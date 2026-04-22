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
import hashlib
import json
import os
import pickle
import re
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
BATCH_SIZE        = 32
CHECKPOINT_EVERY  = 100    # save partial index.pkl every N batches (~3200 chunks)
MAX_CHUNK_CHARS   = 2000   # ~500 tokens — matches cross-encoder/ms-marco-MiniLM-L-6-v2 max_length=512
                           # chunks above this are sub-chunked so the reranker sees complete text
MIN_CHUNK_CHARS   = 40     # skip trivial blank/whitespace-only chunks
_FALLBACK_LINES   = 40     # fixed-line chunk size used when no semantic boundaries found
_FALLBACK_OVERLAP = 8      # overlap lines for fixed-line fallback

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
    # Stale/archived content — move outdated material here to exclude from index
    "archive", "archived", "deprecated", "old", "backup", "backups",
    "legacy", "unused", "obsolete", "tmp", "temp",
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


# --------------------------------------------------------------------------- #
# Semantic chunkers
# --------------------------------------------------------------------------- #
_PY_BOUNDARY   = re.compile(r'^(def |class |async def )')
_M_BOUNDARY    = re.compile(r'^function\s+\w')   # MATLAB / Julia
_C_CLOSE       = re.compile(r'^\}\s*$')           # lone } = end of C/C++ block
_MD_HEADING    = re.compile(r'^#{1,3}\s')
_RST_UNDERLINE = re.compile(r'^[=\-~^`\'"#*+]{3,}\s*$')


def _text_hash(text: str) -> str:
    """Stable SHA-256 of normalised text — used for deduplication."""
    normalised = re.sub(r'\s+', ' ', text.strip().lower())
    return hashlib.sha256(normalised.encode()).hexdigest()


def doc_type_for(path: Path) -> str:
    suf = path.suffix.lower()
    if suf in {'.py', '.m', '.c', '.h', '.cpp', '.cc', '.cu', '.cuh', '.jl'}:
        return 'code'
    if suf in {'.md', '.rst', '.txt'}:
        return 'docs'
    if suf == '.pdf':
        return 'pdf'
    if suf == '.ipynb':
        return 'notebook'
    return 'config'


def priority_for(path: Path, root: Path) -> int:
    rel = str(path.relative_to(root)).lower()
    if any(p in rel for p in ('protocol', 'manual', 'spec', 'reference')):
        return 10
    if any(p in rel for p in ('paper', 'publi', 'article', 'preprint')):
        return 8
    if path.suffix.lower() in {'.py', '.m', '.c', '.h', '.cpp', '.cu', '.cuh', '.jl'}:
        return 5
    return 3


def _section_starts(lines: list[str], suf: str) -> list[int]:
    """Return sorted line indices where a new top-level logical section begins."""
    starts = [0]
    if suf == '.py':
        for i, ln in enumerate(lines):
            if _PY_BOUNDARY.match(ln):
                # Walk backwards to include leading decorator lines
                j = i - 1
                while j >= 0 and lines[j].startswith('@'):
                    j -= 1
                starts.append(j + 1)
    elif suf in ('.m', '.jl'):
        for i, ln in enumerate(lines):
            if _M_BOUNDARY.match(ln):
                starts.append(i)
    elif suf in ('.c', '.h', '.cpp', '.cc', '.cu', '.cuh'):
        for i, ln in enumerate(lines):
            # Lone closing brace = end of top-level block; next chunk starts after it
            if _C_CLOSE.match(ln) and i + 1 < len(lines):
                starts.append(i + 1)
    elif suf == '.md':
        for i, ln in enumerate(lines):
            if _MD_HEADING.match(ln):
                starts.append(i)
    elif suf == '.rst':
        for i, ln in enumerate(lines):
            # RST underline follows the heading title
            if _RST_UNDERLINE.match(ln) and i > 0 and lines[i - 1].strip():
                starts.append(max(0, i - 1))
    return sorted(set(starts))


def _make_chunk(lines: list[str], lo: int, hi: int,
                rel: Path, sig: str, doc_type: str, priority: int) -> dict:
    body   = ''.join(lines[lo:hi]).strip()
    header = f"# Source: {rel}  (lines {lo + 1}\u2013{hi})\n"
    return {
        'id':         f'{rel}::{lo}',
        'text':       header + body,
        'path':       str(rel),
        'start_line': lo + 1,
        'sig':        sig,
        'doc_type':   doc_type,
        'priority':   priority,
    }


def _slice_sections(lines: list[str], starts: list[int],
                    path: Path, root: Path, sig: str) -> list[dict]:
    """Slice lines at semantic section boundaries; sub-chunk oversized sections."""
    rel      = path.relative_to(root)
    doc_type = doc_type_for(path)
    priority = priority_for(path, root)
    chunks: list[dict] = []
    boundaries = starts + [len(lines)]

    for k in range(len(boundaries) - 1):
        lo, hi = boundaries[k], boundaries[k + 1]
        body = ''.join(lines[lo:hi]).strip()
        if not body or len(body) < MIN_CHUNK_CHARS:
            continue

        if len(body) <= MAX_CHUNK_CHARS:
            chunks.append(_make_chunk(lines, lo, hi, rel, sig, doc_type, priority))
        else:
            # Section too large \u2014 sub-chunk with fixed lines + overlap
            i = lo
            while i < hi:
                sub_hi  = min(i + _FALLBACK_LINES, hi)
                sub_body = ''.join(lines[i:sub_hi]).strip()
                if sub_body and len(sub_body) >= MIN_CHUNK_CHARS:
                    chunks.append(_make_chunk(lines, i, sub_hi, rel, sig, doc_type, priority))
                i += _FALLBACK_LINES - _FALLBACK_OVERLAP
    return chunks


def _chunk_paragraphs(text: str, path: Path, root: Path, sig: str) -> list[dict]:
    """Split plain text at blank lines; group paragraphs into chunks \u2264 MAX_CHUNK_CHARS."""
    rel      = path.relative_to(root)
    doc_type = doc_type_for(path)
    priority = priority_for(path, root)
    paras    = re.split(r'\n\s*\n', text)
    chunks: list[dict] = []
    current_parts: list[str] = []
    current_len   = 0
    current_start = 1
    line_offset   = 1

    def _flush() -> None:
        if not current_parts:
            return
        body = '\n\n'.join(current_parts)
        if body.strip() and len(body) >= MIN_CHUNK_CHARS:
            header = f'# Source: {rel}  (approx. line {current_start})\n'
            chunks.append({
                'id':         f'{rel}::{current_start}',
                'text':       header + body,
                'path':       str(rel),
                'start_line': current_start,
                'sig':        sig,
                'doc_type':   doc_type,
                'priority':   priority,
            })

    for para in paras:
        para    = para.strip()
        n_lines = para.count('\n') + 1 if para else 0
        if not para:
            line_offset += 1
            continue
        if current_parts and current_len + len(para) + 2 > MAX_CHUNK_CHARS:
            _flush()
            current_parts = [para]
            current_len   = len(para)
            current_start = line_offset
        else:
            if not current_parts:
                current_start = line_offset
            current_parts.append(para)
            current_len += len(para) + 2
        line_offset += n_lines + 1

    _flush()
    return chunks


def chunk_file(text: str, path: Path, root: Path, sig: str) -> list[dict]:
    """Semantically chunk a source file into indexable pieces.

    Dispatch strategy:
      .txt            \u2192 paragraph grouping
      .py             \u2192 top-level def/class boundaries (with decorator walk-back)
      .m / .jl        \u2192 function keyword boundaries
      .c/.cpp/.h etc. \u2192 closing-brace boundaries
      .md             \u2192 heading (h1\u2013h3) boundaries
      .rst            \u2192 RST underline-detected heading boundaries
      everything else \u2192 fixed-line fallback (_FALLBACK_LINES)
    """
    suf = path.suffix.lower()
    rel      = path.relative_to(root)
    doc_type = doc_type_for(path)
    priority = priority_for(path, root)

    if suf == '.txt':
        return _chunk_paragraphs(text, path, root, sig)

    lines  = text.splitlines(keepends=True)
    starts = _section_starts(lines, suf)

    # If no semantic boundaries found, fall through to fixed-line chunking
    if len(starts) <= 1:
        chunks: list[dict] = []
        i = 0
        while i < len(lines):
            hi   = min(i + _FALLBACK_LINES, len(lines))
            body = ''.join(lines[i:hi]).strip()
            if body and len(body) >= MIN_CHUNK_CHARS:
                chunks.append(_make_chunk(lines, i, hi, rel, sig, doc_type, priority))
            i += _FALLBACK_LINES - _FALLBACK_OVERLAP
        return chunks

    return _slice_sections(lines, starts, path, root, sig)


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
        chunks = chunk_file(text, fpath, root, sig)
        all_chunks.extend(chunks)
        n_files += 1

    log(f"Found {n_files} files \u2192 {len(all_chunks)} raw chunks")

    # Deduplicate: remove chunks whose normalised text is identical
    # (catches copied repos, backup files, generated docs, etc.)
    seen_hashes: set[str] = set()
    deduped: list[dict]   = []
    for chunk in all_chunks:
        h = _text_hash(chunk['text'])
        if h not in seen_hashes:
            seen_hashes.add(h)
            deduped.append(chunk)
    n_dupes = len(all_chunks) - len(deduped)
    if n_dupes:
        log(f"Deduplication: removed {n_dupes} duplicate chunk(s)")
    all_chunks = deduped
    log(f"Chunks after deduplication: {len(all_chunks)}")

    # Partition: split into reusable (unchanged) and to-embed chunks
    to_embed_idx: list[int] = []
    for i, chunk in enumerate(all_chunks):
        cid = chunk["id"]
        if cid in old_map and existing_meta[old_map[cid]]["sig"] == chunk["sig"]:
            pass   # reused below
        else:
            to_embed_idx.append(i)

    n_reuse    = len(all_chunks) - len(to_embed_idx)
    n_to_embed = len(to_embed_idx)
    log(f"Chunks to (re-)embed: {n_to_embed} new/changed  +  {n_reuse} reused  =  {len(all_chunks)} total")

    # Pre-populate final arrays with unchanged chunks (instant — no embedding needed)
    final_embs:  list[np.ndarray] = []
    final_docs:  list[str]        = []
    final_metas: list[dict]       = []
    final_ids:   list[str]        = []

    def _meta(chunk: dict) -> dict:
        return {
            "path":       chunk["path"],
            "start_line": chunk["start_line"],
            "sig":        chunk["sig"],
            "doc_type":   chunk.get("doc_type", "unknown"),
            "priority":   chunk.get("priority", 3),
        }

    for i, chunk in enumerate(all_chunks):
        cid = chunk["id"]
        if cid in old_map and existing_meta[old_map[cid]]["sig"] == chunk["sig"]:
            final_embs.append(existing_embs[old_map[cid]])
            final_docs.append(chunk["text"])
            final_metas.append(_meta(chunk))
            final_ids.append(cid)

    def _save_index(label: str) -> None:
        """Atomically write current final arrays to index.pkl."""
        if not final_embs:
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
        log(f"  [{label}] checkpoint saved — {len(final_ids)} chunks in index")

    def _progress(n_done: int, n_total: int, elapsed: float) -> str:
        pct      = n_done / n_total if n_total else 1.0
        width    = 28
        filled   = int(width * pct)
        arrow    = ">" if filled < width else ""
        bar      = "=" * filled + arrow + " " * (width - filled - len(arrow))
        rate     = n_done / elapsed if elapsed > 0 else 0
        eta_s    = int((n_total - n_done) / rate) if rate > 0 and n_done < n_total else 0
        if eta_s >= 3600:
            eta  = f"{eta_s // 3600}h{(eta_s % 3600) // 60:02d}m"
        elif eta_s >= 60:
            eta  = f"{eta_s // 60}m{eta_s % 60:02d}s"
        else:
            eta  = f"{eta_s}s"
        return (f"  [{bar}] {pct*100:5.1f}%  "
                f"{n_done}/{n_total} chunks  "
                f"{rate:.0f} ch/s  ETA {eta}")

    # Embed new/changed chunks — append to final arrays as we go, checkpoint periodically
    if n_to_embed == 0:
        log("Nothing new to embed — index is up to date")
    else:
        log(f"Starting embedding of {n_to_embed} chunks in batches of {BATCH_SIZE} ...")
        t0     = time.time()
        n_done = 0

        for batch_num, batch_start in enumerate(range(0, n_to_embed, BATCH_SIZE)):
            batch_idx   = to_embed_idx[batch_start : batch_start + BATCH_SIZE]
            batch_texts = [all_chunks[i]["text"] for i in batch_idx]
            try:
                vecs = embed_batch(batch_texts)
            except Exception as e:
                log(f"  WARNING: embedding error (batch {batch_num}, offset {batch_start}): {e} — skipping")
                n_done += len(batch_idx)
                continue

            for ci, vec in zip(batch_idx, vecs):
                chunk = all_chunks[ci]
                final_embs.append(vec)
                final_docs.append(chunk["text"])
                final_metas.append(_meta(chunk))
                final_ids.append(chunk["id"])

            n_done += len(batch_idx)
            elapsed = time.time() - t0
            log(_progress(n_done, n_to_embed, elapsed))

            # Periodic checkpoint — crash-safe: next run reuses all saved chunks
            if (batch_num + 1) % CHECKPOINT_EVERY == 0:
                _save_index(f"batch {batch_num + 1}")

    if not final_embs:
        log("No chunks indexed — is /opt/lab-knowledge/ empty?")
        return

    # Final atomic write
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
