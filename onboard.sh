#!/usr/bin/env bash
# =============================================================================
# onboard.sh — One-time server-side setup for a new lab member.
#
# Run this once after connecting to any lab server via VSCode Remote-SSH.
# It installs VSCode server-side extensions and (optionally) creates a
# shared per-member conda environment.
#
# Usage:
#   ./onboard.sh [member-env-name]
#   Default env-name: $USER
#
# Run from the VSCode Remote-SSH integrated terminal.
# =============================================================================
set -euo pipefail

MEMBER_ENV="${1:-$USER}"

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
info() { echo "[onboard] $*"; }
warn() { echo "[onboard] WARNING: $*"; }

# --------------------------------------------------------------------------- #
# Detect conda
# --------------------------------------------------------------------------- #
if ! command -v conda &>/dev/null; then
    for prefix in /opt/conda /usr/local/conda ~/miniconda3 ~/anaconda3; do
        if [[ -f "${prefix}/etc/profile.d/conda.sh" ]]; then
            # shellcheck disable=SC1091
            source "${prefix}/etc/profile.d/conda.sh"
            break
        fi
    done
fi
command -v conda &>/dev/null || { warn "conda not found — skipping environment setup."; SKIP_CONDA=1; }

# --------------------------------------------------------------------------- #
# Create per-member conda environment (optional but recommended)
# --------------------------------------------------------------------------- #
if [[ -z "${SKIP_CONDA:-}" ]]; then
    if conda env list | grep -qE "^${MEMBER_ENV}\s"; then
        info "Conda environment '${MEMBER_ENV}' already exists. Skipping."
    else
        info "Creating per-member conda environment '${MEMBER_ENV}'..."
        info "(Cloning from lab-base — this may take a few minutes)"
        if conda env list | grep -qE "^lab-base\s"; then
            conda create --name "${MEMBER_ENV}" --clone lab-base -y
        else
            warn "lab-base not found. Ask an admin to run server/setup.sh first."
            warn "Creating minimal environment instead."
            conda create --name "${MEMBER_ENV}" python=3.11 numpy scipy matplotlib pandas jupyter ipykernel -y
        fi
        conda run -n "${MEMBER_ENV}" python -m ipykernel install --user \
            --name "${MEMBER_ENV}" \
            --display-name "Python (${MEMBER_ENV})"
        info "Environment '${MEMBER_ENV}' created and registered as Jupyter kernel."
    fi
fi

# --------------------------------------------------------------------------- #
# Create shared lab-mcp conda environment (MCP server for Roo Code codebase search)
# This env is shared across all users — only created once on the server.
# Path must match .vscode/settings.json: /opt/conda/envs/lab-mcp/bin/python
# --------------------------------------------------------------------------- #
MCP_ENV="lab-mcp"
if conda env list | grep -q "^${MCP_ENV} "; then
    info "Conda env '${MCP_ENV}' already exists — skipping."
else
    info "Creating conda env '${MCP_ENV}' (shared MCP / codebase-search server)..."
    conda create -n "${MCP_ENV}" python=3.11 -y
    # mcp: MCP protocol + FastMCP; numpy: vector maths for similarity search
    conda run -n "${MCP_ENV}" pip install "mcp[cli]" numpy requests
    info "Conda env '${MCP_ENV}' ready."
fi

# --------------------------------------------------------------------------- #
# Install VSCode extensions (server-side, via Remote-SSH)
# Must be run from a VSCode Remote-SSH integrated terminal.
# --------------------------------------------------------------------------- #
EXTENSIONS=(
    "roocode.roo-code"               # agentic coding (Architect/Code/Ask/Debug)
    "continue.continue"              # @codebase semantic search / RAG context injection
    "ms-python.python"               # Python language support
    "ms-python.vscode-pylance"       # Python IntelliSense
    "ms-toolsai.jupyter"             # Jupyter notebooks
    "mads-hartmann.bash-ide-vscode"  # Bash scripting
    "eamodio.gitlens"                # Git integration
    "yzhang.markdown-all-in-one"     # Markdown editing
    # Uncomment to add MATLAB support:
    # "mathworks.language-matlab"
)

if command -v code &>/dev/null; then
    info "Installing VSCode extensions on the server..."
    for ext in "${EXTENSIONS[@]}"; do
        ext="${ext%%#*}"; ext="${ext// /}"; [[ -z "$ext" ]] && continue
        info "  → ${ext}"
        code --install-extension "${ext}" --force 2>/dev/null || \
            warn "  Could not install ${ext}"
    done
    info "Extensions installed."
else
    warn "'code' CLI not found."
    warn "Make sure you are running this from the VSCode Remote-SSH integrated terminal,"
    warn "not from a plain MobaXterm/WSL SSH session."
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
info ""
info "=== Onboarding complete ==="
info ""
info "Your per-member conda env: ${MEMBER_ENV}"
info "  Activate with: conda activate ${MEMBER_ENV}"
info ""
info "For each new project, clone lab-workspace-template and run setup-env.sh."
info "setup-env.sh will ask which env to use — enter '${MEMBER_ENV}' to reuse this one."
