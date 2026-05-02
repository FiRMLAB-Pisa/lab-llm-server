# Lab LLM Server

Self-hosted AI coding assistant for the lab's NVIDIA A40 server (`aleatico2`).
Replaces GitHub Copilot with fully open-source, on-premises models accessible
to all lab members over the lab LAN and GlobalProtect VPN.

**Stack:**
- **llama-server** (llama.cpp) — serves Qwen3.6-35B-A3B at port 11434 (LAN-accessible, OpenAI-compatible)
- **Roo Code** (VSCode extension) — interactive agentic coding with plan/edit/debug modes; streaming thinking tokens via `openai-compatible` provider
- **MCP codebase search** — per-project semantic search auto-called by Roo Code
- **Lab knowledge base** — shared index of SDKs, libraries, and docs on `/opt/lab-knowledge/`
- **Ollama** (internal, ports 11435/11436) — serves `nomic-embed-text` (embeddings) and `starcoder2:3b` (autocomplete) only; not LAN-accessible

---

## Step 1 — Server Setup (admin, run once on aleatico2)

```bash
git clone https://github.com/<lab-org>/lab-llm-server ~/lab-llm-server
cd ~/lab-llm-server
sudo bash setup.sh
```

`setup.sh` does the following automatically (takes 20–40 min on first run, mostly model download):
1. Builds or installs `llama-server` (llama.cpp) with CUDA support
2. Downloads `Qwen3.6-35B-A3B-UD-Q4_K_M.gguf` (~24 GB) to `/opt/llm/models/`
3. Installs `llama-server` as a systemd service on port 11434 (LAN-accessible, OpenAI-compatible)
4. Installs Ollama (internal only) for embeddings (`nomic-embed-text`, port 11436) and autocomplete (`starcoder2:3b`, port 11435)
5. Stops and removes legacy containers (OpenHands, LiteLLM) if present
6. Installs the `gpu-clear` script
7. Installs Docker (needed for SearXNG and Qdrant)
8. Installs the lab knowledge MCP service on port 3001
9. Installs the lab status dashboard on port 3002
10. Installs SearXNG (internal meta search) and the web search MCP service on port 3003
11. Starts Qdrant vector database on port 6333
12. Runs a quick verification and prints a summary of all service URLs

> **Tip:** The model is ~24 GB. Run setup in a `tmux` session so it survives
> disconnection: `tmux new -s setup && sudo bash setup.sh`

### Verify the server

Run this quick smoke check immediately after `setup.sh` to validate core services.
For a full PASS (including Lab Knowledge checks), run smoke test again after
Step 4 has completed at least one successful index build.

```bash
bash ~/lab-llm-server/smoke-test.sh
```

Expected: core services pass immediately after setup. Lab Knowledge-related checks
may fail until `/opt/lab-knowledge` is populated and indexed. Failures print the
exact remediation command.

---

## Step 2 — Client Onboarding (each lab member, each machine, once)

See **`lab-llm-client/README.md`** for the full guide. Summary:

1. Install VSCode + Remote-SSH extension
2. Run `bash ~/lab-llm-client/check-connectivity.sh` (confirms LAN/VPN access)
3. Add SSH key to all servers (one-time — no more password prompts)
4. Add the SSH config block for all lab servers
5. Connect VSCode: `F1` → *Remote-SSH: Connect to Host* → `aleatico2`
6. In the VSCode Remote-SSH terminal, run the member onboarding script:
   ```bash
   bash ~/lab-llm-client/onboard.sh
   ```
   This installs VSCode server-side extensions and the MCP helper venv needed for codebase search.

---

## Step 3 — Start a New Project (each project, once)

```bash
git clone https://github.com/<lab-org>/lab-workspace-template ~/M/my-project
cd ~/M/my-project
git config core.hooksPath .git-hooks          # prevents committing personal interpreter path
```

Then `File → Open Folder → ~/M/my-project` in VSCode. The Python extension will prompt
you to select an interpreter — pick whichever conda env or venv you prefer; VSCode remembers
it per-machine. Roo Code is pre-configured — open the panel and start chatting.

### Enable Roo Code codebase indexing (per project, once)

Roo Code has a built-in local RAG index that lets it search your project files
automatically, without you having to reference them explicitly. Set it up once per
project the first time you open it:

1. Open the **Roo Code panel** (sidebar icon) → click the **Codebase Indexing** tab
   (database icon at the top of the panel).
2. Fill in the fields exactly as follows:

   | Field | Value |
   |---|---|
   | Embedder Provider | `Ollama` |
   | Base URL | `http://aleatico2.imago7.local:11436` |
   | API Key | *(leave empty)* |
   | Model | `nomic-embed-text` *(type in — not a dropdown)* |
   | Model Dimension | `768` |
   | Qdrant URL | `http://aleatico2.imago7.local:6333` |
   | Qdrant API Key | *(leave empty)* |

3. Click **Save and Start Indexing**. A yellow indicator means indexing in progress;
   green means ready. On a typical project this takes 1–2 minutes; subsequent
   re-indexes are incremental.

The index is stored in `.roo-index/` inside the project directory. Add it to `.gitignore`
to avoid committing it:

```bash
echo ".roo-index/" >> .gitignore
```

Roo will automatically re-index when files change. You can also trigger a manual
re-index from the same tab at any time.

**How this works alongside the lab knowledge MCP (`search_knowledge`):**

Both are active at the same time — they are not alternatives.

| | Roo codebase index | Lab knowledge MCP |
|---|---|---|
| Scope | Current workspace only | All repos in `/opt/lab-knowledge/` |
| How it fires | **Passively** — Roo retrieves relevant chunks and injects them into the context before the model sees your message. The model is not aware this happened. | **Actively** — the model decides to call `search_knowledge` as an explicit tool when it judges external context is needed. You can see these calls in the chat. |
| Best for | The project you're actively editing | Cross-repo context: SDKs, vendor docs, shared libs |

On any given turn, both can fire independently: the codebase index is always injected
passively, and the model may additionally call the knowledge MCP if it decides it needs
more context. There is no "switching" between them.

---

## Step 4 — Populate the Lab Knowledge Base (admin, as material becomes available)

Drop any source code, SDK headers, or documentation into `/opt/lab-knowledge/`:

```bash
# Examples — add whatever is relevant to your lab:
sudo git clone https://github.com/pulseq/pulseq          /opt/lab-knowledge/repos/pulseq
sudo git clone https://github.com/imr-framework/pypulseq  /opt/lab-knowledge/repos/pypulseq
sudo git clone https://github.com/mrirecon/bart           /opt/lab-knowledge/repos/bart
sudo git clone https://github.com/gadgetron/gadgetron     /opt/lab-knowledge/repos/gadgetron
sudo git clone https://github.com/dipy/dipy               /opt/lab-knowledge/repos/dipy
sudo cp -r /path/to/epic-sdk                              /opt/lab-knowledge/repos/epic-sdk

# PDF manuals (EPIC docs, vendor manuals, papers, etc.)
sudo apt install poppler-utils      # one-time — enables PDF text extraction
sudo cp EPIC_manual.pdf             /opt/lab-knowledge/docs/
sudo cp GE_sdk_reference.pdf        /opt/lab-knowledge/docs/
```

---

### One-time manual index build (with progress bar)

For best feedback, run the indexer manually after adding material:

```bash
sudo /opt/lab-server/.venv-lab-mcp/bin/python /opt/lab-server/lab-knowledge-index.py
```

This shows a live progress bar and detailed output.

---

### Enable nightly auto-indexing (systemd timer)

After the manual run, enable the nightly refresh:

```bash
sudo systemctl enable --now lab-knowledge-index.timer
```

This will re-index automatically every night at 02:00. To monitor background runs:

```bash
journalctl -fu lab-knowledge-index
```

---

# After the first index completes, run full smoke validation:
bash ~/lab-llm-server/smoke-test.sh
```

The knowledge base re-indexes automatically every night at 02:00.
Roo Code calls `search_knowledge()` automatically — no user action needed.

### Keeping the knowledge base clean

The indexer automatically skips common junk directories (`.git`, `build`,
`__pycache__`, etc.). It also skips these directories by name anywhere in the
tree — so the convention for retiring outdated material is simple:

```bash
# Move outdated protocols or old SDK versions out of the active index:
sudo mv /opt/lab-knowledge/docs/protocol_v1.md \
        /opt/lab-knowledge/archive/protocol_v1.md

# These directory names are all excluded automatically:
#   archive/  archived/  deprecated/  old/  backup/  legacy/  obsolete/
```

No re-configuration needed — just move the file and the next nightly index
run will drop it from retrieval.

**Practical rule:** if two versions of a protocol exist, keep the current one
in `docs/` and move the old one to `archive/`. The AI will only see the current
version.

### PDF manuals

The indexer already handles PDFs — it extracts text with `pdftotext` (poppler)
and chunks it like any other file. This works well for:
- Text-based PDF manuals (GE EPIC docs, vendor SDK references, course slides)
- Papers where you want the abstract/methods searchable

It does **not** need vision — `pdftotext` extracts text directly from the PDF's
internal representation, which is reliable for all properly generated PDFs.
Only scanned documents (image-only PDFs) would need OCR; those are rare in
technical documentation.

> For EPIC specifically: drop PDF manuals in `/opt/lab-knowledge/docs/` and the
> C/C++ header files from the SDK in `/opt/lab-knowledge/repos/epic-sdk/`.
> The indexer will embed both. Headers give precise API coverage; the PDFs add
> narrative context (protocols, timing diagrams, conceptual explanations).
## GPU Sharing and Scientific Jobs

If you need to run a GPU-intensive job (PyTorch, TensorFlow, CUDA):

1. **Book a slot** on the lab calendar and notify other users.
2. **Before starting your job:** run `sudo systemctl stop llama-server && sudo gpu-clear` — stops inference and frees all GPU memory.
3. **Confirm GPU is free:** `nvidia-smi`
4. **Run your job.**
5. **After finishing:** `sudo systemctl start llama-server` — llama-server reloads the model automatically.

> If you skip stopping llama-server, your job will fail with "CUDA out of memory" — the model occupies ~42 GB.

---

## Models and Modes

| Roo Code Mode | Model | VRAM | Purpose |
|---|---|---|---|
| **Orchestrator** | `Qwen3.6-35B-A3B` (llama-server) | ~24 GB weights + KV | Meta-agent: breaks complex tasks into subtasks, delegates automatically |
| Architect | `Qwen3.6-35B-A3B` | ~24 GB weights + KV | Planning, understanding unfamiliar code |
| Code | `Qwen3.6-35B-A3B` | ~24 GB weights + KV | File edits, terminal commands, tool use |
| Ask | `Qwen3.6-35B-A3B` | ~24 GB weights + KV | Quick Q&A, explanations — fast, tool-capable |
| Debug | `Qwen3.6-35B-A3B` | ~24 GB weights + KV | Tracing errors, reading tracebacks |
| Autocomplete | `starcoder2:3b` (Ollama, port 11435) | ~2 GB | Ghost-text tab completion (Continue.dev) |

All Roo Code modes use the single `Qwen3.6-35B-A3B` MoE model served by `llama-server`.
The model is a Mixture-of-Experts with ~3B active parameters per token at Q4_K_M quantisation.
Thinking is streamed via `reasoning_content` (deepseek format) — visible in real time in Roo Code's chat panel.

VRAM budget: ~24 GB weights + ~18 GB KV cache (256K × 3 slots, q4_0) + ~2 GB starcoder2:3b
+ ~3 GB CUDA overhead ≈ 47 GB total. Tight on 48 GB A40 — if OOM at startup, reduce context to
`-c 393216` (128K × 3) in `/opt/llm/start-llama-server.sh` and restart the service.

**Multi-user:** up to 3 simultaneous requests (`--parallel 3`).
Requests beyond 3 are queued, not rejected. Monitor in real time: `watch -n 2 nvidia-smi`

### Updating models

When a new Qwen3.6 GGUF release appears on HuggingFace (bartowski or unsloth), update as follows:

```bash
# Download new model file to /opt/llm/models/
sudo curl -fL -o /opt/llm/models/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf \
    https://huggingface.co/unsloth/Qwen3.6-35B-A3B-GGUF/resolve/main/Qwen3.6-35B-A3B-UD-Q4_K_M.gguf

# Restart the service to pick up the new file
sudo systemctl restart llama-server

# Confirm it loaded
curl http://127.0.0.1:11434/v1/models
```

### Upgrading the model architecture (replacing model families)

When a better model family becomes available, use `migrate-models.sh` to pull new models, verify inference, then remove deprecated ones safely:

```bash
# Dry-run first — see exactly what will be pulled and removed:
bash ~/lab-llm-server/migrate-models.sh --dry-run

# Apply the migration:
bash ~/lab-llm-server/migrate-models.sh

# Confirm all services still pass:
bash ~/lab-llm-server/smoke-test.sh
```

After migration, update the workspace template and notify users to pull and reload:

```bash
git -C ~/lab-workspace-template pull
# Users: git pull in their project repo, then F1 → Developer: Reload Window in VSCode
```

> **GPU sharing:** before any job that needs full VRAM, stop llama-server first:
> `sudo systemctl stop llama-server && sudo gpu-clear`
> After the job, restart: `sudo systemctl start llama-server`

To switch to a newer quantisation of the same model or a new GGUF release, download the new file to `/opt/llm/models/`, update the path in `/opt/llm/start-llama-server.sh`, and restart the service. See the "Updating models" section above.

---

## Services Summary

| Service | Port | URL | Purpose |
|---|---|---|---|
| **llama-server** | **11434** | **`http://aleatico2.imago7.local:11434/v1`** | **Main LLM inference — Qwen3.6-35B-A3B (Roo Code / all modes)** |
| Ollama (embeddings) | 11436 | `127.0.0.1:11436` (internal) | Embeddings for lab knowledge + Qdrant indexing |
| Ollama (autocomplete) | 11435 | `http://aleatico2.imago7.local:11435` | Tab autocomplete — starcoder2:3b |
| Lab Knowledge MCP | 3001 | `http://aleatico2.imago7.local:3001/sse` | Semantic search over lab SDKs/docs |
| **Status dashboard** | **3002** | **`http://aleatico2.imago7.local:3002`** | **Live GPU/model/service status** |
| Web Search MCP | 3003 | `http://aleatico2.imago7.local:3003/sse` | Live web search via SearXNG |
| **Qdrant** | **6333** | **`http://aleatico2.imago7.local:6333`** | **Vector DB for Roo Code codebase indexing** |
| SearXNG | 8080 | `http://127.0.0.1:8080` (localhost only) | Meta search engine (internal) |

All services are reachable from the lab LAN and GlobalProtect VPN.
Do **not** expose these ports to the public internet.

### Management commands

```bash
# llama-server (main inference — port 11434)
sudo systemctl status llama-server
sudo systemctl restart llama-server
journalctl -fu llama-server

# Ollama (embeddings — port 11436, internal)
sudo systemctl status ollama
sudo systemctl restart ollama
journalctl -fu ollama

# Ollama (autocomplete — port 11435, starcoder2:3b)
sudo systemctl status ollama-autocomplete
sudo systemctl restart ollama-autocomplete
journalctl -fu ollama-autocomplete

# Lab knowledge MCP server
sudo systemctl status lab-knowledge
journalctl -fu lab-knowledge

# Rebuild knowledge index now (instead of waiting for 02:00 timer)
sudo systemctl start lab-knowledge-index.service
journalctl -fu lab-knowledge-index

# Status dashboard
sudo systemctl status lab-status
journalctl -fu lab-status

# Web search MCP + SearXNG
sudo systemctl status lab-websearch
journalctl -fu lab-websearch
docker compose -f ~/lab-llm-server/searxng-compose.yml ps
docker compose -f ~/lab-llm-server/searxng-compose.yml logs -f
# If internet connectivity is restored after firewall re-auth:
docker compose -f ~/lab-llm-server/searxng-compose.yml restart

# Stop llama-server and free GPU before a scientific job
sudo systemctl stop llama-server && sudo gpu-clear
# Restart after job completes
sudo systemctl start llama-server
```

---

## Recovery

All services are configured to **restart automatically** on crash and on server reboot — no admin action is normally needed.

| Event | What happens |
|---|---|
| llama-server crashes | systemd restarts it within 10 s |
| Lab Knowledge / Status crash | systemd restarts within 5 s |
| Server reboots | All services up within ~60 s of boot (model load takes ~30 s) |

### Force-restart everything (e.g. after a hang or full stack issue)

```bash
sudo bash ~/lab-llm-server/restart-services.sh
```

Restarts all five services in order and prints their status. Takes under 10 seconds.

### Restart a single service

```bash
sudo systemctl restart llama-server     # most common — clears hung model state
sudo systemctl restart lab-knowledge
sudo systemctl restart lab-status
```

### If Docker itself is stuck

```bash
sudo systemctl restart docker
docker compose -f ~/lab-llm-server/searxng-compose.yml up -d
docker compose -f ~/lab-llm-server/qdrant-compose.yml up -d
```

---

## Security

- All services bind to `0.0.0.0` — accessible on the trusted lab LAN and GlobalProtect VPN.
- SearXNG binds to `127.0.0.1:8080` (localhost only) — not reachable from the network; only the web search MCP server calls it.
- Do **not** expose ports 11434, 3001, 3002, 3003, or 6333 to the public internet.
- If `aleatico2` ever gets a public IP, add nginx basic auth in front of each service.
- **Firewall note:** the lab firewall occasionally drops aleatico2’s internet access and requires manual re-authentication. When this happens, web search returns a connectivity error; all local tools (Roo Code, codebase search, lab knowledge) remain fully functional.
---

## Migrating to a New Host Machine

If you need to move the LLM stack to a different server (hardware upgrade, machine swap, etc.):

### 1. Set up the new machine

```bash
git clone https://github.com/<lab-org>/lab-llm-server ~/lab-llm-server
cd ~/lab-llm-server
sudo bash setup.sh          # ~20–40 min (model downloads)

# Quick infra check (Lab Knowledge checks may fail until index exists)
bash smoke-test.sh

# After transferring/populating /opt/lab-knowledge and rebuilding index,
# run smoke test again for full PASS.
```

### 2. Update the hostname in three repos

The hostname `aleatico2.imago7.local` is referenced in **three places**. If the new machine has a different hostname, update all of them and push:

| File | What to change |
|---|---|
| `lab-workspace-template/.vscode/settings.json` | `openAiBaseUrl` + all three MCP server `url` fields |
| `lab-llm-client/check-connectivity.sh` | All server hostnames |

> **Simplest alternative:** configure DNS/DHCP so the new machine answers to the same
> `aleatico2.imago7.local` name — then no file changes are needed.

### 3. Propagate to lab members

Commit and push the updated `lab-workspace-template`. Members get the new hostname
automatically on their next `git pull` in any project and `F1 → Developer: Reload Window`.

They do **not** need to re-run `onboard.sh` — extensions and the MCP venv remain valid.

### 4. Transfer the knowledge base (optional)

The lab knowledge index lives at `/opt/lab-knowledge/` on the old machine:

```bash
# On the old machine — archive the knowledge base
sudo tar -czf /tmp/lab-knowledge.tar.gz /opt/lab-knowledge/

# Copy to new machine (run from the old machine)
scp /tmp/lab-knowledge.tar.gz <YOU>@<new-host>:/tmp/

# On the new machine — restore
sudo tar -xzf /tmp/lab-knowledge.tar.gz -C /
sudo systemctl start lab-knowledge-index.service   # rebuild embeddings
```
