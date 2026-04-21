#!/usr/bin/env bash
# =============================================================================
# onboard.sh — One-time setup for a new lab member.
#
# Run this once on each machine where you want to use the workspace template:
#   - Via Remote-SSH to aleatico2, aleatico1, merlot0, or any other lab server
#   - Locally on your laptop or desktop (macOS / Linux)
#
# What it does:
#   1. Creates a small per-user Python venv (~/.local/share/lab-mcp) with
#      the MCP dependencies needed to run the codebase-search tool.
#      This is separate from your project environments — you do not need
#      to activate it. VSCode calls it automatically in the background.
#   2. Installs VSCode extensions (server-side when used with Remote-SSH,
#      local when run on a laptop). The Python extension will prompt you
#      to pick an interpreter the first time you open a project; choose
#      whichever conda/venv env you prefer and VSCode will remember it.
#
# Usage:
#   bash ~/lab-llm-server/onboard.sh
#
# Safe to re-run — all steps are idempotent.
# =============================================================================
set -euo pipefail

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
info() { echo "[onboard] $*"; }
warn() { echo "[onboard] WARNING: $*"; }

# --------------------------------------------------------------------------- #
# Per-user MCP venv (~/.local/share/lab-mcp)
#
# Tiny isolated venv (stdlib venv — no conda needed) that provides the
# Python MCP runtime for the codebase-search tool. Works on any Linux or
# macOS machine regardless of which conda installation (if any) is present.
# --------------------------------------------------------------------------- #
MCP_VENV="${HOME}/.local/share/lab-mcp"

if [[ -x "${MCP_VENV}/bin/python" ]]; then
    info "MCP venv already exists at ${MCP_VENV} — upgrading deps."
    "${MCP_VENV}/bin/pip" install -q --upgrade "mcp[cli]" numpy requests
else
    info "Creating MCP venv at ${MCP_VENV}..."
    python3 -m venv "${MCP_VENV}"
    "${MCP_VENV}/bin/pip" install -q "mcp[cli]" numpy requests
    info "MCP venv ready."
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
    warn "Make sure you are running this from a VSCode integrated terminal"
    warn "(Remote-SSH or local), not from a plain MobaXterm/WSL SSH session."
fi

# --------------------------------------------------------------------------- #
# Done
# --------------------------------------------------------------------------- #
info ""
info "=== Onboarding complete ==="
info ""
info "MCP venv: ${MCP_VENV}"
info ""
info "Next steps:"
info "  1. Reload the VSCode window: F1 → Developer: Reload Window"
info "  2. Clone a project:  git clone https://github.com/<lab-org>/lab-workspace-template ~/M/my-project"
info "  3. Open it in VSCode: File → Open Folder"
info "  4. Select your Python interpreter when prompted (conda env, venv — your choice)."
info ""
info "Re-run this script on each machine where you want to use the workspace template."
