#!/usr/bin/env bash
# =============================================================================
# prefetch-llm-assets.sh
#
# Run this on the FAST machine (e.g. lab desktop) via MobaXterm SSH session.
# It downloads the Ollama binary and all required models locally, then rsync
# everything to a shared staging directory on aleatico2.
#
# Usage:
#   bash prefetch-llm-assets.sh [aleatico2_user@aleatico2_host]
#
# Default target host: aleatico2.imago7.local
#
# Prerequisites on aleatico2 (one-time, done by admin):
#   sudo mkdir -p /srv/llm-cache
#   sudo chmod 1777 /srv/llm-cache   # sticky + world-writable, like /tmp
#
# Then on aleatico2 run:
#   sudo bash setup.sh
# setup.sh will detect /srv/llm-cache and skip downloads.
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration
# --------------------------------------------------------------------------- #
ALEATICO="${1:-mcencini@aleatico2.imago7.local}"   # override via first arg
REMOTE_CACHE="/srv/llm-cache"                       # must match setup.sh
LOCAL_CACHE="${HOME}/.llm-prefetch-cache"           # temp dir on fast machine
OLLAMA_PORT="11435"                                 # avoid clash if port 11434 is in use

MODELS=(
    "deepseek-r1:32b"
    "qwen2.5-coder:14b"
    "deepseek-r1:7b"
    "nomic-embed-text"
    "starcoder2:3b"
)

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }

# --------------------------------------------------------------------------- #
# 1. Create local staging dir
# --------------------------------------------------------------------------- #
info "Staging directory: ${LOCAL_CACHE}"
mkdir -p "${LOCAL_CACHE}/models"

# --------------------------------------------------------------------------- #
# 2. Download Ollama Linux binary
# --------------------------------------------------------------------------- #
OLLAMA_BIN="${LOCAL_CACHE}/ollama"
if [[ -x "${OLLAMA_BIN}" ]]; then
    info "Ollama binary already cached at ${OLLAMA_BIN} — skipping download."
else
    info "Downloading Ollama Linux binary..."
    curl -L --progress-bar \
        https://ollama.com/download/ollama-linux-amd64 \
        -o "${OLLAMA_BIN}"
    chmod +x "${OLLAMA_BIN}"
    info "Ollama binary saved ($(du -sh "${OLLAMA_BIN}" | cut -f1))."
fi

# --------------------------------------------------------------------------- #
# 3. Start a temporary local Ollama server to pull models
# --------------------------------------------------------------------------- #
info "Starting temporary Ollama server on port ${OLLAMA_PORT}..."
OLLAMA_MODELS="${LOCAL_CACHE}/models" \
OLLAMA_HOST="127.0.0.1:${OLLAMA_PORT}" \
    "${OLLAMA_BIN}" serve &>/tmp/ollama-prefetch.log &
OLLAMA_PID=$!

# Ensure we kill the server on exit
trap 'info "Stopping temporary Ollama server..."; kill "${OLLAMA_PID}" 2>/dev/null || true; wait "${OLLAMA_PID}" 2>/dev/null || true' EXIT

# Wait for server to be ready
info "Waiting for Ollama server to be ready..."
for i in {1..30}; do
    if curl -sf "http://127.0.0.1:${OLLAMA_PORT}/api/tags" >/dev/null 2>&1; then
        info "Ollama server ready."
        break
    fi
    sleep 2
    if [[ $i -eq 30 ]]; then
        die "Ollama server did not start. See /tmp/ollama-prefetch.log"
    fi
done

# --------------------------------------------------------------------------- #
# 4. Pull all models into local cache
# --------------------------------------------------------------------------- #
info "Pulling models into local cache (this is the slow step on a fast line)..."
for model in "${MODELS[@]}"; do
    info "Pulling ${model}..."
    OLLAMA_HOST="http://127.0.0.1:${OLLAMA_PORT}" \
        "${OLLAMA_BIN}" pull "${model}"
    info "Done: ${model}"
done

info "All models pulled."
info "Local cache size: $(du -sh "${LOCAL_CACHE}" | cut -f1)"

# --------------------------------------------------------------------------- #
# 5. Stop local Ollama server (trap handles it, but be explicit)
# --------------------------------------------------------------------------- #
info "Stopping temporary Ollama server..."
kill "${OLLAMA_PID}" 2>/dev/null || true
wait "${OLLAMA_PID}" 2>/dev/null || true
trap - EXIT   # clear trap so it doesn't double-fire

# --------------------------------------------------------------------------- #
# 6. Rsync to aleatico2
# --------------------------------------------------------------------------- #
info "Transferring to ${ALEATICO}:${REMOTE_CACHE} ..."
info "(You may be prompted for your SSH password)"
rsync -avh --progress \
    "${LOCAL_CACHE}/" \
    "${ALEATICO}:${REMOTE_CACHE}/"

info ""
info "=== Prefetch complete ==="
info ""
info "Next steps on aleatico2:"
info "  1. sudo mkdir -p /srv/llm-cache  (if not already done)"
info "  2. sudo chmod 1777 /srv/llm-cache"
info "  3. cd ~/copilot/lab-llm-server && sudo bash setup.sh"
info ""
info "setup.sh will detect the cache and skip all downloads."
