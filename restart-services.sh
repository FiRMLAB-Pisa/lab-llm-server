#!/usr/bin/env bash
# restart-services.sh — force-restart all lab LLM services
# Run as a user with sudo access:
#   sudo bash ~/lab-llm-server/restart-services.sh
set -euo pipefail

COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/openhands-compose.yml"

echo "[1/7] Restarting Ollama (main — inference, port 11434)..."
systemctl restart ollama
echo "      done."

echo "[2/7] Restarting Ollama autocomplete (starcoder2:3b, port 11435)..."
systemctl restart ollama-autocomplete
echo "      done."

echo "[3/7] Restarting Lab Knowledge MCP..."
systemctl restart lab-knowledge
echo "      done."

echo "[4/7] Restarting Lab Status dashboard..."
systemctl restart lab-status
echo "      done."

echo "[5/7] Restarting Web Search MCP..."
systemctl restart lab-websearch
docker compose -f "${COMPOSE_FILE%openhands*}searxng-compose.yml" restart 2>/dev/null || true
echo "      done."

echo "[6/7] Restarting Qdrant (codebase index vector DB)..."
docker compose -f "${COMPOSE_FILE%openhands*}qdrant-compose.yml" restart 2>/dev/null || true
echo "      done."

echo "[7/7] Restarting OpenHands..."
if [[ -f "${COMPOSE_FILE}" ]]; then
    docker compose -f "${COMPOSE_FILE}" restart
    echo "      done."
else
    echo "      [WARN] openhands-compose.yml not found at ${COMPOSE_FILE} — skipping."
fi

echo ""
echo "All services restarted. Status:"
systemctl is-active ollama ollama-autocomplete lab-knowledge lab-status lab-websearch
docker compose -f "${COMPOSE_FILE}" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
docker compose -f "${COMPOSE_FILE%openhands*}qdrant-compose.yml" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
echo ""
echo "Status dashboard: http://aleatico2.imago7.local:3002"
