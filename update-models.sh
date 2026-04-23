#!/usr/bin/env bash
# update-models.sh — pull latest versions of all lab LLM models
#
# Run periodically (monthly is a good cadence) to get quality improvements
# from new model releases. Ollama updates in-place — no service restart needed;
# new model versions are used automatically from the next request.
#
# Usage (as a user with sudo access):
#   bash ~/lab-llm-server/update-models.sh
#
# What it does:
#   1. Pulls the latest version of each model (skips if already up to date)
#   2. Shows VRAM usage before and after
#   3. Optionally runs smoke-test.sh to verify inference still works
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MODELS=(
    "qwen3.5:35b"
    "devstral-small-2"
    "qwen3.5:9b"
    "nomic-embed-text"
    "starcoder2:3b"
)

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }

echo "=== Lab LLM — Model Update ==="
echo ""
echo "GPU VRAM before:"
nvidia-smi --query-gpu=name,memory.used,memory.free --format=csv,noheader 2>/dev/null || \
    warn "nvidia-smi not found"
echo ""

UPDATED=()
SKIPPED=()

for model in "${MODELS[@]}"; do
    info "Pulling ${model}..."
    OUTPUT=$(ollama pull "${model}" 2>&1)
    if echo "${OUTPUT}" | grep -qi "up to date\|already\|no update"; then
        info "  → already up to date"
        SKIPPED+=("${model}")
    else
        info "  → updated"
        UPDATED+=("${model}")
    fi
done

echo ""
echo "=== Summary ==="
if [[ ${#UPDATED[@]} -gt 0 ]]; then
    echo "  Updated:  ${UPDATED[*]}"
fi
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    echo "  Current:  ${SKIPPED[*]}"
fi

echo ""
echo "GPU VRAM after:"
nvidia-smi --query-gpu=name,memory.used,memory.free --format=csv,noheader 2>/dev/null || true

echo ""
echo "No service restart needed — Ollama uses new model versions automatically."
echo ""

# Optional: run smoke test to verify inference still works
read -r -p "Run smoke-test.sh to verify inference? [Y/n] " ans
ans="${ans:-Y}"
if [[ "${ans}" =~ ^[Yy] ]]; then
    bash "${SCRIPT_DIR}/smoke-test.sh"
fi
