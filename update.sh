#!/usr/bin/env bash
# Weekly updater for the whisper / mcp-whisper stack.
# - Pulls whisper.cpp, rebuilds if HEAD changed, restarts whisper-server.
# - Rebuilds mcp-whisper Docker image with --no-cache --pull (gets latest yt-dlp etc.).
# - Recreates the compose container; only then re-registers the Docker MCP catalog
#   (so a failed `up` doesn't leave the catalog pointing at a missing container).
# - Notifies Discord only on real changes or failures.

set -uo pipefail

WHISPER_DIR="/home/marcus/whisper.cpp"
MCP_DIR="/home/marcus/mcp-whisper"
LOG="${MCP_DIR}/update.log"

export PATH="/home/linuxbrew/.linuxbrew/bin:/usr/local/bin:/usr/bin:/bin"

# Load DISCORD_WEBHOOK_URL (and anything else) from .env without leaking it to the log.
if [[ -f "$MCP_DIR/.env" ]]; then
    set -a
    # shellcheck disable=SC1091
    source "$MCP_DIR/.env"
    set +a
fi
WEBHOOK="${DISCORD_WEBHOOK_URL:-}"

stamp() { date -Is; }
log()   { echo "[$(stamp)] $*" | tee -a "$LOG"; }

CHANGES=()
ERRORS=()

note_change()  { CHANGES+=("$1"); log "CHANGE: $1"; }
note_error()   { ERRORS+=("$1");  log "ERROR : $1"; }

notify_discord() {
    local title="$1" color="$2" body="$3"
    if [[ -z "$WEBHOOK" ]]; then
        log "WARN: DISCORD_WEBHOOK_URL not set; skipping Discord notification"
        return 0
    fi
    local payload
    payload=$(python3 -c '
import json, sys
title, color, body = sys.argv[1], int(sys.argv[2]), sys.argv[3]
print(json.dumps({"embeds":[{"title":title,"color":color,"description":body[:1900]}]}))
' "$title" "$color" "$body")
    curl -s -X POST -H "Content-Type: application/json" -d "$payload" "$WEBHOOK" > /dev/null || true
}

log "=== Update run starting ==="

# Re-assert .env permissions on every run — defense against a careless `cp .env .env.bak`.
if [[ -f "$MCP_DIR/.env" ]]; then
    chmod 0600 "$MCP_DIR/.env" 2>/dev/null || true
fi

# --- 1. whisper.cpp: git pull + conditional rebuild ----------------------------
cd "$WHISPER_DIR" || { note_error "whisper.cpp dir missing"; exit 1; }

OLD_HEAD=$(git -C "$WHISPER_DIR" rev-parse HEAD 2>/dev/null || echo "none")
# Capture pull output to the log but rely solely on the HEAD diff to detect change.
git -C "$WHISPER_DIR" pull --ff-only >> "$LOG" 2>&1 || note_error "whisper.cpp git pull failed"
NEW_HEAD=$(git -C "$WHISPER_DIR" rev-parse HEAD 2>/dev/null || echo "none")

if [[ "$OLD_HEAD" != "$NEW_HEAD" && "$NEW_HEAD" != "none" ]]; then
    log "whisper.cpp: $OLD_HEAD -> $NEW_HEAD, rebuilding"
    if cmake --build "$WHISPER_DIR/build" --config Release -j"$(nproc)" >> "$LOG" 2>&1; then
        if systemctl --user restart whisper-server; then
            note_change "whisper.cpp rebuilt (HEAD $NEW_HEAD), whisper-server restarted"
        else
            note_error "whisper-server restart failed after rebuild"
        fi
    else
        note_error "whisper.cpp build failed (kept previous binary running)"
    fi
fi

# --- 2. mcp-whisper Docker image: --no-cache --pull ----------------------------
cd "$MCP_DIR" || { note_error "mcp-whisper dir missing"; exit 1; }

# Snapshot pinned-package versions from the existing image (if any).
get_img_versions() {
    docker run --rm --entrypoint pip "$1" list --format=freeze 2>/dev/null \
        | grep -iE '^(mcp|httpx|yt-dlp|feedparser|uvicorn)==' | sort
}
OLD_VERS=$(get_img_versions mcp-whisper:latest 2>/dev/null || echo "")
OLD_IMG_ID=$(docker image inspect mcp-whisper:latest --format '{{.Id}}' 2>/dev/null || echo "")

if ! docker build --no-cache --pull -t mcp-whisper:latest "$MCP_DIR" >> "$LOG" 2>&1; then
    note_error "mcp-whisper docker build failed"
else
    NEW_VERS=$(get_img_versions mcp-whisper:latest)
    NEW_IMG_ID=$(docker image inspect mcp-whisper:latest --format '{{.Id}}')

    if [[ "$OLD_VERS" != "$NEW_VERS" ]]; then
        VERSION_DIFF=$(diff <(echo "$OLD_VERS") <(echo "$NEW_VERS") | grep -E '^[<>]' | tr '\n' '; ')
        note_change "mcp-whisper deps changed: ${VERSION_DIFF:0:300}"

        # Bring up the new container FIRST. If this fails we keep the old catalog
        # pointing at the still-running old container (compose hasn't been touched).
        if ! docker compose -f "$MCP_DIR/compose.yml" up -d --force-recreate >> "$LOG" 2>&1; then
            note_error "compose up failed after image rebuild — catalog NOT updated"
        else
            # Verify the new container is actually responding before re-registering the catalog.
            HEALTH=0
            for i in 1 2 3 4 5; do
                if curl -s -o /dev/null -w '%{http_code}' \
                        -X POST http://127.0.0.1:8083/mcp -d '{}' 2>/dev/null | grep -q '^401$'; then
                    HEALTH=1
                    break
                fi
                sleep 2
            done
            if (( HEALTH != 1 )); then
                note_error "new mcp-whisper-http container did not respond on :8083 — catalog NOT updated"
            else
                log "mcp-whisper-http container healthy (auth-enforced 401 received)"
                # Now re-register the Docker MCP catalog entry.
                if docker mcp catalog create local-mcp:latest \
                        --title "Local Custom MCP" \
                        --server "file://${MCP_DIR}/catalog-entry.yaml" >> "$LOG" 2>&1; then
                    docker mcp profile server add default \
                        --server catalog://local-mcp:latest/whisper-transcribe >> "$LOG" 2>&1 \
                        || note_error "Docker MCP profile add failed"
                else
                    note_error "Docker MCP catalog create failed"
                fi
                # Delete the previous image (now untagged) — only when versions really changed.
                if [[ -n "$OLD_IMG_ID" && "$OLD_IMG_ID" != "$NEW_IMG_ID" ]]; then
                    if docker rmi "$OLD_IMG_ID" >> "$LOG" 2>&1; then
                        log "Removed previous mcp-whisper image ${OLD_IMG_ID:7:12}"
                    else
                        log "WARN: could not remove old image ${OLD_IMG_ID:7:12} (may be in use)"
                    fi
                fi
            fi
        fi
    fi
fi

# --- 3. Notify --------------------------------------------------------------
log "=== Run complete: ${#CHANGES[@]} change(s), ${#ERRORS[@]} error(s) ==="

if (( ${#ERRORS[@]} > 0 )); then
    body="Errors:\n$(printf -- '- %s\n' "${ERRORS[@]}")"
    (( ${#CHANGES[@]} > 0 )) && body+=$'\n\n'"Changes:\n$(printf -- '- %s\n' "${CHANGES[@]}")"
    notify_discord "🟥 whisper/mcp-whisper update: errors" 15158332 "$body"
    exit 1
elif (( ${#CHANGES[@]} > 0 )); then
    body="$(printf -- '- %s\n' "${CHANGES[@]}")"
    notify_discord "🟩 whisper/mcp-whisper updated" 3066993 "$body"
fi
# silent on no-op
exit 0
