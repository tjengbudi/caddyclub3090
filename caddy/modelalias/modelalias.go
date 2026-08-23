// Package modelalias is a Caddy HTTP middleware that makes one stable model
// name work against an OpenAI/Anthropic-compatible backend whose real model
// name keeps changing.
//
// Two things happen here:
//
//   - a request whose top-level JSON "model" field equals the configured alias
//     gets that field swapped for the backend's real served-model-name;
//   - a GET .../v1/models response gets the alias inserted into its data array,
//     so clients that validate against the model list accept it.
//
// Everything else is passed through byte-for-byte. In particular only the
// /v1/models response is ever buffered, so streaming (SSE) completions are
// untouched.
package modelalias

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"

	"github.com/caddyserver/caddy/v2"
	"github.com/caddyserver/caddy/v2/caddyconfig/caddyfile"
	"github.com/caddyserver/caddy/v2/caddyconfig/httpcaddyfile"
	"github.com/caddyserver/caddy/v2/modules/caddyhttp"
)

// maxBody caps how much of a request we are willing to hold in memory to
// rewrite. Anything larger is proxied untouched rather than buffered.
const maxBody = 32 << 20

func init() {
	caddy.RegisterModule(Middleware{})
	httpcaddyfile.RegisterHandlerDirective("model_alias", parseCaddyfile)
}

// Middleware swaps Alias for Target in the request body's "model" field.
type Middleware struct {
	// Alias is the stable name clients send, e.g. "club3090".
	Alias string `json:"alias,omitempty"`
	// Target is the backend's real served-model-name.
	Target string `json:"target,omitempty"`
	// ExposeAlias adds the alias to /v1/models responses.
	ExposeAlias bool `json:"expose_alias,omitempty"`
}

func (Middleware) CaddyModule() caddy.ModuleInfo {
	return caddy.ModuleInfo{
		ID:  "http.handlers.model_alias",
		New: func() caddy.Module { return new(Middleware) },
	}
}

func (m *Middleware) ServeHTTP(w http.ResponseWriter, r *http.Request, next caddyhttp.Handler) error {
	m.rewriteRequest(r)

	if m.ExposeAlias && m.Alias != "" && r.Method == http.MethodGet && isModelsPath(r.URL.Path) {
		// Ask the backend for plain text so the JSON is injectable; without
		// this a gzip-capable client would leave us with compressed bytes.
		r.Header.Del("Accept-Encoding")
		return m.serveModels(w, r, next)
	}
	return next.ServeHTTP(w, r)
}

func isModelsPath(p string) bool {
	return strings.HasSuffix(strings.TrimSuffix(p, "/"), "/v1/models")
}

// rewriteRequest replaces the alias in the request body. Every failure path
// leaves the request exactly as it arrived — this proxy must never be the
// reason a call breaks.
func (m *Middleware) rewriteRequest(r *http.Request) {
	if m.Alias == "" || m.Target == "" || r.Body == nil || r.Body == http.NoBody {
		return
	}
	if r.ContentLength > maxBody {
		return
	}
	if ct := r.Header.Get("Content-Type"); ct != "" && !strings.Contains(strings.ToLower(ct), "json") {
		return
	}

	body, err := io.ReadAll(io.LimitReader(r.Body, maxBody+1))
	if err != nil || len(body) > maxBody {
		// Put back whatever we consumed and stay out of the way.
		r.Body = struct {
			io.Reader
			io.Closer
		}{io.MultiReader(bytes.NewReader(body), r.Body), r.Body}
		return
	}
	r.Body.Close()

	newBody, changed := m.swap(body)
	if !changed {
		r.Body = io.NopCloser(bytes.NewReader(body))
		return
	}

	r.Body = io.NopCloser(bytes.NewReader(newBody))
	r.ContentLength = int64(len(newBody))
	r.Header.Set("Content-Length", strconv.Itoa(len(newBody)))
	r.TransferEncoding = nil
}

// swap returns the body with "model" retargeted, and whether it changed.
func (m *Middleware) swap(body []byte) ([]byte, bool) {
	if trimmed := bytes.TrimLeft(body, " \t\r\n"); len(trimmed) == 0 || trimmed[0] != '{' {
		return nil, false
	}
	// RawMessage keeps every other field byte-identical.
	var obj map[string]json.RawMessage
	if json.Unmarshal(body, &obj) != nil {
		return nil, false
	}
	raw, ok := obj["model"]
	if !ok {
		return nil, false
	}
	var name string
	if json.Unmarshal(raw, &name) != nil || name != m.Alias {
		return nil, false
	}
	repl, err := json.Marshal(m.Target)
	if err != nil {
		return nil, false
	}
	obj["model"] = repl
	out, err := json.Marshal(obj)
	if err != nil {
		return nil, false
	}
	return out, true
}

// serveModels buffers the model list so the alias can be added to it.
func (m *Middleware) serveModels(w http.ResponseWriter, r *http.Request, next caddyhttp.Handler) error {
	buf := new(bytes.Buffer)
	rec := caddyhttp.NewResponseRecorder(w, buf, func(status int, header http.Header) bool {
		return status == http.StatusOK &&
			strings.Contains(strings.ToLower(header.Get("Content-Type")), "json")
	})

	if err := next.ServeHTTP(rec, r); err != nil {
		return err
	}
	if !rec.Buffered() {
		return nil // not JSON / not 200: already streamed straight through
	}

	out := buf.Bytes()
	if injected, ok := m.inject(out); ok {
		out = injected
	}

	rec.Header().Set("Content-Length", strconv.Itoa(len(out)))
	rec.Header().Del("Content-Encoding")
	w.WriteHeader(rec.Status())
	_, err := w.Write(out)
	return err
}

// inject prepends the alias entry to the model list.
func (m *Middleware) inject(body []byte) ([]byte, bool) {
	var doc map[string]json.RawMessage
	if json.Unmarshal(body, &doc) != nil {
		return nil, false
	}
	rawData, ok := doc["data"]
	if !ok {
		return nil, false
	}
	var items []json.RawMessage
	if json.Unmarshal(rawData, &items) != nil {
		return nil, false
	}
	for _, it := range items {
		var probe struct {
			ID string `json:"id"`
		}
		if json.Unmarshal(it, &probe) == nil && probe.ID == m.Alias {
			return nil, false // already listed
		}
	}

	entry, err := json.Marshal(map[string]any{
		"id":       m.Alias,
		"object":   "model",
		"created":  0,
		"owned_by": "club3090-proxy",
		"root":     m.Target,
	})
	if err != nil {
		return nil, false
	}
	merged, err := json.Marshal(append([]json.RawMessage{entry}, items...))
	if err != nil {
		return nil, false
	}
	doc["data"] = merged
	out, err := json.Marshal(doc)
	if err != nil {
		return nil, false
	}
	return out, true
}

func (m *Middleware) UnmarshalCaddyfile(d *caddyfile.Dispenser) error {
	for d.Next() {
		for d.NextBlock(0) {
			switch d.Val() {
			case "alias":
				if !d.Args(&m.Alias) {
					return d.ArgErr()
				}
			case "target":
				if !d.Args(&m.Target) {
					return d.ArgErr()
				}
			case "expose_alias":
				m.ExposeAlias = true
			default:
				return d.Errf("unknown model_alias option %q", d.Val())
			}
		}
	}
	return nil
}

func parseCaddyfile(h httpcaddyfile.Helper) (caddyhttp.MiddlewareHandler, error) {
	var m Middleware
	err := m.UnmarshalCaddyfile(h.Dispenser)
	return &m, err
}

var (
	_ caddyhttp.MiddlewareHandler = (*Middleware)(nil)
	_ caddyfile.Unmarshaler       = (*Middleware)(nil)
)
