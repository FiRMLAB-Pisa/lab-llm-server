# Lab LLM Server

Self-hosted AI coding assistant for the lab's NVIDIA A40 server (`aleatico2`).
Replaces GitHub Copilot with fully open-source, on-premises models accessible
to all lab members over the lab LAN and GlobalProtect VPN.

**Stack:**
- **Ollama** — serves Qwen3.5 and Devstral models (LAN-accessible)
- **Roo Code** (VSCode extension) — interactive agentic coding with plan/edit/debug modes
- **OpenHands** — browser-based background agent (async tasks, no editor needed)
- **MCP codebase search** — per-project semantic search auto-called by Roo Code
- **Lab knowledge base** — shared index of SDKs, libraries, and docs on `/opt/lab-knowledge/`

---

## Step 1 — Server Setup (admin, run once on aleatico2)

```bash
git clone https://github.com/<lab-org>/lab-llm-server ~/lab-llm-server
cd ~/lab-llm-server
sudo bash setup.sh
```

`setup.sh` does the following automatically (takes 20–40 min, mostly model downloads):
1. Installs Ollama and configures it as a systemd service bound to all interfaces
2. Pulls all models: `qwen3.5:35b`, `devstral-small-2`, `qwen3.5:9b`, `nomic-embed-text`, `starcoder2:3b`
3. Installs the `gpu-clear` script
4. Installs Docker and starts the OpenHands background agent on port 3000
5. Installs the lab knowledge MCP service on port 3001
6. Installs the lab status dashboard on port 3002
7. Installs SearXNG (internal meta search) and the web search MCP service on port 3003
8. Runs a quick verification and prints a summary of all service URLs

> **Tip:** The 35B model is ~24 GB. Run setup in a `tmux` session so it survives
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
2. Under **Embeddings Provider**, select **Ollama**.
3. Set the **Base URL** to `http://aleatico2.imago7.local:11434`.
4. Set the **Model** to `nomic-embed-text` (already running — no extra download needed).
5. Click **Index Workspace** and wait for the progress bar to complete.
   On a large project this takes 1–2 minutes; subsequent re-indexes are incremental.

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
2. **Before starting your job:** run `sudo gpu-clear` — immediately unloads all models from GPU.
3. **Confirm GPU is free:** `nvidia-smi`
4. **Run your job.**
5. **After finishing:** Ollama reloads models automatically on the next LLM request.

> If you skip `gpu-clear`, your job may fail with "CUDA out of memory".

---

## Models and Modes

| Roo Code Mode | Model | VRAM | Purpose |
|---|---|---|
---|
| **Orchestrator** | `qwen3.5:35b` | ~24 GB | Meta-agent: breaks complex tasks into subtasks, delegates automatically |
| Architect | `qwen3.5:35b` | ~24 GB | Planning, understanding unfamiliar code |
| Code | `devstral-small-2` | ~15 GB | File edits, terminal commands, tool use — SWE-bench specialist |
| Ask | `qwen3.5:9b` | ~7 GB | Quick Q&A, explanations — fast, tool-capable |
| Debug | `devstral-small-2` | ~15 GB | Tracing errors, reading tracebacks |
| Autocomplete | `starcoder2:3b` | ~2 GB | Ghost-text tab completion (Continue.dev) |

Orchestrator and Architect share the 35B model — only one copy is loaded.
35B or 24B loaded at a time = 24 GB peak VRAM, leaving ~24 GB for KV cache.
`nomic-embed-text` and `starcoder2:3b` are small — minimal VRAM impact.

**Multi-user:** configured for up to 10 simultaneous users (`OLLAMA_NUM_PARALLEL=10`).
Roo Code sessions and OpenHands tasks share the same pool — any mix up to 10 is fine.
Monitor in real time: `watch -n 2 nvidia-smi`

### Updating models

New Qwen and Devstral releases appear every few months and bring meaningful
quality improvements. Run the update script monthly (no service restart needed —
Ollama picks up new versions automatically from the next request):

```bash
bash ~/lab-llm-server/update-models.sh
```

The script pulls all models, shows what changed, and optionally runs `smoke-test.sh`.

### Upgrading the model architecture (replacing model families)

When a better model family becomes available (as happened moving from DeepSeek→Qwen3.5/Devstral),
use `migrate-models.sh` to pull new models, verify inference, then remove deprecated ones safely:

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
git -C ~/lab-workspace-template pull   # on aleatico2 or wherever the template lives
# Users: git pull in their project repo, then F1 → Developer: Reload Window in VSCode
# Users: set sticky model per mode once (see client README Quick Start)
```

To switch to a specific model version (e.g. `qwen3.5:35b-q8_0` if VRAM allows),
edit the `MODELS` array in `setup.sh` and `update-models.sh`, then update
`lab-workspace-template/.vscode/settings.json` and run `migrate-models.sh`.

---

## Services Summary

| Service | Port | URL | Purpose |
|---|---|---|---|
| Ollama | 11434 | `http://aleatico2.imago7.local:11434` | LLM inference (Roo Code backend) |
| OpenHands | 3000 | `http://aleatico2.imago7.local:3000` | Browser-based background agent |
| Lab Knowledge MCP | 3001 | `http://aleatico2.imago7.local:3001/sse` | Semantic search over lab SDKs/docs |
| **Status dashboard** | **3002** | **`http://aleatico2.imago7.local:3002`** | **Live GPU/model/service status** |
| Web Search MCP | 3003 | `http://aleatico2.imago7.local:3003/sse` | Live web search via SearXNG |
| SearXNG | 8080 | `http://127.0.0.1:8080` (localhost only) | Meta search engine (internal) |

All services are reachable from the lab LAN and GlobalProtect VPN.
Do **not** expose these ports to the public internet.

### Management commands

```bash
# Ollama
sudo systemctl status ollama
sudo systemctl restart ollama
journalctl -fu ollama

# OpenHands
docker compose -f ~/lab-llm-server/openhands-compose.yml ps
docker compose -f ~/lab-llm-server/openhands-compose.yml logs -f
docker compose -f ~/lab-llm-server/openhands-compose.yml down
docker compose -f ~/lab-llm-server/openhands-compose.yml up -d

# Update OpenHands image only (without touching Ollama or other services)
bash ~/lab-llm-server/update-openhands.sh

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

# Free GPU before a scientific job
sudo gpu-clear
```

---

## Recovery

All services are configured to **restart automatically** on crash and on server reboot — no admin action is normally needed.

| Event | What happens |
|---|---|
| Ollama crashes | systemd restarts it within 5 s |
| OpenHands crashes | Docker restarts it within 5 s |
| Lab Knowledge / Status crash | systemd restarts within 5 s |
| Server reboots | All services up within ~30 s of boot |

### Force-restart everything (e.g. after a hang or full stack issue)

```bash
sudo bash ~/lab-llm-server/restart-services.sh
```

Restarts all five services in order and prints their status. Takes under 10 seconds.

### Restart a single service

```bash
sudo systemctl restart ollama          # most common — fixes hung model
sudo systemctl restart lab-knowledge
sudo systemctl restart lab-status
docker compose -f ~/lab-llm-server/openhands-compose.yml restart
```

### If Docker itself is stuck

```bash
sudo systemctl restart docker
docker compose -f ~/lab-llm-server/openhands-compose.yml up -d
```

---

## Security

- All services bind to `0.0.0.0` — accessible on the trusted lab LAN and GlobalProtect VPN.
- SearXNG binds to `127.0.0.1:8080` (localhost only) — not reachable from the network; only the web search MCP server calls it.
- Do **not** expose ports 11434, 3000, 3001, 3002, or 3003 to the public internet.
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
| `lab-llm-server/openhands-compose.yml` | `SANDBOX_RUNTIME_CONTAINER_IMAGE` env if host-referenced |

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
