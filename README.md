# mcp-whisper

A local-first MCP server that exposes a whisper.cpp HTTP backend as four
transcription tools, with bearer auth, SSRF guards, and a Docker MCP Toolkit
catalog entry.

```
                 ┌────────────────────────────┐
 MCP clients ──► │ mcp-whisper-http :8083/mcp │ ── POST audio ──┐
 (LAN/Tailscale) │ (bearer-auth Streamable    │                 ▼
                 │  HTTP, container, non-root)│       ┌──────────────────────┐
                 └────────────────────────────┘       │ whisper.cpp :8082    │
                                                      │ (Vulkan/AMD, native, │
 Docker MCP gateway ────► same image, stdio mode ──►  │  bound to 127.0.0.1) │
 (Claude / Codex / etc.)                              └──────────────────────┘
```

## Tools

| Tool | Source | Notes |
|---|---|---|
| `transcribe_file(path, format, language?)` | Local audio/video file | Path must resolve under `ALLOWED_INPUT_ROOTS` |
| `transcribe_url(url, format, language?)` | Direct http(s) URL | Public hosts only |
| `transcribe_youtube(url, format, language?)` | YouTube (yt-dlp) | URL validated *before* yt-dlp runs |
| `transcribe_podcast(rss_url, episode_index, format, language?)` | RSS feed episode | Audio enclosure preferred; video fallback |

**Formats:** `text` · `json` · `srt` · `vtt` · `md`. The `md`/`srt`/`vtt` formats
write a file to `OUTPUT_DIR` and return its path; `text`/`json` return inline.

## Quick start

### Prerequisites

1. **whisper.cpp** built with a backend that suits your hardware, running as an
   OpenAI-compatible HTTP server on `127.0.0.1:8082`. Vulkan, CUDA, Metal, or
   CPU-only all work. Example invocation:
   ```bash
   whisper-server --model models/ggml-large-v3-turbo.bin \
       --host 127.0.0.1 --port 8082 \
       --inference-path /v1/audio/transcriptions --convert
   ```
2. **Docker** (Engine or Desktop).
3. **ffmpeg** in `PATH` (only needed if you also run whisper-server's `--convert`).

### Run

```bash
git clone https://github.com/<you>/mcp-whisper
cd mcp-whisper

# Generate auth token
echo "MCP_AUTH_TOKEN=$(openssl rand -hex 32)" > .env
chmod 0600 .env

# Build + run
docker compose up -d --build
```

Verify:
```bash
TOKEN=$(grep MCP_AUTH_TOKEN .env | cut -d= -f2)
curl -X POST http://localhost:8083/mcp \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -d '{"jsonrpc":"2.0","method":"tools/list","id":1}'
```

## Configuration

All knobs are environment variables (see `.env.example`):

| Var | Default | Purpose |
|---|---|---|
| `MCP_AUTH_TOKEN` | — (required for HTTP) | Bearer token clients send |
| `TRANSPORT` | `stdio` | `stdio` for local MCP clients, `http` for daemon mode |
| `HOST` / `PORT` | `0.0.0.0` / `8083` | HTTP bind |
| `WHISPER_URL` | `http://host.docker.internal:8082/v1/audio/transcriptions` | Where to POST audio |
| `ALLOWED_INPUT_ROOTS` | `/home/marcus/Downloads:/home/marcus/Music:/home/marcus/whisper.cpp/samples` | Colon-list of roots `transcribe_file` may read |
| `OUTPUT_DIR` | `/home/marcus/Documents/Obsidian Vault/Transcripts` | Where md/srt/vtt files are written |
| `MAX_DOWNLOAD_BYTES` | `524288000` (500MB) | Cap for httpx + yt-dlp downloads |

## Wiring into MCP clients

### Claude Code / Codex / Cursor (remote HTTP)

```json
{
  "mcpServers": {
    "whisper": {
      "url": "http://your-host:8083/mcp",
      "headers": { "Authorization": "Bearer <token>" }
    }
  }
}
```

### Docker MCP Toolkit (stdio gateway)

The repo includes `catalog-entry.yaml`. On a Docker Desktop machine:

```bash
docker mcp catalog create local-mcp:latest \
    --title "Local Custom MCP" \
    --server file://$PWD/catalog-entry.yaml
docker mcp profile server add default \
    --server catalog://local-mcp:latest/whisper-transcribe
```

Then `whisper-transcribe` appears in Docker Desktop's MCP Toolkit panel and any
client wired to the Docker MCP gateway (e.g. via `MCP_DOCKER` server) sees all
four tools.

## Security model

Hardened in line with a Codex + Gemini cross-review. See [SECURITY.md](SECURITY.md) for the full threat model.

- whisper.cpp **bound to `127.0.0.1`** — LAN cannot bypass the MCP bearer auth
- Container runs as **UID 1000** with `read_only: true` rootfs and `tmpfs: /tmp`
- **Narrow mounts**: only the input roots (RO) and the output dir (RW) — no `~/.ssh`, `.gnupg`, etc.
- `transcribe_file` rejects paths outside `ALLOWED_INPUT_ROOTS` (catches `../`, symlink escape)
- `_validate_remote_url` rejects non-http(s) schemes, private/loopback/link-local IPs, and `host.docker.internal`; applied to all three remote tools *before* yt-dlp/httpx see the URL
- **Fail-closed auth**: HTTP transport refuses to start if `MCP_AUTH_TOKEN` is unset; `hmac.compare_digest` for the check
- **DoS cap**: 500MB ceiling on httpx streams; yt-dlp invoked with `--max-filesize 500M --no-config --no-call-home --no-cache-dir`
- RSS feed fetched via httpx (validated, capped) — feedparser never does its own networking

## Weekly auto-updater

`update.sh` + `mcp-whisper-update.{service,timer}` (systemd user units, fire
Sunday 04:00 with 15min jitter, `Persistent=true`). It:

1. `git pull` whisper.cpp → rebuild if HEAD moved → restart whisper-server
2. Rebuild `mcp-whisper:latest` with `--no-cache --pull`
3. Compare pinned package versions inside the image before/after
4. On a real version change: `compose up -d --force-recreate` → health-check → re-register Docker MCP catalog → remove old image
5. Discord webhook only on real changes or errors (silent on no-op)

Install:
```bash
cp systemd/mcp-whisper-update.{service,timer} ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now mcp-whisper-update.timer
```

## Project layout

```
mcp-whisper/
├── server.py              FastMCP server, 4 tools, dual stdio/http transport
├── Dockerfile             python:3.12-slim + ffmpeg + 5 pip deps, non-root user
├── compose.yml            Long-running HTTP daemon, narrow RO mounts
├── catalog-entry.yaml     Docker MCP Toolkit catalog server spec
├── update.sh              Weekly updater
├── systemd/               Systemd user units (timer, service)
├── .env.example           Copy to .env and fill in MCP_AUTH_TOKEN
└── README.md
```

## License

MIT — see [LICENSE](LICENSE).
