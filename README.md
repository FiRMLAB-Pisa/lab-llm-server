# Lab LLM Server

Self-hosted AI coding assistant for the lab's NVIDIA A40 server (`aleatico2`).
Replaces GitHub Copilot with fully open-source, on-premises models accessible
to all lab members over the lab LAN and GlobalProtect VPN.

**Stack:**
- **Ollama** — serves DeepSeek R1 and Qwen2.5-Coder models (LAN-accessible)
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
2. Pulls all models: `deepseek-r1:32b`, `qwen2.5-coder:14b`, `deepseek-r1:7b`, `nomic-embed-text`
3. Installs the `gpu-clear` script
4. Installs Docker and starts the OpenHands background agent on port 3000
5. Installs the lab knowledge MCP service on port 3001
6. Prints a verification summary

> **Tip:** The 32B model is ~20 GB. Run setup in a `tmux` session so it survives
> disconnection: `tmux new -s setup && sudo bash setup.sh`

### Verify the server

```bash
bash ~/lab-llm-server/smoke-test.sh
```

Expected: all `[PASS]` lines. Failures print the exact remediation command.

---

## Step 2 — Client Onboarding (each lab member, each machine, once)

See **`lab-llm-client/README.md`** for the full guide. Summary:

1. Install VSCode + Remote-SSH extension
2. Run `bash lab-llm-client/check-connectivity.sh` (confirms LAN/VPN access)
3. Add SSH key to all servers (one-time — no more password prompts)
4. Add the SSH config block for all lab servers
5. Connect VSCode: `F1` → *Remote-SSH: Connect to Host* → `aleatico2`
6. In the VSCode Remote-SSH terminal, run the member onboarding script:
   ```bash
   bash ~/lab-llm-server/onboard.sh
   ```
   This creates your per-member conda environment and installs all VSCode server-side extensions.

---

## Step 3 — Start a New Project (each project, once)

```bash
git clone https://github.com/<lab-org>/lab-workspace-template ~/M/my-project
cd ~/M/my-project
git config core.hooksPath .git-hooks          # prevents committing personal interpreter path
conda activate <YOUR_ENV>
pip install -r requirements.txt               # skip if empty
```

Then `File → Open Folder → ~/M/my-project` in VSCode.
Roo Code is pre-configured — open the panel and start chatting.

---

## Step 4 — Try the Examples (verify end-to-end)

| File | What to try |
|---|---|
| `examples/mri_signal.py` | Roo Code **Ask** mode → *"What does ernst_angle compute?"* |
| `examples/mri_signal.py` | Roo Code **Code** mode → *"Add an inversion recovery signal function"* |
| `examples/kspace.py` | Roo Code **Code** mode → *"Write pytest tests for all public functions"* |
| `examples/workflows.ipynb` | Follow the embedded workflow instructions in each cell |

For the background agent:
1. Open `http://aleatico2.imago7.local:3000`
2. Set workspace to `/home/<you>/M/my-project`
3. Paste the OpenHands task from `examples/workflows.ipynb` (Workflow I)

---

## Step 5 — Populate the Lab Knowledge Base (admin, as material becomes available)

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

# Trigger the first index run (watch progress):
sudo systemctl start lab-knowledge-index.service
journalctl -fu lab-knowledge-index
```

The knowledge base re-indexes automatically every night at 02:00.
Roo Code calls `search_knowledge()` automatically — no user action needed.

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

## Shared Conda Environments (admin, run once)

```bash
source /opt/conda/etc/profile.d/conda.sh

# Common scientific stack
conda create -n lab-base -y python=3.11 numpy scipy matplotlib pandas \
    jupyter ipykernel scikit-learn tqdm

# Neuroimaging (hard-link clone — minimal extra disk)
conda create -n lab-neuro --clone lab-base -y
conda run -n lab-neuro pip install nibabel nilearn dipy antspy

# MRI physics / pulse sequences
conda create -n lab-mri --clone lab-base -y
conda run -n lab-mri pip install sigpy ismrmrd twixtools
```

`conda create --clone` uses hard links — far less disk than independent environments.
Check disk usage: `du -sh /opt/conda/envs/*`

---

## Models and Modes

| Roo Code Mode | Model | VRAM | Purpose |
|---|---|---|---|
| Architect | `deepseek-r1:32b` | ~20 GB | Planning, understanding unfamiliar code |
| Code | `qwen2.5-coder:14b` | ~9 GB | File edits, terminal commands, tool use |
| Ask | `deepseek-r1:7b` | ~5 GB | Quick Q&A, explanations |
| Debug | `qwen2.5-coder:14b` | ~9 GB | Tracing errors, reading tracebacks |
| Autocomplete | `starcoder2:3b` | ~2 GB | Ghost-text tab completion (Continue.dev) |

32B + 14B loaded simultaneously = ~29 GB VRAM, leaving ~17 GB for KV cache.
`nomic-embed-text` and `starcoder2:3b` are small — minimal VRAM impact.

**Multi-user:** configured for up to 10 simultaneous users (`OLLAMA_NUM_PARALLEL=10`).
Roo Code sessions and OpenHands tasks share the same pool — any mix up to 10 is fine.
Monitor in real time: `watch -n 2 nvidia-smi`

### Updating models

New DeepSeek and Qwen releases appear every few months and bring meaningful
quality improvements. Run the update script monthly (no service restart needed —
Ollama picks up new versions automatically from the next request):

```bash
bash ~/lab-llm-server/update-models.sh
```

The script pulls all models, shows what changed, and optionally runs `smoke-test.sh`.
To switch to a different model version entirely (e.g. `deepseek-r1:70b` if VRAM allows),
edit the `MODELS` array in `setup.sh` and `update-models.sh`, then update the mode
assignments in `lab-workspace-template/.vscode/settings.json`.

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

# Status dashboard
sudo systemctl status lab-status
journalctl -fu lab-status

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

Restarts all four services in order and prints their status. Takes under 10 seconds.

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
