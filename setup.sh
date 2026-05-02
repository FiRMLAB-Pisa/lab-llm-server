#!/usr/bin/env bash
# =============================================================================
# Lab LLM Server Setup Script
# Run this on the lab server (A40 48GB) as a user with sudo access.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --------------------------------------------------------------------------- #
# Configuration — edit these if needed
# --------------------------------------------------------------------------- #
# llama-server (main inference backend, port 11434)
# Model: Qwen3.6 35B A3B MoE, Q4_K_M quantisation (~24 GB weights)
# Context: 256K × 3 parallel slots = 786432 tokens total
# KV cache quantised to q4_0 (halves KV VRAM vs F16 default)
# Flash attention enabled to reduce VRAM spikes at long context
# Reasoning: --reasoning-format deepseek puts thinking in reasoning_content,
#   which Roo Code openai-compatible provider (v3.18+) streams natively.
LLAMA_SERVER_BIN="${LLAMA_SERVER_BIN:-llama-server}"
LLAMA_MODEL_PATH="${LLAMA_MODEL_PATH:-/opt/llm/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf}"
LLAMA_PORT="11434"
LLAMA_CONTEXT="786432"   # 256K × 3 parallel slots
LLAMA_PARALLEL="3"       # 3 concurrent users; requests beyond 3 are queued

# Ollama is kept only for:
#   - nomic-embed-text  (Roo Code codebase indexing via Qdrant)
#   - starcoder2:3b     (tab autocomplete on port 11435)
# It is bound to 127.0.0.1 only (not LAN-accessible) to avoid port conflicts.
OLLAMA_MODELS_DIR="/var/lib/ollama/models"
OLLAMA_HOST="127.0.0.1:11436"   # internal-only; embeddings + autocomplete only
OLLAMA_MAX_LOADED_MODELS="2"    # nomic-embed-text + starcoder2:3b
OLLAMA_NUM_PARALLEL="1"

# Set to 1 to disable SSL certificate verification for HuggingFace Hub downloads.
# Use this only if your lab network intercepts HTTPS with a self-signed certificate.
# WARNING: This disables SSL verification and is a security risk. Only use in trusted
# internal lab networks, never on machines exposed to the internet.
DISABLE_SSL_VERIFY_FOR_HF="${DISABLE_SSL_VERIFY_FOR_HF:-0}"

# Optional pre-fetched asset cache (populated by prefetch-llm-assets.sh run on
# a fast machine and rsync'd here).  Create the directory on aleatico2 with:
#   sudo mkdir -p /srv/llm-cache && sudo chmod 1777 /srv/llm-cache
# Leave empty to always download from the internet.
PRELOAD_DIR="/srv/llm-cache"

# Models to pull (Ollama registry tags — embedding + autocomplete only)
# nomic-embed-text   → Roo Code codebase indexing via Qdrant (~300 MB, CPU)
# starcoder2:3b      → Tab autocomplete (FIM, ~2 GB VRAM, ~150 ms latency, port 11435)
OLLAMA_MODELS=(
    "nomic-embed-text"
    "starcoder2:3b"
)

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
info()  { echo "[INFO]  $*"; }
warn()  { echo "[WARN]  $*"; }
die()   { echo "[ERROR] $*" >&2; exit 1; }
require_cmd() { command -v "$1" &>/dev/null || die "Required command '$1' not found."; }

install_python_venv_deps() {
    # Best-effort install of system packages needed for python -m venv + pip.
    if command -v apt-get &>/dev/null; then
        sudo apt-get update -y
        sudo apt-get install -y python3-venv python3-pip
    elif command -v dnf &>/dev/null; then
        sudo dnf install -y python3-pip python3-virtualenv
    elif command -v yum &>/dev/null; then
        sudo yum install -y python3-pip python3-virtualenv
    elif command -v zypper &>/dev/null; then
        sudo zypper --non-interactive install python3-pip python3-virtualenv
    else
        warn "No supported package manager found to auto-install python venv deps."
    fi
}

# --------------------------------------------------------------------------- #
# 1. Install llama-server (main inference backend)
# --------------------------------------------------------------------------- #
info "Setting up llama-server (main inference backend)..."

# Check if llama-server is already available in PATH or at a standard location.
LLAMA_FOUND=0
for candidate in "${LLAMA_SERVER_BIN}" /usr/local/bin/llama-server /opt/llama.cpp/build/bin/llama-server; do
    if [[ -x "${candidate}" ]]; then
        info "Found llama-server at ${candidate}."
        LLAMA_SERVER_BIN="${candidate}"
        LLAMA_FOUND=1
        break
    fi
done

if [[ "${LLAMA_FOUND}" -eq 0 ]]; then
    require_cmd cmake
    require_cmd make
    info "llama-server not found. Building llama.cpp from source with CUDA support..."
    BUILD_DIR="/opt/llama.cpp"
    sudo mkdir -p "${BUILD_DIR}"
    sudo chown "${USER}:${USER}" "${BUILD_DIR}"
    if [[ ! -d "${BUILD_DIR}/.git" ]]; then
        git clone --depth 1 https://github.com/ggerganov/llama.cpp "${BUILD_DIR}"
    else
        git -C "${BUILD_DIR}" pull --ff-only
    fi
    cmake -B "${BUILD_DIR}/build" -S "${BUILD_DIR}" -DGGML_CUDA=ON -DCMAKE_BUILD_TYPE=Release
    cmake --build "${BUILD_DIR}/build" --config Release -j"$(nproc)"
    sudo cp "${BUILD_DIR}/build/bin/llama-server" /usr/local/bin/llama-server
    sudo chmod +x /usr/local/bin/llama-server
    LLAMA_SERVER_BIN="/usr/local/bin/llama-server"
    info "llama-server built and installed to /usr/local/bin/llama-server"
fi

# Verify GPU is visible
info "Verifying llama-server GPU detection..."
if "${LLAMA_SERVER_BIN}" --version 2>&1 | grep -qi "cuda\|gpu"; then
    info "✓ llama-server reports CUDA support."
elif nvidia-smi &>/dev/null; then
    info "GPU found via nvidia-smi; llama-server CUDA support assumed (--version silent on GPU)."
else
    warn "Could not confirm GPU detection. llama-server will still run but may fall back to CPU."
fi

# --------------------------------------------------------------------------- #
# 1b. Download Qwen3.6-35B-A3B-UD-Q4_K_M model
# --------------------------------------------------------------------------- #
info "Checking for Qwen3.6 model..."
sudo mkdir -p "$(dirname "${LLAMA_MODEL_PATH}")"
if [[ -f "${LLAMA_MODEL_PATH}" ]]; then
    info "Model already present at ${LLAMA_MODEL_PATH}. Skipping download."
else
    require_cmd curl
    info "Downloading Qwen3.6-35B-A3B-UD-Q4_K_M.gguf from HuggingFace (unsloth)..."
    HF_URL="https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf"
    CURL_FLAGS="-fL --progress-bar"
    if [[ "${DISABLE_SSL_VERIFY_FOR_HF}" == "1" ]]; then
        CURL_FLAGS="${CURL_FLAGS} --insecure"
        warn "SSL verification disabled for HuggingFace download (DISABLE_SSL_VERIFY_FOR_HF=1)."
    fi
    sudo curl ${CURL_FLAGS} -o "${LLAMA_MODEL_PATH}" "${HF_URL}"
    info "Model downloaded to ${LLAMA_MODEL_PATH}."
fi

# --------------------------------------------------------------------------- #
# 1c. Install llama-server systemd service
# --------------------------------------------------------------------------- #
info "Installing llama-server systemd service..."
sudo tee /opt/llm/start-llama-server.sh > /dev/null <<EOF
#!/bin/bash
# llama-server startup script — managed by lab LLM setup
# Model:   Qwen3.6-35B-A3B-UD-Q4_K_M (MoE, ~24 GB weights at Q4_K_M)
# Context: 256K × 3 parallel slots = 786432 tokens (q4_0 KV cache)
# VRAM budget: ~24 GB weights + ~18 GB KV cache at 786k = ~42 GB + 3 GB overhead ≈ 45 GB
# Exposed: 0.0.0.0:11434 (OpenAI-compatible, LAN/VPN accessible)

exec ${LLAMA_SERVER_BIN} \\
  -m ${LLAMA_MODEL_PATH} \\
  -c ${LLAMA_CONTEXT} \\
  --parallel ${LLAMA_PARALLEL} \\
  -ngl 99 \\
  --flash-attn \\
  --no-mmap \\
  --cache-type-k q4_0 \\
  --cache-type-v q4_0 \\
  --jinja \\
  --chat-template-kwargs '{"enable_thinking":true,"preserve_thinking":true}' \\
  --cache-ram 8192 \\
  --reasoning-format deepseek \\
  --temp 0.6 \\
  --top-k 20 \\
  --top-p 0.95 \\
  --batch-size 512 \\
  --ubatch-size 512 \\
  --host 0.0.0.0 \\
  --port ${LLAMA_PORT}
EOF
sudo chmod +x /opt/llm/start-llama-server.sh

sudo tee /etc/systemd/system/llama-server.service > /dev/null <<'SVCEOF'
[Unit]
Description=llama-server — local LLM inference (Qwen3.6-35B-A3B)
After=network.target
Wants=network.target

[Service]
Type=simple
ExecStart=/opt/llm/start-llama-server.sh
Restart=always
RestartSec=10
# Allow large VRAM allocations
LimitMEMLOCK=infinity
# Logging
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
SVCEOF

sudo systemctl daemon-reload
sudo systemctl enable llama-server
sudo systemctl restart llama-server
info "llama-server service enabled and (re)started."

# Wait for llama-server to be ready
info "Waiting for llama-server to be ready (may take ~30s on first load)..."
for i in {1..30}; do
    if curl -sf "http://127.0.0.1:${LLAMA_PORT}/health" > /dev/null 2>&1; then
        info "✓ llama-server is ready."
        break
    fi
    sleep 3
    if [[ $i -eq 30 ]]; then
        warn "llama-server did not respond in time. Check: journalctl -u llama-server -n 50"
    fi
done

# Verify binding to 0.0.0.0:11434
if ss -tlnp 2>/dev/null | grep -q "0.0.0.0:${LLAMA_PORT}"; then
    info "✓ llama-server bound to 0.0.0.0:${LLAMA_PORT} (LAN/VPN accessible)"
else
    warn "llama-server not yet bound to 0.0.0.0:${LLAMA_PORT} — may still be loading the model."
fi

# Print VRAM usage after load
info "GPU VRAM after llama-server load:"
nvidia-smi --query-gpu=name,memory.used,memory.free,memory.total \
    --format=csv,noheader 2>/dev/null || warn "nvidia-smi not found."

# --------------------------------------------------------------------------- #
# 1d. Install Ollama (embedding + autocomplete only, internal port 11436)
# --------------------------------------------------------------------------- #
info "Installing Ollama (embedding + autocomplete backend, port 11436)..."
OLLAMA_CACHED_BIN="${PRELOAD_DIR}/ollama"
if command -v ollama &>/dev/null && ollama --version &>/dev/null 2>&1; then
    CURRENT_VER=$(ollama --version 2>/dev/null | awk '{print $NF}')
    info "Ollama already installed (${CURRENT_VER}). Skipping install."
elif [[ -x "${OLLAMA_CACHED_BIN}" ]]; then
    info "Found cached Ollama binary at ${OLLAMA_CACHED_BIN} — installing from cache."
    sudo cp "${OLLAMA_CACHED_BIN}" /usr/local/bin/ollama
    sudo chmod +x /usr/local/bin/ollama
    info "Ollama installed from cache."
else
    require_cmd curl
    info "Downloading Ollama from internet..."
    curl -fsSL https://ollama.com/install.sh | sh
    info "Ollama installed."
fi

# --------------------------------------------------------------------------- #
# 2. Configure Ollama via systemd drop-in (internal only, port 11436)
# --------------------------------------------------------------------------- #
info "Configuring Ollama systemd service (embeddings + autocomplete, port 11436)..."
DROPIN_DIR="/etc/systemd/system/ollama.service.d"
sudo mkdir -p "${DROPIN_DIR}"

# Ensure Ollama model directory exists and is writable by the service user.
if ! getent passwd ollama >/dev/null; then
    info "Creating system user 'ollama'..."
    sudo useradd -r -s /usr/sbin/nologin -U ollama
fi
sudo mkdir -p "${OLLAMA_MODELS_DIR}"
sudo chown -R ollama:ollama "$(dirname "${OLLAMA_MODELS_DIR}")"
sudo chmod 750 "$(dirname "${OLLAMA_MODELS_DIR}")"

sudo tee "${DROPIN_DIR}/override.conf" > /dev/null <<EOF
# Ollama lab configuration — managed by lab LLM setup
# Ollama serves embeddings (nomic-embed-text) and autocomplete (starcoder2:3b) only.
# Main inference is handled by llama-server on port 11434.
# Bound to 127.0.0.1:11436 — not LAN-accessible (internal use only).
[Service]
Environment="OLLAMA_HOST=${OLLAMA_HOST}"
Environment="OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
Environment="OLLAMA_KEEP_ALIVE=30m"
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
Environment="OLLAMA_MODELS=${OLLAMA_MODELS_DIR}"
Environment="OLLAMA_FLASH_ATTENTION=1"
Environment="OLLAMA_KV_CACHE_TYPE=q8_0"
EOF

sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl restart ollama
info "Ollama service configured and (re)started on port 11436."

# --------------------------------------------------------------------------- #
# 2b. Install dedicated autocomplete Ollama instance (port 11435)
# --------------------------------------------------------------------------- #
info "Installing Ollama autocomplete service (starcoder2:3b on port 11435)..."
# Patch the models dir in case it differs from the default
AUTOCOMPLETE_SERVICE="/etc/systemd/system/ollama-autocomplete.service"
sudo cp "${SCRIPT_DIR}/ollama-autocomplete.service" "${AUTOCOMPLETE_SERVICE}"
sudo sed -i "s|OLLAMA_MODELS=/var/lib/ollama/models|OLLAMA_MODELS=${OLLAMA_MODELS_DIR}|"\
    "${AUTOCOMPLETE_SERVICE}"
sudo systemctl daemon-reload
sudo systemctl enable ollama-autocomplete
sudo systemctl restart ollama-autocomplete
info "Autocomplete Ollama service started on port 11435."

# Wait for autocomplete instance to be ready
for i in {1..15}; do
    if curl -sf http://127.0.0.1:11435/api/tags > /dev/null 2>&1; then
        info "Autocomplete Ollama is ready."
        break
    fi
    sleep 2
    if [[ $i -eq 15 ]]; then
        warn "Autocomplete Ollama did not start in time. Check: journalctl -u ollama-autocomplete -n 50"
    fi
done

# Wait for Ollama (embedding instance) to be ready
info "Waiting for Ollama embedding instance to be ready..."
for i in {1..15}; do
    if curl -sf http://127.0.0.1:11436/api/tags > /dev/null 2>&1; then
        info "Ollama embedding instance is ready."
        break
    fi
    sleep 2
    if [[ $i -eq 15 ]]; then
        die "Ollama embedding instance did not start in time. Check: journalctl -u ollama -n 50"
    fi
done

# Verify Ollama embedding instance is on 127.0.0.1:11436 (must NOT be LAN-accessible)
if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:11436"; then
    info "✓ Ollama embedding instance bound to 127.0.0.1:11436 (internal only)"
else
    warn "Ollama embedding instance not bound to 127.0.0.1:11436 — check systemd drop-in config"
fi

# --------------------------------------------------------------------------- #
# 3. Cleanup legacy services (OpenHands, LiteLLM)
# --------------------------------------------------------------------------- #
info "Stopping and removing legacy services (OpenHands, LiteLLM)..."

# Stop and disable OpenHands if running
if docker compose -f "${SCRIPT_DIR}/openhands-compose.yml" ps --services 2>/dev/null | grep -q .; then
    info "Stopping OpenHands containers..."
    docker compose -f "${SCRIPT_DIR}/openhands-compose.yml" down --remove-orphans 2>/dev/null || true
fi
# Remove OpenHands images to free disk space
for img in docker.all-hands.dev/all-hands-ai/runtime docker.all-hands.dev/all-hands-ai/openhands; do
    if docker image ls --format '{{.Repository}}' 2>/dev/null | grep -q "${img}"; then
        info "Removing OpenHands image: ${img}"
        docker image rm "${img}" 2>/dev/null || true
    fi
done

# Stop and remove LiteLLM if running
if [[ -f "${SCRIPT_DIR}/litellm-compose.yml" ]]; then
    if docker compose -f "${SCRIPT_DIR}/litellm-compose.yml" ps --services 2>/dev/null | grep -q .; then
        info "Stopping LiteLLM containers..."
        docker compose -f "${SCRIPT_DIR}/litellm-compose.yml" down --remove-orphans 2>/dev/null || true
    fi
    for img in ghcr.io/berriai/litellm; do
        if docker image ls --format '{{.Repository}}' 2>/dev/null | grep -q "${img}"; then
            info "Removing LiteLLM image: ${img}"
            docker image rm "${img}" 2>/dev/null || true
        fi
    done
fi

info "Legacy service cleanup done."

# --------------------------------------------------------------------------- #
# 3b. Install gpu-clear script
# --------------------------------------------------------------------------- #
info "Installing gpu-clear script..."
sudo cp "$(dirname "$0")/gpu-clear" /usr/local/bin/gpu-clear
sudo chmod +x /usr/local/bin/gpu-clear
info "gpu-clear installed to /usr/local/bin/gpu-clear"

# --------------------------------------------------------------------------- #
# 4. Pull Ollama models (embedding + autocomplete only)
# --------------------------------------------------------------------------- #
info "Pulling Ollama models (embedding + autocomplete)..."

# If a pre-fetched model cache exists, seed OLLAMA_MODELS_DIR from it first.
PRELOAD_MODELS="${PRELOAD_DIR}/models"
if [[ -d "${PRELOAD_MODELS}/blobs" ]]; then
    info "Found pre-fetched model cache at ${PRELOAD_MODELS} — seeding model store..."
    sudo mkdir -p "${OLLAMA_MODELS_DIR}"
    sudo rsync -a --ignore-existing "${PRELOAD_MODELS}/" "${OLLAMA_MODELS_DIR}/"
    info "Model cache seeded. ollama pull will skip already-present blobs."
fi

for model in "${OLLAMA_MODELS[@]}"; do
    OLLAMA_HOST=127.0.0.1:11436 ollama list | awk 'NR>1 {print $1}' | grep -Fxq "${model}" \
        && info "Already present locally, skipping pull: ${model}" \
        || { info "Pulling ${model}..."; OLLAMA_HOST=127.0.0.1:11436 ollama pull "${model}"; info "Done: ${model}"; }
done

# Remove LLM models that are no longer part of the active stack (LiteLLM/Qwen3.5 era).
# llama-server now serves all chat inference; these Ollama models are stale.
STALE_MODELS=(
    "qwen3.5:35b"
    "qwen3.5:27b-q8_0"
    "qwen3.5:9b"
    "devstral-small-2"
    "deepseek-r1:32b"
    "qwen2.5-coder:14b"
    "deepseek-r1:7b"
)
for model in "${STALE_MODELS[@]}"; do
    if OLLAMA_HOST=127.0.0.1:11436 ollama list | awk 'NR>1 {print $1}' | grep -Fxq "${model}"; then
        info "Removing stale model from Ollama: ${model}"
        OLLAMA_HOST=127.0.0.1:11436 ollama rm "${model}"
    fi
done

# --------------------------------------------------------------------------- #
# 5. Install Docker (needed for SearXNG and Qdrant)
# --------------------------------------------------------------------------- #
info "Checking Docker..."
if command -v docker &>/dev/null; then
    info "Docker already installed ($(docker --version)). Skipping install."
else
    info "Installing Docker..."
    require_cmd curl
    curl -fsSL https://get.docker.com | sh
    # Allow the current user to run docker without sudo
    sudo usermod -aG docker "${USER}"
    info "Docker installed. NOTE: you may need to log out and back in for"
    info "the docker group to take effect.  If the next step fails, run:"
    info "  newgrp docker && sudo bash setup.sh"
fi

sudo systemctl enable docker
sudo systemctl start docker

# --------------------------------------------------------------------------- #
# 6. Install lab knowledge MCP service
# --------------------------------------------------------------------------- #
info "Installing lab knowledge MCP service..."
INSTALL_DIR="/opt/lab-server"
KNOWLEDGE_DIR="/opt/lab-knowledge"
LAB_CONDA_PY="/opt/conda/envs/lab-mcp/bin/python"
LAB_VENV_DIR="${INSTALL_DIR}/.venv-lab-mcp"

# Ensure Python packages are available for lab services.
# Prefer the shared conda env when present; otherwise fall back to a local venv.
LAB_PY="${LAB_CONDA_PY}"
if [[ ! -x "${LAB_PY}" ]]; then
    info "lab-mcp conda env not found. Trying to create it..."
    if command -v mamba &>/dev/null; then
        mamba create -n lab-mcp python=3.11 -y
    elif command -v conda &>/dev/null; then
        conda create -n lab-mcp python=3.11 -y
    else
        info "conda/mamba not found — using system python venv fallback."
        require_cmd python3
        sudo mkdir -p "${INSTALL_DIR}"
        if [[ ! -x "${LAB_VENV_DIR}/bin/python" ]]; then
            if ! sudo python3 -m venv "${LAB_VENV_DIR}"; then
                warn "python3 -m venv failed; attempting to install venv dependencies..."
                install_python_venv_deps
                sudo python3 -m venv "${LAB_VENV_DIR}" || \
                    die "Failed to create venv at ${LAB_VENV_DIR}."
            fi
        fi

        # Some distro builds create venv without pip unless python3-venv is installed.
        if ! sudo "${LAB_VENV_DIR}/bin/python" -m pip --version &>/dev/null; then
            warn "pip missing in venv; attempting bootstrap via ensurepip..."
            if ! sudo "${LAB_VENV_DIR}/bin/python" -m ensurepip --upgrade; then
                warn "ensurepip failed; attempting to install system python venv dependencies..."
                install_python_venv_deps
                if ! sudo "${LAB_VENV_DIR}/bin/python" -m ensurepip --upgrade; then
                    die "Could not bootstrap pip in ${LAB_VENV_DIR}. Install python3-venv and retry."
                fi
            fi
        fi
        sudo "${LAB_VENV_DIR}/bin/python" -m pip install -q --upgrade pip
        LAB_PY="${LAB_VENV_DIR}/bin/python"
    fi
fi
if [[ ! -x "${LAB_PY}" ]]; then
    LAB_PY="${LAB_CONDA_PY}"
fi
info "Installing/upgrading Python packages in lab-mcp env..."
sudo "${LAB_PY}" -m pip install -q --upgrade fastmcp numpy requests "rank-bm25" "sentence-transformers" uvicorn
info "Python packages ready."

# Pre-download the cross-encoder reranker model so the first query isn't slow.
# Model is 66 MB and cached to ~/.cache/huggingface/ — downloaded once, used forever.
# Reranker is optional: lab knowledge search works fine with vector+BM25 alone.
# If HuggingFace is unreachable (SSL inspection, firewall, etc.), skip silently
# and gracefully degrade. First query will be slower, but will work.
# Reranker model is optional and requires internet access without SSL inspection.
# Lab knowledge retrieval works fine with vector+BM25 alone (graceful degradation).
info "Reranker model pre-download (optional, skip if unreachable)..."

HF_CACHE_DIR="/opt/lab-server/hf-cache"
RERANKER_CACHE="${HF_CACHE_DIR}/hub/models--cross-encoder--ms-marco-MiniLM-L6-v2"
sudo mkdir -p "${HF_CACHE_DIR}/hub" "${HF_CACHE_DIR}/transformers"
if [[ -d "${RERANKER_CACHE}" ]]; then
    info "Reranker model already cached."
else
    # Try to download using curl --insecure (bypasses SSL cert verification)
    DOWNLOAD_SCRIPT="${SCRIPT_DIR}/download-reranker.sh"
    if [[ -f "${DOWNLOAD_SCRIPT}" ]]; then
        info "Attempting to download reranker model using curl --insecure..."
        # Run as root and place artifacts in a shared cache path used by the service.
        if timeout 180 sudo HF_HOME="${HF_CACHE_DIR}" bash "${DOWNLOAD_SCRIPT}"; then
            info "Reranker model downloaded successfully."
        else
            warn "Reranker download failed. Lab knowledge will use vector+BM25 only."
            warn "To add it manually:"
            warn "  1. scp -r ./models--cross-encoder--ms-marco-MiniLM-L6-v2 <user>@aleatico2:/tmp/"
            warn "  2. ssh <user>@aleatico2 'sudo mkdir -p ${HF_CACHE_DIR}/hub && sudo mv /tmp/models--cross-encoder--ms-marco-MiniLM-L6-v2 ${HF_CACHE_DIR}/hub/'"
        fi
    else
        warn "Reranker download script not found at ${DOWNLOAD_SCRIPT}."
        warn "Lab knowledge will use vector+BM25 only (fully functional)."
    fi
fi

# Create directories
sudo mkdir -p "${INSTALL_DIR}" "${KNOWLEDGE_DIR}"
sudo chmod 755 "${KNOWLEDGE_DIR}"

# Copy scripts
sudo cp "${SCRIPT_DIR}/lab-knowledge-index.py"  "${INSTALL_DIR}/"
sudo cp "${SCRIPT_DIR}/lab-knowledge-server.py" "${INSTALL_DIR}/"
sudo chmod 755 "${INSTALL_DIR}/lab-knowledge-index.py" \
               "${INSTALL_DIR}/lab-knowledge-server.py"

# Install systemd units
sudo cp "${SCRIPT_DIR}/lab-knowledge.service"       /etc/systemd/system/
sudo cp "${SCRIPT_DIR}/lab-knowledge-index.service" /etc/systemd/system/
sudo cp "${SCRIPT_DIR}/lab-knowledge-index.timer"   /etc/systemd/system/
# Patch unit files to use the interpreter selected above (conda or venv fallback).
# Use printf to properly escape the replacement path, then apply sed.
ESCAPED_LAB_PY=$(printf '%s\n' "${LAB_PY}" | sed -e 's/[\/&]/\\&/g')
sudo sed -i "s|ExecStart=/opt/conda/envs/lab-mcp/bin/python|ExecStart=${ESCAPED_LAB_PY}|" \
    /etc/systemd/system/lab-knowledge.service \
    /etc/systemd/system/lab-knowledge-index.service
# Verify the patch was applied
if grep -q "${LAB_PY}" /etc/systemd/system/lab-knowledge.service; then
    info "Lab knowledge systemd units patched successfully."
else
    warn "Lab knowledge systemd units patch may have failed. Check manually:"
    warn "  cat /etc/systemd/system/lab-knowledge.service | grep ExecStart"
fi

# --------------------------------------------------------------------------- #
# Manual one-time index build with progress bar (recommended for setup)
# --------------------------------------------------------------------------- #
info "Building lab knowledge index interactively (progress bar visible)..."
sudo "${LAB_PY}" /opt/lab-server/lab-knowledge-index.py
info "Manual index build complete."

# --------------------------------------------------------------------------- #
# Enable and start nightly auto-indexing (systemd timer)
# --------------------------------------------------------------------------- #
info "Enabling and starting nightly lab-knowledge-index.timer..."
sudo systemctl enable --now lab-knowledge-index.timer
info "Nightly lab-knowledge-index.timer is active. To monitor background runs: journalctl -fu lab-knowledge-index"
sudo systemctl daemon-reload
sudo systemctl enable lab-knowledge.service lab-knowledge-index.timer
if ! sudo systemctl restart lab-knowledge.service; then
    warn "lab-knowledge.service failed to restart; continuing setup. Check: journalctl -u lab-knowledge -n 50"
fi
if ! sudo systemctl restart lab-knowledge-index.timer; then
    warn "lab-knowledge-index.timer failed to restart; continuing setup."
fi

info ""
info "Lab knowledge MCP service started on port 3001."
info "Populate ${KNOWLEDGE_DIR}/ with repos and docs, then trigger a first index:"
info "  sudo systemctl start lab-knowledge-index.service"
info "  journalctl -fu lab-knowledge-index  # watch progress"
info ""
info "Or add repos now and re-run setup.sh — the timer will index them nightly."

# --------------------------------------------------------------------------- #
# 7. Install lab status dashboard
# --------------------------------------------------------------------------- #
info "Installing lab status dashboard..."
sudo cp "${SCRIPT_DIR}/lab-status-server.py" "${INSTALL_DIR}/"
sudo chmod 755 "${INSTALL_DIR}/lab-status-server.py"
sudo cp "${SCRIPT_DIR}/lab-status.service" /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable lab-status.service
if ! sudo systemctl restart lab-status.service; then
    warn "lab-status.service failed to restart; continuing setup. Check: journalctl -u lab-status -n 50"
fi
info "Lab status dashboard started on port 3002."

# --------------------------------------------------------------------------- #
# 8. Install web search (SearXNG + web search MCP)
# --------------------------------------------------------------------------- #
info "Starting SearXNG (self-hosted meta search engine)..."
docker compose -f "${SCRIPT_DIR}/searxng-compose.yml" pull --quiet
docker compose -f "${SCRIPT_DIR}/searxng-compose.yml" up -d
info "SearXNG started on 127.0.0.1:8080 (internal only)."

info "Installing web search MCP server..."
sudo cp "${SCRIPT_DIR}/lab-websearch-server.py" "${INSTALL_DIR}/"
sudo chmod 755 "${INSTALL_DIR}/lab-websearch-server.py"
sudo cp "${SCRIPT_DIR}/lab-websearch.service" /etc/systemd/system/
# Patch websearch service to use the correct Python interpreter
sudo sed -i "s|ExecStart=/opt/conda/envs/lab-mcp/bin/python|ExecStart=${ESCAPED_LAB_PY}|" \
    /etc/systemd/system/lab-websearch.service
sudo systemctl daemon-reload
sudo systemctl enable lab-websearch.service
if ! sudo systemctl restart lab-websearch.service; then
    warn "lab-websearch.service failed to restart; continuing setup. Check: journalctl -u lab-websearch -n 50"
fi
info "Web search MCP server started on port 3003."
info "NOTE: Web search requires internet access on aleatico2."
info "      If the lab firewall drops the connection, re-authenticate and"
info "      run: sudo systemctl restart lab-websearch"

# --------------------------------------------------------------------------- #
# 9. Start Qdrant (vector database for Roo Code codebase indexing)
# --------------------------------------------------------------------------- #
info "Starting Qdrant vector database (Roo Code codebase indexing)..."
docker compose -f "${SCRIPT_DIR}/qdrant-compose.yml" pull --quiet
docker compose -f "${SCRIPT_DIR}/qdrant-compose.yml" up -d
info "Qdrant started on 0.0.0.0:6333 (LAN/VPN accessible)."
info "Roo Code codebase indexing settings:"
info "  Embedder Provider : Ollama"
info "  Base URL          : http://aleatico2.imago7.local:11436"
info "  API Key           : (leave empty)"
info "  Model             : nomic-embed-text"
info "  Model Dimension   : 768"
info "  Qdrant URL        : http://aleatico2.imago7.local:6333"
info "  Qdrant API Key    : (leave empty)"

# Ensure embedding model is present (needed by lab-knowledge indexing/search).
if OLLAMA_HOST=127.0.0.1:11436 ollama list | awk 'NR>1 {print $1}' | grep -Eq '^nomic-embed-text(:|$)'; then
    info "Embedding model already present: nomic-embed-text"
else
    info "Pulling required embedding model: nomic-embed-text..."
    OLLAMA_HOST=127.0.0.1:11436 ollama pull nomic-embed-text
fi

# --------------------------------------------------------------------------- #
# 11. Verify
# --------------------------------------------------------------------------- #
info ""
info "=== Setup complete. Verification ==="
info ""
info "llama-server status:"
systemctl is-active llama-server && info "  ✓ llama-server.service is active" || warn "  ✗ llama-server.service is NOT active"

info ""
info "GPU memory usage:"
nvidia-smi --query-gpu=name,memory.used,memory.free,memory.total --format=csv,noheader 2>/dev/null || \
    warn "nvidia-smi not found — check GPU manually."

info ""
info "Test the OpenAI-compatible API (llama-server — what Roo Code uses):"
info "  curl http://127.0.0.1:11434/v1/models"
info "  curl http://aleatico2.imago7.local:11434/v1/models"
info ""
info "Test embeddings (Ollama internal instance):"
info "  OLLAMA_HOST=127.0.0.1:11436 ollama list"
info ""
info "To manually flush GPU memory before a CUDA job:"
info "  gpu-clear"
info ""
info "Lab knowledge MCP:            http://aleatico2.imago7.local:3001/sse"
info "Lab status dashboard:          http://aleatico2.imago7.local:3002"
info "Web search MCP:                http://aleatico2.imago7.local:3003/sse"
info "llama-server (Roo Code/LLM):  http://aleatico2.imago7.local:11434/v1"
info ""
info "Each lab member should run onboard.sh once from a VSCode Remote-SSH terminal."
