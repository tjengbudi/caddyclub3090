# caddyclub3090

A reverse proxy that gives the club-3090 rig **one address and one model name
that never change**, no matter which engine container is currently serving.

```
http://<host>/v1/...      →  whichever club-3090 engine is running
model: "club3090"         →  whatever that engine actually serves
```

## The problem

Every `switch.sh` / `gpu-mode.sh` changes two things at once:

- the **host port** — `:8010`, `:8020`, `:8091`, `:8117`, …
- the **model name** — `--served-model-name qwen3.6-27b-autoround` today,
  something else tomorrow

`club-3090/scripts/club3090-env.sh` fixes this for programs started from a
shell, by exporting `ANTHROPIC_BASE_URL` and `ANTHROPIC_MODEL`. Anything else —
Open WebUI, an SDK with a base_url in a config file, another machine on the LAN
— still has to be edited by hand.

This proxy removes that step. Point clients at `http://<host>/` with model
`club3090` once, and never touch it again.

## Why a custom Caddy module

vLLM rejects a model name it does not serve:

```
$ curl 127.0.0.1:8020/v1/chat/completions -d '{"model":"club3090",...}'
{"error":{"message":"The model `club3090` does not exist.","code":404}}
```

so a stable alias means editing the JSON request body — and stock Caddy can
only rewrite URIs and headers. `caddy/modelalias/` is a ~240-line Caddy module
that does the swap. It is compiled with `xcaddy` inside the Docker build, so
the host needs no Go toolchain.

Adding the alias upstream instead (a second `--served-model-name`) would have
meant editing the club-3090 compose files. **This project never writes to that
repo** — it only reads two of its scripts as a reference for how to detect a
running engine.

## Layout

| Path | What it is |
|---|---|
| `caddy/modelalias/modelalias.go` | the Caddy module: alias swap + `/v1/models` injection |
| `caddy/Dockerfile` | multi-stage `xcaddy` build |
| `router/Dockerfile` | watcher sidecar (bash + curl + docker-cli) |
| `scripts/lib-discover.sh` | finds running engines, their port and model |
| `scripts/reconcile.sh` | builds a Caddyfile and pushes it to Caddy's admin API |
| `scripts/watch.sh` | reacts to docker events; entrypoint of the router container |
| `scripts/llmroute` | CLI: pick the active backend, manage the API key |
| `Caddyfile.bootstrap` | cold-start config, replaced at runtime |
| `state/` | pinned backend + last applied config (gitignored) |
| `.env` | `PROXY_KEY` (gitignored) |

## Install

```bash
docker compose up -d --build
ln -s ~/caddy/scripts/llmroute ~/.local/bin/llmroute
```

Both containers use `network_mode: host` — that is what lets Caddy bind `:80`
without sudo (the docker daemon is already root) and reach engines on
`127.0.0.1:<port>` directly. Caddy's admin API stays bound to `127.0.0.1:2019`.

## Use

```bash
export ANTHROPIC_BASE_URL=http://localhost
export ANTHROPIC_MODEL=club3090
export ANTHROPIC_API_KEY=dummy          # or the PROXY_KEY, if one is set
```

The engine's real names keep working too (`qwen3.6-27b`, `…-autoround`, …) —
the proxy only intercepts the literal string `club3090`. It is additive; nothing
that worked before stops working.

```bash
llmroute                 # route the only backend, or offer a menu
llmroute 8020            # pin by port
llmroute status          # what is routed where
llmroute key generate    # lock :80 behind a random key
llmroute key clear       # open it back up
```

## How routing decides

| Situation | Result |
|---|---|
| one engine running | routed automatically, no questions |
| several, pin still alive | pin kept — `:80` never moves on its own |
| several, no valid pin | `:80` returns 503 listing the candidates; run `llmroute` |
| none | `:80` returns 503 saying so |

Every engine, active or not, is also reachable at `http://<host>/b/<port>/v1/...`
and `http://<host>/b/<container-name>/v1/...`, each with its own alias mapping.

`GET /_status` returns the whole picture as JSON.

## Optional API key

`PROXY_KEY` in `.env`. Empty means open. When set, every request needs either
`Authorization: Bearer <key>` or `x-api-key: <key>` — both, because OpenAI and
Anthropic clients disagree about which header to use.

This is a gate against casual use from the LAN, not encryption: `:80` is plain
HTTP, so the key travels in the clear on the local network.

## Maintenance

The only coupling to club-3090 is the engine-name regex in
`scripts/lib-discover.sh`:

```
^(vllm-|llamacpp-|llama-cpp-|sglang-|beellama-|ik-llama-)
```

It is the union of the two lists in that repo — `scripts/club3090-env.sh:46`
and `scripts/gpu-mode.sh:1035`. If a new engine prefix ever shows up there, add
it here too. Everything else is derived at runtime.
