#!/usr/bin/env bash
# =============================================================================
# Lab LLM Server Setup Script
# Run this on the lab server (A40 48GB) as a user with sudo access.
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Configuration — edit these if needed
# --------------------------------------------------------------------------- #
OLLAMA_MODELS_DIR="/var/lib/ollama/models"   # where model weights are stored
OLLAMA_KEEP_ALIVE="30m"   # unload models after 30 min idle (frees GPU)
OLLAMA_MAX_LOADED_MODELS="2"   # keep 32B + 14B warm simultaneously
OLLAMA_NUM_PARALLEL="10"   # serve up to 10 concurrent requests per model
OPENHANDS_PULL_RETRIES="6"  # tolerate transient DNS/firewall hiccups
OPENHANDS_PULL_DELAY_SECS="15"
# Set to 1 to disable SSL certificate verification for HuggingFace Hub downloads.
# Use this only if your lab network intercepts HTTPS with a self-signed certificate.
# WARNING: This disables SSL verification and is a security risk. Only use in trusted
# internal lab networks, never on machines exposed to the internet.
DISABLE_SSL_VERIFY_FOR_HF="${DISABLE_SSL_VERIFY_FOR_HF:-0}"
# Bind to all interfaces so every lab server and VPN user can reach Ollama
# directly at http://aleatico2.imago7.local:11434 — no tunnel needed.
# This is safe on a trusted internal lab network (GlobalProtect VPN).
OLLAMA_HOST="0.0.0.0:11434"

# Optional pre-fetched asset cache (populated by prefetch-llm-assets.sh run on
# a fast machine and rsync'd here).  Create the directory on aleatico2 with:
#   sudo mkdir -p /srv/llm-cache && sudo chmod 1777 /srv/llm-cache
# Leave empty to always download from the internet.
PRELOAD_DIR="/srv/llm-cache"

# Models to pull (Ollama registry tags)
# deepseek-r1:32b   → Architect mode  (~20 GB VRAM, Q4_K_M)
# qwen2.5-coder:14b → Code/Agent mode (~9 GB VRAM, Q4_K_M)
# deepseek-r1:7b    → Ask mode        (~5 GB VRAM, Q4_K_M)
# nomic-embed-text  → Local codebase embeddings for Continue.dev @codebase RAG
#                     (~300 MB, runs on CPU — does not use the A40)
# starcoder2:3b      → Tab autocomplete (FIM, ~2 GB VRAM, ~150 ms latency)
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
# 1. Install Ollama
# --------------------------------------------------------------------------- #
info "Installing Ollama..."
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
# 2. Configure Ollama via systemd drop-in
# --------------------------------------------------------------------------- #
info "Configuring Ollama systemd service..."
DROPIN_DIR="/etc/systemd/system/ollama.service.d"
sudo mkdir -p "${DROPIN_DIR}"

# Ensure Ollama model directory exists and is writable by the service user.
# Some fresh installs do not pre-create /var/lib/ollama, causing startup to fail
# with: "permission denied: mkdir /var/lib/ollama".
if ! getent passwd ollama >/dev/null; then
    info "Creating system user 'ollama'..."
    sudo useradd -r -s /usr/sbin/nologin -U ollama
fi
sudo mkdir -p "${OLLAMA_MODELS_DIR}"
sudo chown -R ollama:ollama "$(dirname "${OLLAMA_MODELS_DIR}")"
sudo chmod 750 "$(dirname "${OLLAMA_MODELS_DIR}")"

sudo tee "${DROPIN_DIR}/override.conf" > /dev/null <<EOF
# Ollama lab configuration — managed by lab LLM setup
[Service]
# Bind to all interfaces so every lab server and VPN client can reach the API
# at http://aleatico2.imago7.local:11434 — no SSH tunnel needed.
Environment="OLLAMA_HOST=${OLLAMA_HOST}"
# Keep the two primary models (32B + 14B) loaded simultaneously
Environment="OLLAMA_MAX_LOADED_MODELS=${OLLAMA_MAX_LOADED_MODELS}"
# Auto-unload models after KEEP_ALIVE idle time (frees GPU for scientific jobs)
Environment="OLLAMA_KEEP_ALIVE=${OLLAMA_KEEP_ALIVE}"
# Accept up to 2 simultaneous requests without queueing
Environment="OLLAMA_NUM_PARALLEL=${OLLAMA_NUM_PARALLEL}"
# Where model weights are stored (ensure this partition has enough space)
Environment="OLLAMA_MODELS=${OLLAMA_MODELS_DIR}"
EOF

sudo systemctl daemon-reload
sudo systemctl enable ollama
sudo systemctl restart ollama
info "Ollama service configured and (re)started."

# Wait for Ollama to be ready
info "Waiting for Ollama to be ready..."
for i in {1..15}; do
    if curl -sf http://127.0.0.1:11434/api/tags > /dev/null 2>&1; then
        info "Ollama is ready."
        break
    fi
    sleep 2
    if [[ $i -eq 15 ]]; then
        die "Ollama did not start in time. Check: journalctl -u ollama -n 50"
    fi
done

# Verify binding to 0.0.0.0:11434 (required for LAN access)
if ss -tlnp 2>/dev/null | grep -q "0.0.0.0:11434"; then
    info "✓ Ollama bound to 0.0.0.0:11434 (LAN/VPN accessible)"
else
    warn "Ollama not bound to 0.0.0.0:11434 — it's only on 127.0.0.1"
    warn "Attempting to restart Ollama with explicit OLLAMA_HOST..."
    sudo systemctl stop ollama
    sleep 1
    sudo OLLAMA_HOST=0.0.0.0:11434 systemctl start ollama
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q "0.0.0.0:11434"; then
        info "✓ Ollama now bound to 0.0.0.0:11434"
    else
        warn "Ollama binding still not working. This may be a network configuration issue."
    fi
fi

# --------------------------------------------------------------------------- #
# 3. Install gpu-clear script
# --------------------------------------------------------------------------- #
info "Installing gpu-clear script..."
sudo cp "$(dirname "$0")/gpu-clear" /usr/local/bin/gpu-clear
sudo chmod +x /usr/local/bin/gpu-clear
info "gpu-clear installed to /usr/local/bin/gpu-clear"

# --------------------------------------------------------------------------- #
# 4. Pull models
# --------------------------------------------------------------------------- #
info "Pulling models — this will take a while on first run..."

# If a pre-fetched model cache exists, seed OLLAMA_MODELS_DIR from it first.
# ollama pull will then detect existing blobs and skip re-downloading them.
PRELOAD_MODELS="${PRELOAD_DIR}/models"
if [[ -d "${PRELOAD_MODELS}/blobs" ]]; then
    info "Found pre-fetched model cache at ${PRELOAD_MODELS} — seeding model store..."
    sudo mkdir -p "${OLLAMA_MODELS_DIR}"
    sudo rsync -a --ignore-existing "${PRELOAD_MODELS}/" "${OLLAMA_MODELS_DIR}/"
    info "Model cache seeded. ollama pull will skip already-present blobs."
fi

for model in "${MODELS[@]}"; do
    if ollama list | awk 'NR>1 {print $1}' | grep -Fxq "${model}"; then
        info "Already present locally, skipping pull: ${model}"
    else
        info "Pulling ${model}..."
        ollama pull "${model}"
        info "Done: ${model}"
    fi
done

# --------------------------------------------------------------------------- #
# 5. Install Docker (if not present) and start OpenHands
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

info "Starting OpenHands background agent..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
COMPOSE_FILE="${SCRIPT_DIR}/openhands-compose.yml"
[[ -f "${COMPOSE_FILE}" ]] || die "openhands-compose.yml not found at ${COMPOSE_FILE}"

# Heads-up for tight disks: OpenHands images plus writable layers are several GB.
FREE_GB=$(df -BG /var/lib/docker 2>/dev/null | awk 'NR==2{gsub("G","",$4); print $4}')
if [[ -n "${FREE_GB:-}" ]] && (( FREE_GB < 25 )); then
    warn "Only ${FREE_GB}G free on /var/lib/docker. OpenHands image pulls may fail."
    warn "If needed, clean old Docker cache: sudo docker system prune -af"
fi

pull_ok=0
for ((i=1; i<=OPENHANDS_PULL_RETRIES; i++)); do
    info "Pulling OpenHands images (attempt ${i}/${OPENHANDS_PULL_RETRIES})..."
    if docker compose -f "${COMPOSE_FILE}" pull --quiet; then
        pull_ok=1
        break
    fi
    if (( i < OPENHANDS_PULL_RETRIES )); then
        warn "OpenHands pull failed (attempt ${i}). Retrying in ${OPENHANDS_PULL_DELAY_SECS}s..."
        sleep "${OPENHANDS_PULL_DELAY_SECS}"
    fi
done

if (( pull_ok == 1 )); then
    if docker compose -f "${COMPOSE_FILE}" up -d; then
        info "OpenHands started — accessible at http://aleatico2.imago7.local:3000"
    else
        warn "OpenHands container failed to start. Continuing setup of remaining services."
        warn "Check logs: docker compose -f ${COMPOSE_FILE} logs --tail=100"
    fi
else
    warn "OpenHands image pull failed after ${OPENHANDS_PULL_RETRIES} attempts"
    warn "(often DNS/firewall/registry issue)."
    warn "Continuing setup of remaining services. Retry later with:"
    warn "  docker compose -f ${COMPOSE_FILE} pull && docker compose -f ${COMPOSE_FILE} up -d"
fi

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
sudo "${LAB_PY}" -m pip install --upgrade fastmcp
sudo "${LAB_PY}" -m pip install -q --upgrade numpy requests "rank-bm25" "sentence-transformers" uvicorn
info "Python packages ready."

# Pre-download the cross-encoder reranker model so the first query isn't slow.
# Model is 66 MB and cached to ~/.cache/huggingface/ — downloaded once, used forever.
# Reranker is optional: lab knowledge search works fine with vector+BM25 alone.
# If HuggingFace is unreachable (SSL inspection, firewall, etc.), skip silently
# and gracefully degrade. First query will be slower, but will work.
# Reranker model is optional and requires internet access without SSL inspection.
# Lab knowledge retrieval works fine with vector+BM25 alone (graceful degradation).
info "Reranker model pre-download (optional, skip if unreachable)..."

RERANKER_CACHE="/root/.cache/huggingface/hub/models--cross-encoder--ms-marco-MiniLM-L6-v2"
if [[ -d "${RERANKER_CACHE}" ]]; then
    info "Reranker model already cached."
else
    # Try to download using curl --insecure (bypasses SSL cert verification)
    DOWNLOAD_SCRIPT="${SCRIPT_DIR}/download-reranker.sh"
    if [[ -f "${DOWNLOAD_SCRIPT}" ]]; then
        info "Attempting to download reranker model using curl --insecure..."
        # Run as root so the cache ends up in /root/.cache where sentence_transformers expects it
        if timeout 180 sudo bash "${DOWNLOAD_SCRIPT}"; then
            info "Reranker model downloaded successfully."
        else
            warn "Reranker download failed. Lab knowledge will use vector+BM25 only."
            warn "To add it manually:"
            warn "  1. scp -r ~/.cache/huggingface/hub/models--cross-encoder--ms-marco-MiniLM-L6-v2 root@aleatico2:/root/.cache/huggingface/hub/"
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

# Ensure embedding model is present (needed by lab-knowledge indexing/search).
if ollama list | awk 'NR>1 {print $1}' | grep -Eq '^nomic-embed-text(:|$)'; then
    info "Embedding model already present: nomic-embed-text"
else
    info "Pulling required embedding model: nomic-embed-text..."
    ollama pull nomic-embed-text
fi

# --------------------------------------------------------------------------- #
# 9. Verify
# --------------------------------------------------------------------------- #
info ""
info "=== Setup complete. Verification ==="
info ""
info "Loaded models (may take a moment for first load):"
ollama list

info ""
info "GPU memory usage:"
nvidia-smi --query-gpu=name,memory.used,memory.free --format=csv,noheader 2>/dev/null || \
    warn "nvidia-smi not found — check GPU manually."

info ""
info "Test the API:"
info "  curl http://127.0.0.1:11434/api/tags"
info ""
info "To manually flush GPU memory before a CUDA job:"
info "  gpu-clear"
info ""
info "OpenHands (background agent): http://aleatico2.imago7.local:3000"
info "Lab knowledge MCP:            http://aleatico2.imago7.local:3001/sse"
info "Lab status dashboard:          http://aleatico2.imago7.local:3002"
info "Web search MCP:                http://aleatico2.imago7.local:3003/sse"
info ""
info "Each lab member should run onboard.sh once from a VSCode Remote-SSH terminal."
