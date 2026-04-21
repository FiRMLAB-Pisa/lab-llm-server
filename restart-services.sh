#!/usr/bin/env bash
# restart-services.sh — force-restart all lab LLM services
# Run as a user with sudo access:
#   sudo bash ~/lab-llm-server/restart-services.sh
set -euo pipefail

COMPOSE_FILE="$(cd "$(dirname "$0")" && pwd)/openhands-compose.yml"

echo "[1/5] Restarting Ollama..."
systemctl restart ollama
echo "      done."

echo "[2/5] Restarting Lab Knowledge MCP..."
systemctl restart lab-knowledge
echo "      done."

echo "[3/5] Restarting Lab Status dashboard..."
systemctl restart lab-status
echo "      done."

echo "[4/5] Restarting Web Search MCP..."
systemctl restart lab-websearch
docker compose -f "${COMPOSE_FILE%openhands*}searxng-compose.yml" restart 2>/dev/null || true
echo "      done."

echo "[5/5] Restarting OpenHands..."
if [[ -f "${COMPOSE_FILE}" ]]; then
    docker compose -f "${COMPOSE_FILE}" restart
    echo "      done."
else
    echo "      [WARN] openhands-compose.yml not found at ${COMPOSE_FILE} — skipping."
fi

echo ""
echo "All services restarted. Status:"
systemctl is-active ollama lab-knowledge lab-status lab-websearch
docker compose -f "${COMPOSE_FILE}" ps --format "table {{.Name}}\t{{.Status}}" 2>/dev/null || true
echo ""
echo "Status dashboard: http://aleatico2.imago7.local:3002"
