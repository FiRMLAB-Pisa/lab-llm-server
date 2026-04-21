#!/usr/bin/env python3
"""
Lab Knowledge Index Builder
============================
Walks /opt/lab-knowledge/ automatically, embeds every supported file using
nomic-embed-text via Ollama, and saves a vector index to
/opt/lab-knowledge/.index/index.pkl.

Run this once after populating /opt/lab-knowledge/, and again whenever you
add new repos or documents.  A systemd timer re-runs it nightly.

Usage:
    /opt/conda/envs/lab-mcp/bin/python lab-knowledge-index.py [--root /opt/lab-knowledge]

The lab-knowledge-server.py process hot-reloads the index automatically when
this script finishes writing (it detects the mtime change).

Supported file types (auto-discovered, no config needed):
    Source code:  .py .m .c .h .cpp .cu .cuh .jl
    Text/docs:    .md .rst .txt .ipynb
    Config:       .yaml .yml .toml .json .cmake
    PDF:          converted to text via pdftotext (poppler) if available
"""

import argparse
import json
import os
import pickle
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import requests

# --------------------------------------------------------------------------- #
# Config
# --------------------------------------------------------------------------- #
OLLAMA_BASE  = "http://aleatico2.imago7.local:11434"
EMBED_MODEL  = "nomic-embed-text"
BATCH_SIZE   = 32
CHUNK_LINES  = 80     # slightly larger chunks than per-project (docs are verbose)
OVERLAP_LINES = 15

INCLUDE_SUFFIXES = {
    ".py", ".m", ".c", ".h", ".cpp", ".cu", ".cuh", ".jl",
    ".md", ".rst", ".txt",
    ".yaml", ".yml", ".toml", ".json", ".cmake",
    ".ipynb",
    ".pdf",       # handled separately via pdftotext
}

EXCLUDE_DIRS = {
    ".git", ".index", ".mypy_cache", "__pycache__",
    ".venv", "venv", "node_modules", "build", "dist",
    ".ipynb_checkpoints", ".tox", "*.egg-info",
}

EXCLUDE_SUFFIXES = {
    ".pyc", ".pyo", ".so", ".o", ".a", ".dll", ".dylib",
    ".png", ".jpg", ".jpeg", ".gif", ".svg", ".ico",
    ".zip", ".tar", ".gz", ".bz2", ".7z",
    ".nii", ".nii.gz", ".h5", ".hdf5", ".mat", ".bin",
    ".npz", ".npy",
}

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
def log(msg: str) -> None:
    ts = time.strftime("%H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def embed_batch(texts: list[str]) -> np.ndarray:
    resp = requests.post(
        f"{OLLAMA_BASE}/api/embed",
        json={"model": EMBED_MODEL, "input": texts},
        timeout=180,
    )
    resp.raise_for_status()
    vecs = np.array(resp.json()["embeddings"], dtype=np.float32)
    norms = np.linalg.norm(vecs, axis=1, keepdims=True)
    norms = np.where(norms == 0, 1.0, norms)
    return vecs / norms


def file_sig(path: Path) -> str:
    st = path.stat()
    return f"{st.st_mtime:.3f}:{st.st_size}"


def pdf_to_text(path: Path) -> str | None:
    """Convert PDF to plain text using pdftotext (poppler). Returns None if unavailable."""
    try:
        result = subprocess.run(
            ["pdftotext", "-layout", str(path), "-"],
            capture_output=True, text=True, timeout=30,
        )
        return result.stdout if result.returncode == 0 else None
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None


def iter_files(root: Path):
    """Walk root, yield all indexable files."""
    for dirpath, dirs, files in os.walk(root):
        # Prune excluded dirs in-place
        dirs[:] = sorted(
            d for d in dirs
            if d not in EXCLUDE_DIRS and not d.startswith(".")
        )
        for fname in sorted(files):
            p = Path(dirpath) / fname
            if p.suffix.lower() in EXCLUDE_SUFFIXES:
                continue
            if p.suffix.lower() in INCLUDE_SUFFIXES:
                yield p


def read_file(path: Path) -> str | None:
    """Read a file to plain text. Returns None on failure."""
    suf = path.suffix.lower()
    if suf == ".pdf":
        return pdf_to_text(path)
    if suf == ".ipynb":
        try:
            nb = json.loads(path.read_text(errors="replace"))
            parts = []
            for cell in nb.get("cells", []):
                src = cell.get("source", [])
                parts.extend(src if isinstance(src, list) else [src])
                parts.append("\n\n")
            return "".join(parts)
        except Exception:
            return None
    try:
        return path.read_text(errors="replace")
    except Exception:
        return None


def chunk_text(text: str, path: Path, root: Path, sig: str) -> list[dict]:
    lines = text.splitlines(keepends=True)
    rel   = path.relative_to(root)
    chunks = []
    i = 0
    while i < len(lines):
        batch = lines[i : i + CHUNK_LINES]
        body  = "".join(batch).strip()
        if body:
            header = f"# Source: {rel}  (lines {i+1}–{i+len(batch)})\n"
            chunks.append({
                "id":         f"{rel}::{i}",
                "text":       header + body,
                "path":       str(rel),
                "start_line": i + 1,
                "sig":        sig,
            })
        i += CHUNK_LINES - OVERLAP_LINES
    return chunks


# --------------------------------------------------------------------------- #
# Main
# --------------------------------------------------------------------------- #
def build_index(root: Path) -> None:
    index_dir  = root / ".index"
    index_file = index_dir / "index.pkl"
    tmp_file   = index_dir / "index.pkl.tmp"
    index_dir.mkdir(parents=True, exist_ok=True)

    # Load existing index for incremental updates
    existing_embs: np.ndarray | None = None
    existing_docs: list[str]         = []
    existing_meta: list[dict]        = []
    existing_ids:  list[str]         = []

    if index_file.exists():
        try:
            with open(index_file, "rb") as f:
                saved = pickle.load(f)
            existing_embs = saved["embeddings"]
            existing_docs = saved["documents"]
            existing_meta = saved["metadata"]
            existing_ids  = saved["ids"]
            log(f"Loaded existing index: {len(existing_ids)} chunks")
        except Exception as e:
            log(f"Warning: could not load existing index ({e}), rebuilding from scratch")

    old_map = {id_: i for i, id_ in enumerate(existing_ids)}

    # Walk and collect chunks
    log(f"Walking {root} ...")
    all_chunks: list[dict] = []
    n_files = 0
    for fpath in iter_files(root):
        text = read_file(fpath)
        if not text or not text.strip():
            continue
        sig    = file_sig(fpath)
        chunks = chunk_text(text, fpath, root, sig)
        all_chunks.extend(chunks)
        n_files += 1

    log(f"Found {n_files} files → {len(all_chunks)} chunks")

    # Partition: reuse existing embeddings where file unchanged
    to_embed_idx: list[int] = []   # indices into all_chunks
    for i, chunk in enumerate(all_chunks):
        cid = chunk["id"]
        if cid in old_map and existing_meta[old_map[cid]]["sig"] == chunk["sig"]:
            pass   # will copy below
        else:
            to_embed_idx.append(i)

    log(f"Chunks to (re-)embed: {len(to_embed_idx)} / {len(all_chunks)}")

    # Embed new/changed chunks
    new_vecs: dict[int, np.ndarray] = {}   # chunk index → vector
    for batch_start in range(0, len(to_embed_idx), BATCH_SIZE):
        batch_idx   = to_embed_idx[batch_start : batch_start + BATCH_SIZE]
        batch_texts = [all_chunks[i]["text"] for i in batch_idx]
        try:
            vecs = embed_batch(batch_texts)
        except Exception as e:
            log(f"Embedding error (batch starting at {batch_start}): {e}")
            continue
        for ci, vec in zip(batch_idx, vecs):
            new_vecs[ci] = vec
        if (batch_start // BATCH_SIZE) % 10 == 0:
            log(f"  Embedded {min(batch_start + BATCH_SIZE, len(to_embed_idx))}"
                f" / {len(to_embed_idx)} chunks")

    # Assemble final arrays
    final_embs:  list[np.ndarray] = []
    final_docs:  list[str]        = []
    final_metas: list[dict]       = []
    final_ids:   list[str]        = []

    for i, chunk in enumerate(all_chunks):
        cid = chunk["id"]
        if i in new_vecs:
            vec = new_vecs[i]
        elif cid in old_map:
            vec = existing_embs[old_map[cid]]
        else:
            continue   # embedding failed, skip
        final_embs.append(vec)
        final_docs.append(chunk["text"])
        final_metas.append({"path": chunk["path"], "start_line": chunk["start_line"],
                             "sig": chunk["sig"]})
        final_ids.append(cid)

    if not final_embs:
        log("No chunks indexed — is /opt/lab-knowledge/ empty?")
        return

    matrix = np.stack(final_embs, axis=0)

    with open(tmp_file, "wb") as f:
        pickle.dump({
            "embeddings": matrix,
            "documents":  final_docs,
            "metadata":   final_metas,
            "ids":        final_ids,
        }, f, protocol=pickle.HIGHEST_PROTOCOL)
    tmp_file.replace(index_file)

    log(f"Index saved: {len(final_ids)} chunks, matrix shape {matrix.shape}")
    log(f"Index file: {index_file}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default="/opt/lab-knowledge",
                        help="Root directory to index (default: /opt/lab-knowledge)")
    args = parser.parse_args()
    root = Path(args.root)
    if not root.exists():
        print(f"Error: {root} does not exist.  Create it and populate it first.")
        sys.exit(1)
    build_index(root)
