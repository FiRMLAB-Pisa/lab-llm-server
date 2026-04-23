#!/usr/bin/env python3
"""
Lab Knowledge MCP Server (HTTP/SSE transport)
==============================================
A persistent MCP server that exposes a `search_knowledge` tool backed by
the shared lab knowledge index at /opt/lab-knowledge/.index/index.pkl.

Runs as a systemd service on aleatico2, port 3001.
All workspaces connect to it via HTTP/SSE — one process, shared by everyone.
Index is hot-reloaded whenever lab-knowledge-index.py rebuilds it (mtime watch).

Workspace settings point to: http://aleatico2.imago7.local:3001/sse

Usage (managed by systemd — do not run manually in production):
    /opt/conda/envs/lab-mcp/bin/python lab-knowledge-server.py
    /opt/conda/envs/lab-mcp/bin/python lab-knowledge-server.py --root /opt/lab-knowledge --port 3001
"""

import argparse
import pickle
import re
import sys
import threading
import time
from pathlib import Path

import numpy as np
import requests
from fastmcp import FastMCP

try:
    from rank_bm25 import BM25Okapi
    _HAS_BM25 = True
except ImportError:
    _HAS_BM25 = False
    sys.stderr.write(
        "[lab-knowledge] rank_bm25 not installed — falling back to vector-only retrieval.\n"
        "[lab-knowledge] Install it: pip install rank-bm25\n"
    )

try:
    from sentence_transformers import CrossEncoder
    _HAS_RERANKER = True
except ImportError:
    _HAS_RERANKER = False
    sys.stderr.write(
        "[lab-knowledge] sentence-transformers not installed — reranking disabled.\n"
        "[lab-knowledge] Install it: pip install sentence-transformers\n"
    )

# --------------------------------------------------------------------------- #
# Config (overridable via CLI)
# --------------------------------------------------------------------------- #
DEFAULT_ROOT    = "/opt/lab-knowledge"
DEFAULT_PORT    = 3001
OLLAMA_BASE     = "http://aleatico2.imago7.local:11434"
EMBED_MODEL     = "nomic-embed-text"
RELOAD_SECS     = 60      # check for index updates every 60 s
RERANKER_MODEL  = "cross-encoder/ms-marco-MiniLM-L6-v2"  # 66 MB, CPU, ~3 ms/pair
# CANDIDATE_K scales with corpus: 1% of chunks, clamped to [20, 100].
# Small corpus → 20; large corpus → 100.  Reranker only helps what it sees.
CANDIDATE_K     = 20      # floor; overridden at query time based on index size
PRIORITY_ALPHA  = 0.10    # weight of priority boost in RRF score  (0 = disabled)

# --------------------------------------------------------------------------- #
# Shared index state
# --------------------------------------------------------------------------- #
_embeddings:  np.ndarray | None = None
_documents:   list[str]         = []
_metadata:    list[dict]        = []

_bm25                           = None   # BM25Okapi instance, or None
_reranker                       = None   # CrossEncoder, loaded lazily on first query
_reranker_lock = threading.Lock()
_index_mtime: float             = 0.0
_lock         = threading.RLock()
_ready        = threading.Event()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=str, default=DEFAULT_ROOT)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()

    global _embeddings, _documents, _metadata, _bm25, _reranker, _index_mtime, _lock, _ready
    # ...existing code for loading index, etc...
    import fastmcp
    print(f"[lab-knowledge] fastmcp version: {getattr(fastmcp, '__version__', 'unknown')}")
    mcp = FastMCP("lab-knowledge")
    print(f"Lab knowledge MCP server listening on http://0.0.0.0:{args.port}/", flush=True)
    try:
        mcp.run(transport="http", host="0.0.0.0", port=args.port)
    except Exception as e:
        print(f"[lab-knowledge] fastmcp version: {getattr(fastmcp, '__version__', 'unknown')}")
        print(f"[lab-knowledge] MCP server failed to start: {e}")
        raise


if __name__ == "__main__":
    main()


def _tokenize(text: str) -> list[str]:
    """Tokeniser for BM25 — preserves underscores, splits camelCase.

    Handles lab-specific identifiers correctly:
      T2_star      → ['t2_star']
      getUserID    → ['get', 'user', 'i', 'd']  (camelCase split)
      B0_field     → ['b0_field']
      foo_bar_baz  → ['foo_bar_baz']
    """
    # Split camelCase/PascalCase: insert space before each uppercase run
    text = re.sub(r'([a-z0-9])([A-Z])', r'\1 \2', text)
    text = re.sub(r'([A-Z]+)([A-Z][a-z])', r'\1 \2', text)
    # Extract words that may contain underscores and digits (lab identifiers)
    return re.findall(r'[a-zA-Z0-9][a-zA-Z0-9_]*', text.lower())


# --------------------------------------------------------------------------- #
# Index loader (hot-reload on mtime change)
# --------------------------------------------------------------------------- #
def _load_index(index_file: Path) -> None:
    global _embeddings, _documents, _metadata, _bm25, _index_mtime
    try:
        mtime = index_file.stat().st_mtime
        if mtime == _index_mtime:
            return   # unchanged
        with open(index_file, "rb") as f:
            data = pickle.load(f)

        # Build BM25 outside the lock (can be slow for large corpora)
        new_bm25 = None
        if _HAS_BM25 and data.get("documents"):
            new_bm25 = BM25Okapi([_tokenize(d) for d in data["documents"]])

        with _lock:
            _embeddings   = data["embeddings"]
            _documents    = data["documents"]
            _metadata     = data["metadata"]
            _bm25         = new_bm25
            _index_mtime  = mtime
        n = len(data["ids"])
        sys.stderr.write(f"[lab-knowledge] Index loaded: {n} chunks "
                         f"(mtime={mtime:.0f}, bm25={'yes' if new_bm25 else 'no'})\n")
        _ready.set()
    except FileNotFoundError:
        sys.stderr.write(
            "[lab-knowledge] Index not found — run lab-knowledge-index.py first.\n"
        )
        _ready.set()   # allow queries to return a helpful message
    except Exception as e:
        sys.stderr.write(f"[lab-knowledge] Index load error: {e}\n")
        _ready.set()


def _watch_loop(index_file: Path) -> None:
    while True:
        _load_index(index_file)
        time.sleep(RELOAD_SECS)


# --------------------------------------------------------------------------- #
# Reranker — loaded once on first use (downloads model ~66 MB to HF cache)
# --------------------------------------------------------------------------- #
def _get_reranker():
    global _reranker
    if not _HAS_RERANKER:
        return None
    with _reranker_lock:
        if _reranker is None:
            try:
                _reranker = CrossEncoder(RERANKER_MODEL, max_length=512)
                sys.stderr.write(
                    f"[lab-knowledge] Reranker loaded: {RERANKER_MODEL}\n"
                )
            except Exception as e:
                sys.stderr.write(f"[lab-knowledge] Reranker load failed: {e}\n")
        return _reranker


# --------------------------------------------------------------------------- #
# Embedding helper
# --------------------------------------------------------------------------- #
def _embed(text: str) -> np.ndarray:
    resp = requests.post(
        f"{OLLAMA_BASE}/api/embed",
        json={"model": EMBED_MODEL, "input": [text]},
        timeout=30,
    )
    resp.raise_for_status()
    vec = np.array(resp.json()["embeddings"][0], dtype=np.float32)
    norm = np.linalg.norm(vec)
    return vec / norm if norm > 0 else vec


# --------------------------------------------------------------------------- #
# MCP tool
# --------------------------------------------------------------------------- #
@mcp.tool()
def search_knowledge(query: str, n_results: int = 5) -> str:
    """Search the lab's shared knowledge base: SDK headers, library source code,
    tutorials, and reference documentation.

    Use this tool when you need authoritative API signatures, function
    signatures, or usage examples from:
    - GE EPIC SDK (pulse programming)
    - KSFoundation
    - Pulseq / PyPulseq
    - BART (reconstruction toolbox)
    - Gadgetron
    - DIPY, Nipype, and other neuroimaging libraries
    - Any other material the admin placed in /opt/lab-knowledge/

    Args:
        query:     What to search for (natural language or code fragment).
        n_results: Number of results to return (default 5, max 10).
    """
    if not _ready.is_set():
        return "Knowledge base is still loading. Retry in a few seconds."

    n_results = min(max(1, n_results), 10)

    # ------------------------------------------------------------------ #
    # Embed the query — outside the lock (network I/O, 2-5 s).
    # Multiple concurrent users can embed in parallel.
    # ------------------------------------------------------------------ #
    try:
        q_vec = _embed(query)
    except Exception as e:
        return f"Embedding error: {e}"

    # ------------------------------------------------------------------ #
    # Snapshot the current index arrays under the lock (microseconds).
    # We work on local references so the lock is not held during compute.
    # ------------------------------------------------------------------ #
    with _lock:
        if _embeddings is None or len(_documents) == 0:
            return (
                "The lab knowledge base index has not been built yet.\n"
                "Ask the admin to run:\n"
                "  sudo /opt/conda/envs/lab-mcp/bin/python "
                "/opt/lab-server/lab-knowledge-index.py"
            )
        emb_snap  = _embeddings   # numpy array reference — safe to read without lock
        docs_snap = _documents
        meta_snap = _metadata
        bm25_snap = _bm25

    # ------------------------------------------------------------------ #
    # Stage 1 — candidate retrieval (vector + BM25 → RRF + priority boost)
    # All CPU compute, no lock needed.
    # ------------------------------------------------------------------ #
    # Scale candidate pool with corpus size: 1% of chunks, clamped [20, 100].
    # This ensures the reranker has a fair chance as the knowledge base grows.
    n_corpus     = len(emb_snap)
    n_candidates = max(n_results * 4, CANDIDATE_K,
                       min(100, max(20, int(0.01 * n_corpus))))
    scores_vec   = (emb_snap @ q_vec).astype(float)
    ranked_vec   = sorted(range(len(scores_vec)), key=lambda i: -scores_vec[i])[:n_candidates]

    if _HAS_BM25 and bm25_snap is not None:
        scores_bm25 = bm25_snap.get_scores(_tokenize(query))
        ranked_bm25 = sorted(range(len(scores_bm25)), key=lambda i: -scores_bm25[i])[:n_candidates]
        rrf: dict[int, float] = {}
        for rank, idx in enumerate(ranked_vec):
            rrf[idx] = rrf.get(idx, 0.0) + 1.0 / (60 + rank + 1)
        for rank, idx in enumerate(ranked_bm25):
            rrf[idx] = rrf.get(idx, 0.0) + 1.0 / (60 + rank + 1)
    else:
        rrf = {idx: 1.0 / (60 + rank + 1) for rank, idx in enumerate(ranked_vec)}

    # Priority boost: validated protocols and papers float above random READMEs
    if PRIORITY_ALPHA > 0:
        max_priority = 10.0
        for idx in rrf:
            p = meta_snap[idx].get('priority', 3)
            rrf[idx] *= (1.0 + PRIORITY_ALPHA * p / max_priority)

    candidates = sorted(rrf, key=lambda i: -rrf[i])[:n_candidates]

    # ------------------------------------------------------------------ #
    # Stage 2 — cross-encoder reranking — outside the lock (~80 ms CPU).
    # Multiple users can rerank in parallel.
    # ------------------------------------------------------------------ #
    reranker = _get_reranker()
    if reranker is not None and len(candidates) > n_results:
        pairs         = [(query, docs_snap[i]) for i in candidates]
        rerank_scores = reranker.predict(pairs)
        order         = sorted(range(len(candidates)),
                               key=lambda k: -float(rerank_scores[k]))
        top_k = [candidates[k] for k in order[:n_results]]
    else:
        top_k = candidates[:n_results]

    # ------------------------------------------------------------------ #
    # Format results
    # ------------------------------------------------------------------ #
    parts = []
    for idx in top_k:
        meta      = meta_snap[idx]
        sim       = float(scores_vec[idx])
        doc       = docs_snap[idx]
        doc_type  = meta.get('doc_type', '')
        priority  = meta.get('priority', 3)
        type_tag  = f", {doc_type}" if doc_type else ""
        parts.append(
            f"**{meta['path']}** (line {meta['start_line']}{type_tag}, "
            f"priority {priority}, similarity {sim:.2f})\n```\n{doc}\n```"
        )

    return "\n\n---\n\n".join(parts)


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=DEFAULT_ROOT)
    args = parser.parse_args()

    index_file = Path(args.root) / ".index" / "index.pkl"

    # Start background watcher — loads index immediately, then polls
    threading.Thread(target=_watch_loop, args=(index_file,), daemon=True).start()

    true_port = 8000  # FastMCP always binds to 8000 in this version
    sys.stderr.write(
        f"[lab-knowledge] Starting HTTP/SSE MCP server on port {true_port} (FastMCP ignores --port)\n"
        f"[lab-knowledge] Index: {index_file}\n"
        f"[lab-knowledge] Roo Code endpoint: "
        f"http://aleatico2.imago7.local:{true_port}/sse\n"
    )
    # No port argument; FastMCP always binds to 8000
    mcp.run(transport="sse")  # Only pass supported arguments; port is now fixed in FastMCP


if __name__ == "__main__":
    main()
