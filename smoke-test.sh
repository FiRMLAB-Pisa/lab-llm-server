#!/usr/bin/env bash
# =============================================================================
# Lab LLM Server Smoke Test
# Run on aleatico2 after setup.sh completes, or any time you want to verify
# the full stack is healthy.
# =============================================================================
set -uo pipefail

LLAMA_URL="http://127.0.0.1:11434"
OLLAMA_EMBED_URL="http://127.0.0.1:11436"
OLLAMA_AUTOCOMPLETE_URL="http://127.0.0.1:11435"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PASS=0; FAIL=0
pass() { echo "  [PASS] $*"; (( PASS++ )) || true; }
fail() { echo "  [FAIL] $*"; (( FAIL++ )) || true; }
section() { echo ""; echo "=== $* ==="; }

# --------------------------------------------------------------------------- #
section "llama-server (main inference, port 11434)"
# --------------------------------------------------------------------------- #

if systemctl is-active --quiet llama-server; then
    pass "llama-server.service is active"
else
    fail "llama-server.service is NOT active — run: sudo systemctl start llama-server"
fi

if curl -sf "${LLAMA_URL}/health" > /dev/null 2>&1; then
    pass "llama-server /health reachable at ${LLAMA_URL}"
else
    fail "llama-server /health not reachable at ${LLAMA_URL} — may still be loading model"
fi

if ss -tln | grep -Eq '0\.0\.0\.0:11434|\*:11434|\[::\]:11434'; then
    pass "llama-server listening on all interfaces for :11434 (LAN/VPN accessible)"
else
    fail "llama-server is NOT listening on 0.0.0.0:11434 — check: journalctl -u llama-server -n 50"
fi

# --------------------------------------------------------------------------- #
section "llama-server OpenAI-compatible endpoint"
# --------------------------------------------------------------------------- #

MODELS_RESP=$(curl -sf "${LLAMA_URL}/v1/models" 2>/dev/null)
if echo "${MODELS_RESP}" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); assert len(d['data'])>0" 2>/dev/null; then
    MODEL_ID=$(echo "${MODELS_RESP}" | python3 -c \
        "import sys,json; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null)
    pass "llama-server /v1/models OK — model: ${MODEL_ID}"
else
    fail "llama-server /v1/models NOT working — check: journalctl -u llama-server -n 50"
fi

# --------------------------------------------------------------------------- #
section "Inference — chat completion with reasoning (short prompt)"
# --------------------------------------------------------------------------- #

CHAT_RESP=$(curl -sf -X POST "${LLAMA_URL}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d '{"model":"'${MODEL_ID:-qwen3.6-35b}'","stream":false,"messages":[{"role":"user","content":"/think\nReply with exactly: OK"}]}' \
    2>/dev/null)
if echo "${CHAT_RESP}" | python3 -c \
    "import sys,json; r=json.load(sys.stdin); assert r['choices'][0]['message']['content']" 2>/dev/null; then
    pass "Chat completion OK"
    # Check reasoning_content field is present (deepseek format)
    if echo "${CHAT_RESP}" | python3 -c \
        "import sys,json; r=json.load(sys.stdin); c=r['choices'][0]['message']; assert 'reasoning_content' in c" 2>/dev/null; then
        pass "reasoning_content field present in response (deepseek reasoning format active)"
    else
        fail "reasoning_content field missing — check --reasoning-format deepseek flag in llama-server startup"
    fi
else
    fail "Chat completion FAILED — check: journalctl -u llama-server -n 50"
fi

# --------------------------------------------------------------------------- #
section "Ollama embedding instance (port 11436, internal only)"
# --------------------------------------------------------------------------- #

if systemctl is-active --quiet ollama; then
    pass "ollama.service is active"
else
    fail "ollama.service is NOT active — run: sudo systemctl start ollama"
fi

if curl -sf "${OLLAMA_EMBED_URL}/api/tags" > /dev/null 2>&1; then
    pass "Ollama embedding API reachable at ${OLLAMA_EMBED_URL}"
else
    fail "Ollama embedding API not reachable at ${OLLAMA_EMBED_URL}"
fi

# Verify it is NOT LAN-accessible (must be 127.0.0.1 only)
if ss -tln | grep -Eq '0\.0\.0\.0:11436|\*:11436'; then
    fail "Ollama embedding instance is exposed on all interfaces — should be 127.0.0.1:11436 only"
else
    pass "Ollama embedding instance correctly bound to 127.0.0.1:11436 (internal only)"
fi

# --------------------------------------------------------------------------- #
section "Embeddings (nomic-embed-text, port 11436)"
# --------------------------------------------------------------------------- #

EMBED_RESP=$(curl -sf -X POST "${OLLAMA_EMBED_URL}/api/embed" \
    -H "Content-Type: application/json" \
    -d '{"model":"nomic-embed-text","input":["test"]}' 2>/dev/null)
DIM=$(echo "${EMBED_RESP}" | python3 -c \
    "import sys,json; e=json.load(sys.stdin)['embeddings']; print(len(e[0]))" 2>/dev/null)
if [[ -n "${DIM}" && "${DIM}" -gt 0 ]]; then
    pass "Embeddings OK: nomic-embed-text (dim=${DIM})"
else
    fail "Embeddings FAILED: nomic-embed-text — run: OLLAMA_HOST=127.0.0.1:11436 ollama pull nomic-embed-text"
fi

# --------------------------------------------------------------------------- #
section "Ollama autocomplete instance (starcoder2:3b, port 11435)"
# --------------------------------------------------------------------------- #

if systemctl is-active --quiet ollama-autocomplete; then
    pass "ollama-autocomplete.service is active"
else
    fail "ollama-autocomplete.service is NOT active — run: sudo systemctl start ollama-autocomplete"
fi

if curl -sf "${OLLAMA_AUTOCOMPLETE_URL}/api/tags" > /dev/null 2>&1; then
    pass "Autocomplete Ollama API reachable at :11435"
else
    fail "Autocomplete Ollama not reachable at :11435 — check: journalctl -u ollama-autocomplete -n 50"
fi

AUTOCOMPLETE_MODELS=$(curl -sf "${OLLAMA_AUTOCOMPLETE_URL}/api/tags" 2>/dev/null | \
    python3 -c "import sys,json; tags=json.load(sys.stdin).get('models',[]); [print(m.get('name','')) for m in tags]" 2>/dev/null)
if echo "${AUTOCOMPLETE_MODELS}" | grep -Eq "^starcoder2:3b(:|$)"; then
    pass "starcoder2:3b available on autocomplete instance"
else
    fail "starcoder2:3b not loaded on :11435 — run: OLLAMA_HOST=127.0.0.1:11435 ollama pull starcoder2:3b"
fi

# --------------------------------------------------------------------------- #
section "Docker"
# --------------------------------------------------------------------------- #

if command -v docker &>/dev/null; then
    pass "Docker installed ($(docker --version))"
else
    fail "Docker not installed — run setup.sh"
fi

# --------------------------------------------------------------------------- #
section "Web Search (SearXNG + web search MCP)"
# --------------------------------------------------------------------------- #
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

if ss -tln | grep -Eq '(:|\*)3003\b'; then
    pass "Web search MCP service listening on :3003"
elif curl -sf --max-time 2 'http://127.0.0.1:3003/mcp' > /dev/null 2>&1 || \
     curl -sf --max-time 2 'http://127.0.0.1:3003/' > /dev/null 2>&1; then
    pass "Web search MCP HTTP endpoint reachable at :3003"
else
    fail "Web search MCP not reachable at :3003 — check: journalctl -fu lab-websearch"
fi

# --------------------------------------------------------------------------- #
section "Qdrant (vector DB for Roo Code codebase indexing)"
# --------------------------------------------------------------------------- #

if docker compose -f "${SCRIPT_DIR}/qdrant-compose.yml" ps --status running --services 2>/dev/null | grep -q .; then
    pass "Qdrant container is running"
elif curl -sf 'http://127.0.0.1:6333/healthz' > /dev/null 2>&1 || \
     curl -sf 'http://127.0.0.1:6333/' > /dev/null 2>&1; then
    pass "Qdrant reachable at 127.0.0.1:6333 (container status check unavailable)"
else
    fail "Qdrant container is NOT running — run: docker compose -f ~/lab-llm-server/qdrant-compose.yml up -d"
fi

if curl -sf 'http://127.0.0.1:6333/healthz' > /dev/null 2>&1; then
    pass "Qdrant health endpoint OK at 127.0.0.1:6333"
elif curl -sf 'http://127.0.0.1:6333/collections' > /dev/null 2>&1; then
    pass "Qdrant collections endpoint reachable at 127.0.0.1:6333"
else
    fail "Qdrant not reachable at :6333 — check: docker compose -f ~/lab-llm-server/qdrant-compose.yml logs"
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
    RERANKER_OK=$(HF_HOME=/opt/lab-server/hf-cache \
                  HUGGINGFACE_HUB_CACHE=/opt/lab-server/hf-cache/hub \
                  TRANSFORMERS_CACHE=/opt/lab-server/hf-cache/transformers \
                  RERANKER_MODEL_PATH=/opt/lab-server/hf-cache/hub/models--cross-encoder--ms-marco-MiniLM-L6-v2 \
                  "${LAB_PY}" -c "
import os
from sentence_transformers import CrossEncoder
model = os.environ.get('RERANKER_MODEL_PATH', 'cross-encoder/ms-marco-MiniLM-L6-v2')
m = CrossEncoder(model, max_length=512)
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
