#!/usr/bin/env bash
# =============================================================================
# Lab LLM Server Smoke Test
# Run on aleatico2 after setup.sh completes, or any time you want to verify
# the full stack is healthy.
# =============================================================================
set -uo pipefail

OLLAMA_URL="http://127.0.0.1:11434"
OPENHANDS_URL="http://127.0.0.1:3000"

REQUIRED_MODELS=(
    "deepseek-r1:32b"
    "qwen2.5-coder:14b"
    "deepseek-r1:7b"
    "nomic-embed-text"
)

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }
section() { echo ""; echo "=== $* ==="; }

# --------------------------------------------------------------------------- #
section "Ollama service"
# --------------------------------------------------------------------------- #

if systemctl is-active --quiet ollama; then
    pass "ollama.service is active"
else
    fail "ollama.service is NOT active — run: sudo systemctl start ollama"
fi

if curl -sf "${OLLAMA_URL}/api/tags" > /dev/null; then
    pass "Ollama API reachable at ${OLLAMA_URL}"
else
    fail "Ollama API not reachable at ${OLLAMA_URL}"
fi

# Check network binding (must be 0.0.0.0, not 127.0.0.1)
if ss -tln | grep -Eq '(:|\*)11434\b'; then
    if ss -tln | grep -Eq '0\.0\.0\.0:11434|\*:11434|\[::\]:11434'; then
        pass "Ollama listening on all interfaces for :11434 (LAN/VPN accessible)"
    else
        fail "Ollama is listening, but not on all interfaces for :11434"
    fi
else
    fail "Ollama is NOT listening on :11434 — check systemd drop-in config"
fi

# --------------------------------------------------------------------------- #
section "Models"
# --------------------------------------------------------------------------- #

AVAILABLE=$(curl -sf "${OLLAMA_URL}/api/tags" | python3 -c \
    "import sys,json; tags=json.load(sys.stdin).get('models', []); [print(m.get('name','')) for m in tags]" 2>/dev/null)

for model in "${REQUIRED_MODELS[@]}"; do
    if echo "${AVAILABLE}" | grep -Eq "^${model}(:|$)"; then
        pass "Model available: ${model}"
    else
        fail "Model NOT available: ${model} — run: ollama pull ${model}"
    fi
done

# --------------------------------------------------------------------------- #
section "Inference — chat completion (short prompt)"
# --------------------------------------------------------------------------- #

for model in "qwen2.5-coder:14b" "deepseek-r1:7b"; do
    RESP=$(curl -sf -X POST "${OLLAMA_URL}/api/chat" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${model}\",\"stream\":false,\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: OK\"}]}" \
        2>/dev/null)
    if echo "${RESP}" | python3 -c "import sys,json; r=json.load(sys.stdin); assert r['message']['content']" 2>/dev/null; then
        pass "Inference OK: ${model}"
    else
        fail "Inference FAILED: ${model}"
    fi
done

# --------------------------------------------------------------------------- #
section "Embeddings (nomic-embed-text)"
# --------------------------------------------------------------------------- #

EMBED_RESP=$(curl -sf -X POST "${OLLAMA_URL}/api/embed" \
    -H "Content-Type: application/json" \
    -d '{"model":"nomic-embed-text","input":["test"]}' 2>/dev/null)
DIM=$(echo "${EMBED_RESP}" | python3 -c \
    "import sys,json; e=json.load(sys.stdin)['embeddings']; print(len(e[0]))" 2>/dev/null)
if [[ -n "${DIM}" && "${DIM}" -gt 0 ]]; then
    pass "Embeddings OK: nomic-embed-text (dim=${DIM})"
else
    fail "Embeddings FAILED: nomic-embed-text"
fi

# --------------------------------------------------------------------------- #
section "OpenAI-compatible endpoint (used by Roo Code)"
# --------------------------------------------------------------------------- #

OAI_RESP=$(curl -sf "${OLLAMA_URL}/v1/models" 2>/dev/null)
if echo "${OAI_RESP}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); assert len(d['data'])>0" 2>/dev/null; then
    pass "OpenAI-compatible /v1/models endpoint OK"
else
    fail "OpenAI-compatible endpoint NOT working"
fi

# --------------------------------------------------------------------------- #
section "OpenHands"
# --------------------------------------------------------------------------- #

if command -v docker &>/dev/null; then
    pass "Docker installed"
    if docker compose -f "$(dirname "$0")/openhands-compose.yml" ps --status running --services 2>/dev/null | grep -q .; then
        pass "OpenHands container is running"
    elif curl -sf "${OPENHANDS_URL}" > /dev/null; then
        pass "OpenHands reachable at ${OPENHANDS_URL} (container status check unavailable)"
    else
        fail "OpenHands container is NOT running — run: docker compose -f ./openhands-compose.yml up -d"
    fi
    if curl -sf "${OPENHANDS_URL}" > /dev/null; then
        pass "OpenHands UI reachable at ${OPENHANDS_URL}"
    else
        fail "OpenHands UI not reachable at ${OPENHANDS_URL} (container may still be starting)"
    fi
else
    fail "Docker not installed — run setup.sh"
fi

# --------------------------------------------------------------------------- #
section "Web Search (SearXNG + web search MCP)"
# --------------------------------------------------------------------------- #

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if docker compose -f "${SCRIPT_DIR}/searxng-compose.yml" ps --status running --services 2>/dev/null | grep -q .; then
    pass "SearXNG container is running"
elif curl -sf 'http://127.0.0.1:8080/search?q=test&format=json' > /dev/null; then
    pass "SearXNG reachable at 127.0.0.1:8080 (container status check unavailable)"
else
    fail "SearXNG container is NOT running — run: docker compose -f ~/lab-llm-server/searxng-compose.yml up -d"
fi

if curl -sf 'http://127.0.0.1:8080/search?q=test&format=json' > /dev/null; then
    pass "SearXNG JSON API reachable at 127.0.0.1:8080"
else
    fail "SearXNG JSON API not reachable (may still be starting, or internet auth needed)"
fi

if systemctl is-active --quiet lab-websearch; then
    pass "lab-websearch.service is active"
else
    fail "lab-websearch.service is NOT active — run: sudo systemctl start lab-websearch"
fi

if curl -sf 'http://127.0.0.1:3003/mcp' > /dev/null 2>&1 || \
    curl -sf --max-time 2 'http://127.0.0.1:3003/' > /dev/null 2>&1; then
     pass "Web search MCP HTTP endpoint reachable at :3003"
else
    fail "Web search MCP not reachable at :3003 — check: journalctl -fu lab-websearch"
fi

# --------------------------------------------------------------------------- #
section "Lab Knowledge MCP (port 3001)"
# --------------------------------------------------------------------------- #

LAB_PY=$(sed -n 's|^ExecStart=\([^[:space:]]*\).*|\1|p' /etc/systemd/system/lab-knowledge.service 2>/dev/null | head -1)
if [[ -z "${LAB_PY}" || "${LAB_PY}" == "{" ]]; then
    LAB_PY="/opt/conda/envs/lab-mcp/bin/python"
fi

if systemctl is-active --quiet lab-knowledge; then
    pass "lab-knowledge.service is active"
else
    fail "lab-knowledge.service is NOT active — run: sudo systemctl start lab-knowledge"
fi

if ss -tln | grep -Eq '(:|\*)3001\b'; then
    pass "Lab knowledge service listening on :3001"
elif curl -sf --max-time 3 'http://127.0.0.1:3001/mcp' > /dev/null 2>&1 || \
    curl -sf --max-time 3 'http://127.0.0.1:3001/' > /dev/null 2>&1; then
    pass "Lab knowledge MCP HTTP endpoint reachable at :3001"
else
    fail "Lab knowledge MCP not reachable at :3001 — check: journalctl -fu lab-knowledge"
fi

# Check Python packages in the lab-mcp env
if [[ -x "${LAB_PY}" ]]; then
    for pkg in "rank_bm25" "sentence_transformers" "mcp" "numpy" "requests"; do
        if "${LAB_PY}" -c "import ${pkg}" 2>/dev/null; then
            pass "Python package available: ${pkg}"
        else
            fail "Python package MISSING in lab-mcp env: ${pkg} — run: ${LAB_PY} -m pip install ${pkg//_/-}"
        fi
    done

    # Functional reranker check: actually score a pair
    RERANKER_OK=$("${LAB_PY}" -c "
from sentence_transformers import CrossEncoder
m = CrossEncoder('cross-encoder/ms-marco-MiniLM-L6-v2', max_length=512)
s = m.predict([('T1 relaxation', 'T1 is the longitudinal relaxation time constant')])
print('ok' if float(s[0]) > -10 else 'bad')
" 2>/dev/null)
    if [[ "${RERANKER_OK}" == "ok" ]]; then
        pass "Cross-encoder reranker functional (ms-marco-MiniLM-L6-v2)"
    else
        fail "Cross-encoder reranker not working — check model cache or sentence-transformers install"
    fi
else
    fail "lab-mcp Python env not found at ${LAB_PY} — run setup.sh"
fi

# --------------------------------------------------------------------------- #
section "GPU"
# --------------------------------------------------------------------------- #

if command -v nvidia-smi &>/dev/null; then
    VRAM_USED=$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits | head -1 | tr -d ' ')
    VRAM_FREE=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | head -1 | tr -d ' ')
    VRAM_TOTAL=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -1 | tr -d ' ')
    pass "GPU VRAM: ${VRAM_USED}/${VRAM_TOTAL} MiB used, ${VRAM_FREE} MiB free"
    if [[ "${VRAM_FREE}" -lt 4096 ]]; then
        fail "Less than 4 GB VRAM free — models may not load or inference will be slow"
    fi
else
    fail "nvidia-smi not found — GPU status unknown"
fi

# --------------------------------------------------------------------------- #
section "Results"
# --------------------------------------------------------------------------- #
echo ""
echo "  Passed: ${PASS}"
echo "  Failed: ${FAIL}"
echo ""
if [[ "${FAIL}" -eq 0 ]]; then
    echo "All checks passed. The server is ready."
else
    echo "Some checks failed. Review the [FAIL] lines above."
    exit 1
fi
