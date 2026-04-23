#!/usr/bin/env bash
# =============================================================================
# migrate-models.sh — upgrade the lab LLM model stack
#
# Pulls the new 3-tier model set (Qwen3.5/Devstral), then removes the old
# DeepSeek R1 / Qwen2.5-Coder models to free disk and VRAM headroom.
#
# Run ONCE on aleatico2 as the Ollama service user (or any user with ollama
# in their PATH).  No sudo required; Ollama manages its own model store.
#
# Old stack:  deepseek-r1:32b  qwen2.5-coder:14b  deepseek-r1:7b
# New stack:  qwen3.5:35b  devstral-small-2  qwen3.5:9b
#             (+ starcoder2:3b and nomic-embed-text unchanged)
#
# Usage:
#   bash ~/lab-llm-server/migrate-models.sh [--dry-run]
#
# --dry-run  Show what would happen without pulling or deleting anything.
# =============================================================================
set -euo pipefail

DRY_RUN=0
for arg in "$@"; do
    [[ "$arg" == "--dry-run" ]] && DRY_RUN=1
done

info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }
dryrun(){ echo "[DRY]   $*"; }

command -v ollama &>/dev/null || die "ollama not found in PATH — run this on aleatico2"

NEW_MODELS=(
    "qwen3.5:35b"
    "devstral-small-2"
    "qwen3.5:9b"
)

OLD_MODELS=(
    "deepseek-r1:32b"
    "qwen2.5-coder:14b"
    "deepseek-r1:7b"
)

# Models never removed (keep-alive: embedding and autocomplete are small)
KEEP_MODELS=(
    "nomic-embed-text"
    "starcoder2:3b"
)

# ---------------------------------------------------------------------------
echo ""
echo "=== Lab LLM — Model Stack Migration ==="
[[ "$DRY_RUN" -eq 1 ]] && echo "    DRY RUN — no changes will be made"
echo ""
echo "GPU VRAM before migration:"
nvidia-smi --query-gpu=name,memory.used,memory.free --format=csv,noheader 2>/dev/null \
    || warn "nvidia-smi not available"
echo ""

# ---------------------------------------------------------------------------
# 1. Pull new models
# ---------------------------------------------------------------------------
echo "--- Step 1: Pull new models ---"
for model in "${NEW_MODELS[@]}"; do
    if [[ "$DRY_RUN" -eq 1 ]]; then
        dryrun "would pull: $model"
    else
        info "Pulling $model (this may take a while for large models)..."
        ollama pull "$model"
        info "  done: $model"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 2. Verify new models respond before removing old ones
# ---------------------------------------------------------------------------
if [[ "$DRY_RUN" -eq 0 ]]; then
    echo "--- Step 2: Quick inference check on new models ---"
    OLLAMA_URL="http://127.0.0.1:11434"
    VERIFY_MODEL="qwen3.5:9b"   # smallest new model — fastest to verify
    info "Sending test prompt to ${VERIFY_MODEL}..."
    RESP=$(curl -sf --max-time 60 -X POST "${OLLAMA_URL}/api/chat" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${VERIFY_MODEL}\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}" \
        2>/dev/null || true)
    if echo "${RESP}" | python3 -c "import sys,json; assert json.load(sys.stdin)['message']['content']" 2>/dev/null; then
        info "  Inference OK — ${VERIFY_MODEL} is working"
    else
        die "Inference check failed for ${VERIFY_MODEL}. Aborting — old models NOT removed."
    fi
    echo ""
fi

# ---------------------------------------------------------------------------
# 3. Remove old models
# ---------------------------------------------------------------------------
echo "--- Step 3: Remove deprecated models ---"
AVAILABLE=$(ollama list 2>/dev/null | awk 'NR>1 {print $1}')
for model in "${OLD_MODELS[@]}"; do
    if echo "${AVAILABLE}" | grep -q "^${model}"; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            dryrun "would remove: $model"
        else
            info "Removing $model..."
            ollama rm "$model"
            info "  removed: $model"
        fi
    else
        info "  not present (already gone): $model"
    fi
done
echo ""

# ---------------------------------------------------------------------------
# 4. Summary
# ---------------------------------------------------------------------------
echo "--- Step 4: Current model list ---"
if [[ "$DRY_RUN" -eq 0 ]]; then
    ollama list
    echo ""
    echo "GPU VRAM after migration:"
    nvidia-smi --query-gpu=name,memory.used,memory.free --format=csv,noheader 2>/dev/null \
        || warn "nvidia-smi not available"
fi

echo ""
echo "=== Migration complete ==="
echo ""
echo "Next steps:"
echo "  1. Run smoke-test.sh to confirm all services still pass:"
echo "       bash ~/lab-llm-server/smoke-test.sh"
echo "  2. Pull the updated workspace template in each project repo:"
echo "       git -C ~/lab-workspace-template pull"
echo "  3. In Roo Code: reload the window (F1 → Developer: Reload Window)"
echo "     then set sticky model per mode (see client README Quick Start)."
