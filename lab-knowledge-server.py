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
import sys
import threading
import time
from pathlib import Path

import numpy as np
import requests
from mcp.server.fastmcp import FastMCP

# --------------------------------------------------------------------------- #
# Config (overridable via CLI)
# --------------------------------------------------------------------------- #
DEFAULT_ROOT = "/opt/lab-knowledge"
DEFAULT_PORT = 3001
OLLAMA_BASE  = "http://aleatico2.imago7.local:11434"
EMBED_MODEL  = "nomic-embed-text"
RELOAD_SECS  = 60   # check for index updates every 60 s

# --------------------------------------------------------------------------- #
# Shared index state
# --------------------------------------------------------------------------- #
_embeddings: np.ndarray | None = None
_documents:  list[str]         = []
_metadata:   list[dict]        = []
_index_mtime: float            = 0.0
_lock        = threading.RLock()
_ready       = threading.Event()

mcp = FastMCP("lab-knowledge")


# --------------------------------------------------------------------------- #
# Index loader (hot-reload on mtime change)
# --------------------------------------------------------------------------- #
def _load_index(index_file: Path) -> None:
    global _embeddings, _documents, _metadata, _index_mtime
    try:
        mtime = index_file.stat().st_mtime
        if mtime == _index_mtime:
            return   # unchanged
        with open(index_file, "rb") as f:
            data = pickle.load(f)
        with _lock:
            _embeddings   = data["embeddings"]
            _documents    = data["documents"]
            _metadata     = data["metadata"]
            _index_mtime  = mtime
        n = len(data["ids"])
        sys.stderr.write(f"[lab-knowledge] Index loaded: {n} chunks "
                         f"(mtime={mtime:.0f})\n")
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

    with _lock:
        if _embeddings is None or len(_documents) == 0:
            return (
                "The lab knowledge base index has not been built yet.\n"
                "Ask the admin to run:\n"
                "  sudo /opt/conda/envs/lab-mcp/bin/python "
                "/opt/lab-server/lab-knowledge-index.py"
            )

        try:
            q_vec  = _embed(query)
        except Exception as e:
            return f"Embedding error: {e}"

        scores = (_embeddings @ q_vec).astype(float)
        top_k  = sorted(range(len(scores)), key=lambda i: -scores[i])[:n_results]

        parts = []
        for idx in top_k:
            meta  = _metadata[idx]
            sim   = float(scores[idx])
            doc   = _documents[idx]
            parts.append(
                f"**{meta['path']}** (line {meta['start_line']}, "
                f"similarity {sim:.2f})\n```\n{doc}\n```"
            )

    return "\n\n---\n\n".join(parts)


# --------------------------------------------------------------------------- #
# Entry point
# --------------------------------------------------------------------------- #
def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=DEFAULT_ROOT)
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()

    index_file = Path(args.root) / ".index" / "index.pkl"

    # Start background watcher — loads index immediately, then polls
    threading.Thread(target=_watch_loop, args=(index_file,), daemon=True).start()

    sys.stderr.write(
        f"[lab-knowledge] Starting HTTP/SSE MCP server on port {args.port}\n"
        f"[lab-knowledge] Index: {index_file}\n"
        f"[lab-knowledge] Roo Code endpoint: "
        f"http://aleatico2.imago7.local:{args.port}/sse\n"
    )
    mcp.run(transport="sse", host="0.0.0.0", port=args.port)


if __name__ == "__main__":
    main()
