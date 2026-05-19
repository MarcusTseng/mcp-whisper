# Security Model

This document captures the threat model and concrete mitigations applied to
mcp-whisper. The current state is the result of an iterated review by Codex
and Gemini.

## Threat actors considered

1. **Network reachable, unauthenticated** — any host on the LAN/Tailscale network
   that can hit `:8083` or `:8082`.
2. **Authenticated MCP caller** — a client that holds `MCP_AUTH_TOKEN` and can
   call any tool the server exposes.

Out of scope: a malicious user with shell access on the StrixHalo host. They
already have everything in `~/`.

## Attack chains and what closes them

### 1. Bearer-auth bypass via raw whisper endpoint

**Vector:** if `whisper-server` is bound to `0.0.0.0`, anyone on the LAN can
POST audio to `:8082` directly, bypassing the MCP bearer auth on `:8083`.

**Fix:** `whisper-server.sh` binds `--host 127.0.0.1`. Only processes on the
StrixHalo host can connect. Docker Desktop's vpnkit forwards container
`host.docker.internal:8082` requests to host loopback — so the MCP container
still works, while LAN clients see `connection refused`.

### 2. SSRF via `transcribe_url` / `transcribe_youtube` / `transcribe_podcast`

**Vector:** an authenticated caller passes an internal URL
(`http://host.docker.internal:8082/...`, `http://192.168.50.1/admin`) and uses
the server as a confused deputy to hit non-public services.

**Fix:** `_validate_remote_url` is called on every user-supplied URL *before*
httpx/yt-dlp/feedparser sees it. It:

- accepts only `http` and `https` schemes (rejects `file://`, `javascript:`, etc.)
- resolves the hostname and checks **every** address it maps to
- rejects loopback, private (RFC1918), link-local, multicast, reserved, unspecified
- explicitly rejects `host.docker.internal` and `gateway.docker.internal` by name

### 3. yt-dlp foot-guns

**Vector:** yt-dlp will happily follow `file://`, internal HTTP, IMDS
(`169.254.169.254`), and other non-public URLs.

**Fix:** the URL is validated by `_validate_remote_url` *before* `yt-dlp` is
invoked. The binary itself is also invoked with:
- `--no-config` (don't read user config)
- `--no-call-home`
- `--no-cache-dir`
- `--max-filesize <MAX_DOWNLOAD_BYTES>`
- `--no-playlist`

### 4. Arbitrary file read via `transcribe_file`

**Vector:** an authenticated caller passes `path=/home/marcus/.ssh/id_rsa` or
similar and the server reads + transmits the file content to a downstream
service.

**Fix:** two-layer defense.
- The container only mounts the input roots (RO) — `~/Downloads`, `~/Music`,
  `~/whisper.cpp/samples`. Anything else doesn't exist inside the container.
- `_validate_input_path` resolves the path (catching `..` and symlinks) and
  rejects anything not under `ALLOWED_INPUT_ROOTS`.

### 5. Container compromise → host pivot

**Vector:** any RCE in the Python server (or in `ffmpeg` / `yt-dlp` parsing
malicious media) gives the attacker the container's full privileges.

**Fix:**
- Container runs as **UID 1000 (`appuser`)** — not root
- `read_only: true` rootfs
- `tmpfs: /tmp` (writable scratch, but ephemeral)
- Narrow mounts (see #4)
- No `--privileged`, no `cap_add`, no `--pid host`

### 6. Disk exhaustion DoS

**Vector:** authenticated caller asks the server to download `https://example.com/dev/zero`
or a never-ending stream.

**Fix:** `_download` tracks total bytes streamed, raises `ValidationError`
after `MAX_DOWNLOAD_BYTES` (default 500MB). Same cap is passed to yt-dlp via
`--max-filesize`. RSS feeds have a stricter 50MB cap.

### 7. RSS-feed SSRF + tarpit

**Vector:** `feedparser.parse(url)` does its own HTTP request with **no
timeout** and no SSRF guard.

**Fix:** the feed is fetched by httpx (validated, size-capped, 30s timeout)
and the **bytes** are passed to `feedparser.parse(body)`. `feedparser` never
touches the network.

### 8. Bearer-token timing oracle

**Vector:** a naive `==` comparison leaks token length / position via timing
differences over many requests.

**Fix:** `hmac.compare_digest` for the bearer compare. (Realistic exploit risk
over a LAN/Tailscale network is low due to jitter, but the fix is one line.)

### 9. Silent fail-open auth

**Vector:** if `MCP_AUTH_TOKEN` is unset / empty, the auth middleware would
silently allow all requests.

**Fix:** in HTTP mode the server prints a fatal message to stderr and exits
with code 1 if the token is missing. There is no path to running unauthenticated.

### 10. Token leak via careless copy

**Vector:** `cp .env .env.bak` creates a file with the default 0644 umask,
exposing `MCP_AUTH_TOKEN` to other local users.

**Fix:** `update.sh` re-asserts `chmod 0600 .env` on every weekly run.

## Non-issues (knowingly accepted)

- **`host.docker.internal:host-gateway` mapping inside the container.** Needed
  so the container can reach the host's loopback-bound whisper backend. The
  same hostname is explicitly rejected for *user-supplied* URLs in
  `_validate_remote_url`, so a caller can't trick the server into hitting it.
- **`/tmp` is tmpfs.** Downloads are scratch; container restart loses them.
  This is intentional.
- **Container can read its own mounted input directories.** If you don't want
  certain Downloads to be transcribable, don't put them under an allowed root,
  or set `ALLOWED_INPUT_ROOTS` to a more constrained path.

## Reporting issues

If you find a vulnerability, please open a GitHub issue (or contact the maintainer
directly for embargoed issues).
