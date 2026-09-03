# caddyclub3090

Satu alamat dan satu nama model yang tidak pernah berubah untuk rig club-3090.

```
http://localhost/v1/...     →  engine club-3090 mana pun yang sedang hidup
model: "club3090"           →  nama model apa pun yang sedang dilayani engine itu
```

Setiap `switch.sh` mengubah **dua** hal sekaligus — port host (`:8010`, `:8020`,
`:8117`, …) dan nama model (`qwen3.6-27b-autoround`, `qwen3.8-27b-uncensored`, …).
Proxy ini menyembunyikan keduanya. Set config klien sekali, lalu lupakan.

---

## Mulai

```bash
cd ~/caddy
docker compose up -d --build          # sekali saja
ln -s ~/caddy/scripts/llmroute ~/.local/bin/llmroute
```

Cek:

```bash
$ llmroute status
key      : none — :80 is open to anyone who can reach it
prefer   : none — :80 follows the last pick, or the only engine up
backends :
  => vllm-qwen38-27b-uncensored-dual-max     :8117  qwen3.8-27b-uncensored-fp8     9 minutes

  '=>' owns http://localhost/ (via sole) — the others stay reachable at http://localhost/b/<port>/
```

Setelah ini tidak ada yang perlu dijalankan lagi. Ganti compose sesuka hati —
proxy mengikuti sendiri dalam hitungan detik.

---

## Cara pakai per klien

Nilai yang dipakai selalu sama: **base URL `http://localhost`** (atau
`http://192.168.1.202` dari mesin lain), **model `club3090`**.

### Claude Code

Di `~/.bashrc`:

```bash
export ANTHROPIC_BASE_URL=http://localhost
export ANTHROPIC_MODEL=club3090
export ANTHROPIC_API_KEY=dummy        # ganti dengan PROXY_KEY kalau key dipasang
```

Ini menggantikan `club3090-env.sh` sepenuhnya: tidak ada lagi `eval` yang harus
dijalankan di tiap terminal baru, dan tidak ada lagi terminal yang menunjuk ke
port basi.

> `~/.claude/settings.json` tetap harus **tidak** memuat `ANTHROPIC_BASE_URL`
> atau `ANTHROPIC_MODEL` di bagian `env`, karena nilai di situ menang atas
> environment. Cukup `{"env": {"ANTHROPIC_API_KEY": "dummy"}}`.

### curl

```bash
curl http://localhost/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"club3090","messages":[{"role":"user","content":"halo"}]}'
```

### OpenAI SDK — Python

```python
from openai import OpenAI

client = OpenAI(base_url="http://localhost/v1", api_key="dummy")
r = client.chat.completions.create(
    model="club3090",
    messages=[{"role": "user", "content": "halo"}],
)
```

### OpenAI SDK — Node

```js
import OpenAI from "openai";

const client = new OpenAI({ baseURL: "http://localhost/v1", apiKey: "dummy" });
const r = await client.chat.completions.create({
  model: "club3090",
  messages: [{ role: "user", content: "halo" }],
});
```

### Anthropic SDK

```python
from anthropic import Anthropic

client = Anthropic(base_url="http://localhost", api_key="dummy")
r = client.messages.create(
    model="club3090", max_tokens=256,
    messages=[{"role": "user", "content": "halo"}],
)
```

### Open WebUI dan klien berbasis daftar model

Tambahkan koneksi OpenAI dengan base URL `http://localhost/v1` dan API key bebas.
`club3090` muncul di daftar model bersama nama-nama aslinya:

```bash
$ curl -s localhost/v1/models | python3 -c "import sys,json;print([m['id'] for m in json.load(sys.stdin)['data']])"
['club3090', 'qwen3.8-27b-uncensored', 'qwen3.8-27b-uncensored-fp8']
```

### Dari mesin lain di LAN

Ganti `localhost` dengan IP rig — `http://192.168.1.202`. Selebihnya identik.
Perhatikan: selama `PROXY_KEY` kosong, siapa pun di jaringan lokal bisa memakai
GPU ini. Lihat [Mengunci dengan key](#mengunci-dengan-key).

### Nama model asli tetap berfungsi

Proxy hanya mencegat string persis `club3090`. `qwen3.8-27b-uncensored-fp8`
diteruskan apa adanya, dan nama yang tidak dikenal tetap ditolak vLLM seperti
biasa. Jadi sifatnya menambah, bukan mengganti.

---

## Perintah `llmroute`

| Perintah | Kegunaan |
|---|---|
| `llmroute` | rutekan satu-satunya backend, atau tampilkan menu bila ada beberapa |
| `llmroute 8117` | pilih berdasarkan port |
| `llmroute vllm-qwen38-27b-uncensored-dual-max` | pilih berdasarkan nama container |
| `llmroute prefer <port\|nama>` | jadikan backend ini pilihan utama permanen |
| `llmroute prefer show` | tampilkan preferensi yang berlaku |
| `llmroute prefer clear` | hapus preferensi |
| `llmroute status` | apa yang sedang dirutekan ke mana |
| `llmroute key generate` | pasang key acak |
| `llmroute key set <key>` | pasang key tertentu |
| `llmroute key show` | tampilkan key saat ini |
| `llmroute key clear` | hapus key — `:80` kembali terbuka |

Dalam pemakaian normal (satu engine hidup) perintah ini **tidak pernah perlu
dijalankan** — daemon sudah mengurusnya.

---

## Kalau ada beberapa engine sekaligus

Urutan penentuan siapa yang memegang `:80`:

1. **preferensi** (`state/preferred`) — menang selama container-nya hidup
2. **pilihan terakhir** (`state/pinned`) — kalau preferensi tidak dipasang atau engine-nya mati
3. **satu-satunya engine hidup** — memilih dirinya sendiri, dan tercatat sebagai pilihan terakhir

| Situasi | Yang terjadi |
|---|---|
| satu engine hidup | langsung dirutekan, tanpa bertanya |
| preferensi dipasang dan engine-nya hidup | selalu dia yang dapat `:80` |
| beberapa, pilihan lama masih hidup | pilihan dipertahankan — `:80` tidak pernah pindah diam-diam |
| beberapa, belum ada preferensi maupun pilihan | `:80` balas 503 berisi daftar kandidat; jalankan `llmroute` |
| tidak ada sama sekali | `:80` balas 503 yang menyebutkan itu |

### Pilihan utama yang permanen

`llmroute <nama>` hanya menyetel pilihan terakhir, dan pilihan itu bisa tergeser
sendiri: kalau engine lain sempat jalan sendirian, dialah yang tercatat. Untuk
keputusan yang bertahan, pakai preferensi:

```bash
llmroute prefer vllm-qwen38-27b-uncensored-dual-max
```

Selama container itu hidup, dia memegang `:80` — tidak peduli apa lagi yang
menyala atau siapa yang terakhir dipilih. Saat dia mati, routing turun ke
pilihan terakhir atau ke engine tunggal yang tersisa, lalu kembali ke dia
begitu dia hidup lagi. `/_status` melaporkannya lewat `preferred` dan
`selected_by`.

Setiap engine — yang aktif maupun tidak — selalu bisa diakses langsung:

```bash
curl http://localhost/b/8117/v1/models                          # berdasarkan port
curl http://localhost/b/vllm-qwen38-27b-uncensored-dual-max/v1/models   # berdasarkan nama
```

Masing-masing punya pemetaan alias sendiri, jadi `model: "club3090"` di
`/b/8020/` menunjuk ke model milik `:8020`, bukan milik backend aktif.

Memilih lewat menu:

```
$ llmroute
2 backend aktif:
  1) vllm-qwen38-27b-uncensored-dual-max      :8117  qwen3.8-27b-uncensored-fp8   (9 minutes)
  2) vllm-qwen36-27b-minimal                  :8020  qwen3.6-27b-autoround        (3 minutes)
Pilih [1-2]: 1
=> :80 => :8117  vllm-qwen38-27b-uncensored-dual-max  (qwen3.8-27b-uncensored-fp8)
```

---

## Mengunci dengan key

Secara default `:80` terbuka. Untuk menguncinya:

```bash
$ llmroute key generate
sk-c3-UidRRlX71iNLGb6qPKRXLgeD5a9QBKv2
```

Berlaku seketika, tanpa restart. Setelah itu setiap request wajib membawa key —
lewat salah satu dari dua header ini, karena klien OpenAI dan Anthropic memakai
konvensi yang berbeda:

```bash
curl http://localhost/v1/models -H "Authorization: Bearer sk-c3-…"   # gaya OpenAI
curl http://localhost/v1/models -H "x-api-key: sk-c3-…"              # gaya Anthropic
```

Artinya cukup isi field API key yang memang sudah ada di klien Anda
(`ANTHROPIC_API_KEY`, `OpenAI(api_key=…)`, kolom API key di Open WebUI).

Tanpa key atau dengan key salah: `401`.

```bash
llmroute key clear     # kembali terbuka
```

Key ini pagar terhadap pemakaian iseng di LAN, **bukan** enkripsi — `:80` tetap
HTTP polos, jadi key terkirim sebagai teks biasa di jaringan lokal.

---

## `/_status`

```bash
$ curl -s localhost/_status | python3 -m json.tool
{
    "alias": "club3090",
    "config_id": "5570727abf248879",
    "key_required": false,
    "ambiguous": false,
    "active": {
        "container": "vllm-qwen38-27b-uncensored-dual-max",
        "port": 8117,
        "model": "qwen3.8-27b-uncensored-fp8"
    },
    "preferred": "vllm-qwen38-27b-uncensored-dual-max",
    "selected_by": "preferred",
    "candidates": [ … ]
}
```

Kalau key dipasang, endpoint ini ikut terkunci. `llmroute status` selalu bisa
dipakai dari rig tanpa key karena ia membaca Docker langsung.

---

## Kalau ada yang tidak beres

| Gejala | Kemungkinan | Tindakan |
|---|---|---|
| `503 no club-3090 backend is running` | tidak ada engine hidup | `docker ps`; nyalakan compose-nya |
| `503 several backends … none is preferred or pinned` | beberapa engine hidup, belum dipilih | `llmroute`, atau `llmroute prefer <nama>` |
| `503 club3090 proxy is starting up` | Caddy baru restart, config belum di-push | tunggu ≤60 detik (heartbeat), atau `docker exec c3proxy-router bash /home/budi/caddy/scripts/reconcile.sh` |
| `401` di semua request | `PROXY_KEY` terpasang | `llmroute key show`, atau `llmroute key clear` |
| `404 The model 'club3090' does not exist` | request tidak lewat proxy | cek base URL — jangan menunjuk langsung ke `:8117` |
| model di `/_status` terlihat salah sesaat setelah switch | engine masih memuat bobot, nama diambil dari argumen container | otomatis dikoreksi ~15 detik setelah endpoint siap |
| `connection refused` di `:80` | container proxy mati | `docker compose ps`, lalu `docker compose up -d` |

Log:

```bash
docker logs -f c3proxy-router     # keputusan routing
docker logs -f c3proxy-caddy      # error Caddy
cat ~/caddy/state/Caddyfile.applied   # config yang sedang berlaku
```

Setelah mengubah kode modul Go:

```bash
docker compose up -d --build
```

---

## Cara kerjanya, singkat

```
                     ┌─ gerbang key (dilewati bila key kosong)
 klien ──▶ :80 caddy ├─ GET /_status
                     ├─ /b/<port|nama>/v1/...   → engine mana pun
                     └─ /v1/...                 → engine aktif
                          ├ model_alias  "club3090" → "qwen3.8-27b-uncensored-fp8"
                          └ reverse_proxy 127.0.0.1:8117

 c3proxy-router ──▶ docker events ──▶ reconcile.sh ──▶ admin API :2019
```

vLLM menolak nama model yang tidak dilayaninya, sementara Caddy standar hanya
bisa menulis ulang URI dan header — bukan body. Karena itu
`caddy/modelalias/modelalias.go` (~240 baris) menukar field `"model"` sebelum
request diteruskan, dan menyisipkan alias ke respons `/v1/models`. Modul ini
di-compile dengan `xcaddy` di dalam build Docker, jadi host tidak perlu Go.
Hanya `/v1/models` yang pernah di-buffer — streaming SSE lewat begitu saja.

| Berkas | Isi |
|---|---|
| `caddy/modelalias/modelalias.go` | modul Caddy: tukar alias + sisip `/v1/models` |
| `caddy/Dockerfile` | build `xcaddy` multi-stage |
| `router/Dockerfile` | sidecar pemantau (bash + curl + docker-cli) |
| `scripts/lib-discover.sh` | deteksi engine, port, dan nama model |
| `scripts/reconcile.sh` | susun Caddyfile, push ke admin API |
| `scripts/watch.sh` | ikuti docker events; entrypoint container router |
| `scripts/llmroute` | CLI pemilih backend dan pengelola key |
| `state/` | preferensi, pilihan terakhir, config terakhir (gitignored) |
| `.env` | `PROXY_KEY` (gitignored) |

Keduanya memakai `network_mode: host` — itu yang membuat Caddy bisa mengikat
`:80` tanpa sudo (daemon Docker sudah root) dan menjangkau engine di
`127.0.0.1:<port>` langsung. Admin API Caddy tetap terkunci di `127.0.0.1:2019`.

---

## Perawatan

Repo `club-3090` **tidak pernah ditulisi** oleh proyek ini; dua skripnya hanya
dibaca sebagai acuan. Satu-satunya kopling adalah regex prefix nama engine di
`scripts/lib-discover.sh`:

```
^(vllm-|llamacpp-|llama-cpp-|sglang-|beellama-|ik-llama-)
```

Itu gabungan dua daftar di repo tersebut — `scripts/club3090-env.sh:46` dan
`scripts/gpu-mode.sh:1035`. Kalau suatu saat muncul prefix engine baru di sana,
tambahkan juga di sini. Sisanya diturunkan saat runtime.
