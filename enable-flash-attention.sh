#!/usr/bin/env bash
# =============================================================================
# enable-flash-attention.sh — Enable Flash Attention 2 for Ollama on aleatico2
#
# What Flash Attention does:
#   Standard attention computes a full N×N attention matrix (N = sequence length)
#   and stores it in VRAM. Flash Attention 2 rewrites the algorithm to process
#   attention in tiles that stay in the GPU's fast on-chip SRAM, never
#   materialising the full matrix. The result:
#     - ~2–4× less VRAM for the KV-cache (critical for long contexts)
#     - ~20–30% faster prefill (processing the prompt) on A40-class GPUs
#     - No change to model quality — mathematically identical output
#   The win is most visible on long prompts (Orchestrator with many tool results,
#   big code files passed as context). Short single-turn messages: minimal gain.
#
# Run once on aleatico2 as a user with sudo access:
#   bash ~/lab-llm-server/enable-flash-attention.sh
#
# Idempotent — safe to re-run.
# =============================================================================
set -euo pipefail

info() { echo "[flash-attn] $*"; }
warn() { echo "[flash-attn] WARNING: $*"; }

DROPIN_DIR="/etc/systemd/system/ollama.service.d"
DROPIN_FILE="${DROPIN_DIR}/flash-attention.conf"

# --------------------------------------------------------------------------- #
# 1. Write (or overwrite) the drop-in
# --------------------------------------------------------------------------- #
info "Writing systemd drop-in: ${DROPIN_FILE}"
sudo mkdir -p "${DROPIN_DIR}"
sudo tee "${DROPIN_FILE}" > /dev/null <<'EOF'
# Flash Attention 2 for Ollama — managed by enable-flash-attention.sh
[Service]
Environment="OLLAMA_FLASH_ATTENTION=1"
EOF
info "Drop-in written."

# --------------------------------------------------------------------------- #
# 2. Reload systemd and restart Ollama
# --------------------------------------------------------------------------- #
info "Reloading systemd daemon..."
sudo systemctl daemon-reload

info "Restarting Ollama (takes ~5 seconds)..."
sudo systemctl restart ollama

# --------------------------------------------------------------------------- #
# 3. Wait for Ollama to be ready
# --------------------------------------------------------------------------- #
info "Waiting for Ollama to be ready..."
for i in {1..15}; do
    if curl -sf http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        info "Ollama is ready."
        break
    fi
    sleep 2
    if [[ $i -eq 15 ]]; then
        echo "[flash-attn] ERROR: Ollama did not start in time." >&2
        echo "             Check: journalctl -u ollama -n 50" >&2
        exit 1
    fi
done

# --------------------------------------------------------------------------- #
# 4. Verify the env var is live
# --------------------------------------------------------------------------- #
info "Verifying configuration..."
if sudo systemctl show ollama --property=Environment | grep -q "OLLAMA_FLASH_ATTENTION=1"; then
    info "✓ OLLAMA_FLASH_ATTENTION=1 is active."
else
    warn "OLLAMA_FLASH_ATTENTION not visible in systemctl show — check the drop-in."
    warn "Run: sudo systemctl cat ollama"
fi

echo ""
echo "=== Flash Attention enabled ==="
echo "Models will use Flash Attention 2 from the next inference request."
echo "No model re-download needed."
echo ""
echo "Current GPU VRAM:"
nvidia-smi --query-gpu=name,memory.used,memory.free --format=csv,noheader 2>/dev/null || \
    warn "nvidia-smi not found — check VRAM manually."
