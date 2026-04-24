#!/usr/bin/env bash
# =============================================================================
# update-openhands.sh — Update OpenHands without touching the rest of the stack
#
# Run this on aleatico2 as a user with sudo / docker access.
# It pulls the latest OpenHands image, then does a rolling restart
# (down + up) of the openhands container only.
#
# Usage:
#   bash ~/lab-llm-server/update-openhands.sh
#
# What it does NOT touch:
#   - Ollama and its models
#   - Lab knowledge / status / websearch MCP services
#   - SearXNG
# =============================================================================
set -euo pipefail

info() { echo "[INFO]  $*"; }
warn() { echo "[WARN]  $*"; }
die()  { echo "[ERROR] $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/openhands-compose.yml"

[[ -f "${COMPOSE_FILE}" ]] || die "openhands-compose.yml not found at ${COMPOSE_FILE}"

command -v docker &>/dev/null || die "docker not found — is Docker installed?"

# --------------------------------------------------------------------------- #
# 1. Pull the latest OpenHands image
# --------------------------------------------------------------------------- #
info "Pulling latest OpenHands images..."
PULL_RETRIES=4
PULL_DELAY=15
pull_ok=0
for ((i=1; i<=PULL_RETRIES; i++)); do
    if docker compose -f "${COMPOSE_FILE}" pull; then
        pull_ok=1
        break
    fi
    if (( i < PULL_RETRIES )); then
        warn "Pull failed (attempt ${i}/${PULL_RETRIES}). Retrying in ${PULL_DELAY}s..."
        sleep "${PULL_DELAY}"
    fi
done
(( pull_ok == 1 )) || die "Image pull failed after ${PULL_RETRIES} attempts. Check network/firewall."

# --------------------------------------------------------------------------- #
# 2. Stop and remove the openhands container only (keeps the data volume)
# --------------------------------------------------------------------------- #
info "Stopping openhands container..."
docker compose -f "${COMPOSE_FILE}" stop openhands
docker compose -f "${COMPOSE_FILE}" rm -f openhands

# --------------------------------------------------------------------------- #
# 3. Start with the new image
# --------------------------------------------------------------------------- #
info "Starting openhands with updated image..."
docker compose -f "${COMPOSE_FILE}" up -d openhands

# --------------------------------------------------------------------------- #
# 4. Verify
# --------------------------------------------------------------------------- #
info "Waiting for OpenHands to become healthy..."
for i in {1..20}; do
    STATUS=$(docker inspect --format='{{.State.Status}}' openhands 2>/dev/null || echo "missing")
    if [[ "${STATUS}" == "running" ]]; then
        info "OpenHands is running."
        break
    fi
    sleep 3
    if [[ $i -eq 20 ]]; then
        warn "OpenHands container status after 60s: ${STATUS}"
        warn "Check logs: docker compose -f ${COMPOSE_FILE} logs --tail=60 openhands"
    fi
done

info ""
info "Active image:"
docker inspect --format='{{.Config.Image}}  (id: {{.Id}}' openhands 2>/dev/null | cut -c1-80 || true
info ""
info "LLM model in use: $(grep LLM_MODEL "${COMPOSE_FILE}" | head -1 | sed 's/.*=//')"
info ""
info "OpenHands: http://aleatico2.imago7.local:3000"
info "Logs:      docker compose -f ${COMPOSE_FILE} logs -f openhands"
