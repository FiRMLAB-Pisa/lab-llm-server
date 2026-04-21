#!/usr/bin/env python3
"""lab-status-server.py — Lab LLM stack status dashboard

Serves a self-contained HTML status page on port 3002.
Accessible from any browser on the lab LAN or GlobalProtect VPN:
    http://aleatico2.imago7.local:3002

No external dependencies — stdlib only.
Auto-refreshes every 10 seconds.

Shows:
    - GPU: VRAM used / free / utilisation (per GPU)
    - Ollama: loaded models + VRAM per model + keep-alive expiry
    - Services: Ollama, OpenHands, Lab Knowledge MCP
    - Quick links to each service
"""

import json
import subprocess
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.error import URLError
from urllib.request import urlopen

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 3002
OLLAMA_URL = "http://127.0.0.1:11434"


# --------------------------------------------------------------------------- #
# Data collectors
# --------------------------------------------------------------------------- #

def ollama_ps():
    """Return list of loaded models from /api/ps, or error string."""
    try:
        with urlopen(f"{OLLAMA_URL}/api/ps", timeout=3) as r:
            return json.loads(r.read()).get("models", []), None
    except URLError as e:
        return [], f"Connection refused — is Ollama running? ({e.reason})"
    except Exception as e:
        return [], str(e)


def ollama_tags():
    """Return count of available (downloaded) models."""
    try:
        with urlopen(f"{OLLAMA_URL}/api/tags", timeout=3) as r:
            return len(json.loads(r.read()).get("models", [])), None
    except Exception as e:
        return 0, str(e)


def gpu_status():
    """Return list of GPU dicts from nvidia-smi, or error string."""
    try:
        result = subprocess.run(
            [
                "nvidia-smi",
                "--query-gpu=name,memory.used,memory.free,memory.total,utilization.gpu",
                "--format=csv,noheader,nounits",
            ],
            capture_output=True, text=True, timeout=5,
        )
        gpus = []
        for line in result.stdout.strip().splitlines():
            parts = [p.strip() for p in line.split(",")]
            if len(parts) >= 5:
                name, used, free, total, util = parts[:5]
                gpus.append({
                    "name": name,
                    "used": int(used),
                    "free": int(free),
                    "total": int(total),
                    "util": int(util),
                })
        return gpus, None
    except FileNotFoundError:
        return [], "nvidia-smi not found"
    except Exception as e:
        return [], str(e)


def docker_container_status(name):
    """Return container state string (running / exited / not found)."""
    try:
        r = subprocess.run(
            ["docker", "inspect", "--format={{.State.Status}}", name],
            capture_output=True, text=True, timeout=5,
        )
        state = r.stdout.strip()
        return state if state else "not found"
    except FileNotFoundError:
        return "docker not found"
    except Exception as e:
        return f"error: {e}"

def systemd_service_status(name):
    """Return systemd active state (active / inactive / failed / unknown)."""
    try:
        r = subprocess.run(
            ["systemctl", "is-active", name],
            capture_output=True, text=True, timeout=5,
        )
        return r.stdout.strip()
    except Exception:
        return "unknown"


# --------------------------------------------------------------------------- #
# HTML rendering
# --------------------------------------------------------------------------- #

def _badge(ok, label_ok="running", label_fail=None):
    cls = "ok" if ok else "fail"
    label = label_ok if ok else (label_fail or "down")
    return f'<span class="badge {cls}">{label}</span>'


def _bytes_to_gib(b):
    return f"{b / 1024:.1f} GiB"


def render_html(models, ollama_err, n_available, gpus, gpu_err, oh_state, kb_state, ws_state, sx_state):
    now = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    ollama_ok = ollama_err is None
    gpu_ok = bool(gpus) and gpu_err is None
    oh_ok = oh_state == "running"
    kb_ok = kb_state == "active"
    ws_ok = ws_state == "active"
    sx_ok = sx_state == "running"

    # --- GPU section ---
    if gpu_err and not gpus:
        gpu_html = f'<div class="dim err">{gpu_err}</div>'
    else:
        gpu_html = ""
        for g in gpus:
            pct = g["used"] / g["total"] * 100 if g["total"] else 0
            bar_cls = "bar-warn" if pct > 85 else "bar-ok"
            gpu_html += f"""
          <div class="gpu-row">
            <div class="label">{g['name']}</div>
            <div class="bar-wrap"><div class="bar {bar_cls}" style="width:{pct:.0f}%"></div></div>
            <div class="dim" style="font-size:0.8rem;margin-top:4px">
              {g['used']:,} / {g['total']:,} MiB used &nbsp;·&nbsp; {g['util']}% compute
            </div>
          </div>"""

    # --- Loaded models section ---
    if ollama_err:
        models_html = f'<div class="dim err">Ollama unreachable: {ollama_err}</div>'
    elif not models:
        models_html = '<div class="dim">No models loaded — idle (loads on next request)</div>'
    else:
        rows = ""
        for m in models:
            name = m.get("name", "?")
            vram = _bytes_to_gib(m.get("size_vram", 0))
            expires = m.get("expires_at", "")
            exp_str = expires[:19].replace("T", " ") if expires else "—"
            rows += f"<tr><td>{name}</td><td>{vram}</td><td>{exp_str}</td></tr>"
        models_html = f"""
        <table>
          <tr><th>Model</th><th>VRAM</th><th>Keep-alive until</th></tr>
          {rows}
        </table>"""

    return f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Lab LLM Status</title>
<style>
  :root {{
    --green:#2da44e; --red:#cf222e; --yellow:#bf8700;
    --bg:#0d1117; --card:#161b22; --border:#30363d;
    --text:#e6edf3; --dim:#8b949e;
  }}
  * {{ box-sizing:border-box; margin:0; padding:0 }}
  body {{ background:var(--bg); color:var(--text); font:14px/1.6 system-ui,sans-serif; padding:24px }}
  h1 {{ font-size:1.3rem; margin-bottom:4px }}
  .ts {{ color:var(--dim); font-size:0.8rem; margin-bottom:20px }}
  .grid {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:16px }}
  .card {{ background:var(--card); border:1px solid var(--border); border-radius:8px; padding:16px }}
  .card h2 {{ font-size:0.95rem; margin-bottom:12px; display:flex; align-items:center; gap:8px }}
  .badge {{ padding:2px 8px; border-radius:12px; font-size:0.75rem; font-weight:600 }}
  .badge.ok  {{ background:#1a3a26; color:var(--green) }}
  .badge.fail {{ background:#3a1a1a; color:var(--red) }}
  table {{ width:100%; border-collapse:collapse; font-size:0.85rem }}
  th {{ color:var(--dim); font-weight:500; text-align:left; padding:4px 0; border-bottom:1px solid var(--border) }}
  td {{ padding:5px 0; border-bottom:1px solid #21262d }}
  tr:last-child td {{ border-bottom:none }}
  .gpu-row {{ margin-bottom:12px }}
  .label {{ font-size:0.85rem; color:var(--dim); margin-bottom:4px }}
  .bar-wrap {{ background:#21262d; border-radius:4px; height:10px; overflow:hidden }}
  .bar {{ height:100%; border-radius:4px; transition:width 0.4s }}
  .bar-ok   {{ background:var(--green) }}
  .bar-warn {{ background:var(--yellow) }}
  .svc-list {{ list-style:none }}
  .svc-list li {{ display:flex; justify-content:space-between; align-items:center;
                   padding:6px 0; border-bottom:1px solid #21262d; font-size:0.85rem }}
  .svc-list li:last-child {{ border-bottom:none }}
  .links a {{ display:block; padding:5px 0; color:#58a6ff; font-size:0.85rem;
              border-bottom:1px solid #21262d; text-decoration:none }}
  .links a:last-child {{ border-bottom:none }}
  .links a:hover {{ text-decoration:underline }}
  .dim {{ color:var(--dim) }}
  .err {{ color:var(--red) }}
  footer {{ color:var(--dim); font-size:0.75rem; margin-top:20px; text-align:right }}
</style>
<script>setTimeout(() => location.reload(), 10000);</script>
</head>
<body>
<h1>Lab LLM Status</h1>
<div class="ts">Updated {now} &nbsp;·&nbsp; refreshes every 10 s</div>

<div class="grid">

  <div class="card">
    <h2>GPU {_badge(gpu_ok, "online", "unavailable")}</h2>
    {gpu_html or '<div class="dim">No GPU data</div>'}
  </div>

  <div class="card">
    <h2>Ollama {_badge(ollama_ok, "running", "unreachable")}</h2>
    <div class="dim" style="font-size:0.8rem;margin-bottom:10px">
      {n_available} models available &nbsp;·&nbsp; {len(models)} loaded in VRAM
    </div>
    {models_html}
  </div>

  <div class="card">
    <h2>Services</h2>
    <ul class="svc-list">
      <li><span>Ollama &nbsp;<span class="dim">:11434</span></span>  {_badge(ollama_ok)}</li>
      <li><span>OpenHands &nbsp;<span class="dim">:3000</span></span> {_badge(oh_ok, "running", oh_state)}</li>
      <li><span>Lab Knowledge &nbsp;<span class="dim">:3001</span></span> {_badge(kb_ok, "active", kb_state)}</li>
      <li><span>Web Search MCP &nbsp;<span class="dim">:3003</span></span> {_badge(ws_ok, "active", ws_state)}</li>
      <li><span>SearXNG &nbsp;<span class="dim">:8080 (internal)</span></span> {_badge(sx_ok, "running", sx_state)}</li>
    </ul>
  </div>

  <div class="card links">
    <h2>Quick links</h2>
    <a href="http://aleatico2.imago7.local:11434/api/tags" target="_blank">Ollama — available models (:11434/api/tags)</a>
    <a href="http://aleatico2.imago7.local:11434/api/ps"   target="_blank">Ollama — loaded models (:11434/api/ps)</a>
    <a href="http://aleatico2.imago7.local:3000"           target="_blank">OpenHands background agent (:3000)</a>
    <a href="http://aleatico2.imago7.local:3001/sse"       target="_blank">Lab Knowledge MCP (:3001/sse)</a>
  </div>

</div>
<footer>
  Status page: <a style="color:#58a6ff" href="http://aleatico2.imago7.local:3002">aleatico2.imago7.local:3002</a>
</footer>
</body>
</html>"""


# --------------------------------------------------------------------------- #
# HTTP server
# --------------------------------------------------------------------------- #

class StatusHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        pass  # suppress per-request access log noise

    def do_GET(self):
        if self.path not in ("/", "/status"):
            self.send_response(404)
            self.end_headers()
            return

        models, ollama_err = ollama_ps()
        n_available, _ = ollama_tags()
        gpus, gpu_err = gpu_status()
        oh_state = docker_container_status("openhands")
        sx_state = docker_container_status("searxng")
        kb_state = systemd_service_status("lab-knowledge")
        ws_state = systemd_service_status("lab-websearch")

        html = render_html(models, ollama_err, n_available, gpus, gpu_err, oh_state, kb_state, ws_state, sx_state)
        body = html.encode()

        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


if __name__ == "__main__":
    server = HTTPServer(("0.0.0.0", PORT), StatusHandler)
    print(f"Lab status server listening on http://0.0.0.0:{PORT}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("Stopped.")
