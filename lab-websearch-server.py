#!/usr/bin/env python3
"""lab-websearch-server.py — Web search MCP server for the lab LLM stack

Wraps the lab's SearXNG instance and exposes a search_web tool
over HTTP/SSE on port 3003. Roo Code and OpenHands call this tool
automatically when they need current information from the internet.

Access (MCP SSE endpoint):
    http://aleatico2.imago7.local:3003/sse

Requires:
    - SearXNG running on 127.0.0.1:8080 (see searxng-compose.yml)
    - Internet access on aleatico2

NOTE: The lab firewall sometimes drops the internet connection and
requires re-authentication. If web search fails with a connectivity
error, the admin needs to re-authenticate the server on the network.
Until then, only local knowledge (codebase MCP + lab-knowledge MCP)
will be available.

Dependencies (already in /opt/conda/envs/lab-mcp):
    mcp[cli]
"""

import json
import sys
from urllib.error import URLError
from urllib.parse import urlencode
from urllib.request import urlopen

from mcp.server.fastmcp import FastMCP

SEARXNG_URL = "http://127.0.0.1:8080"
mcp = FastMCP("lab-web-search")
import argparse

DEFAULT_PORT = 3003

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=DEFAULT_PORT)
    args = parser.parse_args()
    import fastmcp
    print(f"[lab-websearch] fastmcp version: {getattr(fastmcp, '__version__', 'unknown')}")
    mcp = FastMCP("lab-web-search")
    print(f"Lab web search MCP server listening on http://0.0.0.0:{args.port}/", flush=True)
    try:
        mcp.run(transport="http", host="0.0.0.0", port=args.port)
    except Exception as e:
        print(f"[lab-websearch] fastmcp version: {getattr(fastmcp, '__version__', 'unknown')}")
        print(f"[lab-websearch] MCP server failed to start: {e}")
        raise


if __name__ == "__main__":
    main()


@mcp.tool()
def search_web(query: str, n_results: int = 5) -> str:
    """Search the web for current information not available in local sources.

    Use this tool when you need:
    - Documentation or API references not in the local knowledge base
    - Error messages, Stack Overflow answers, or GitHub issues
    - Recent papers or preprints (searches arxiv, Semantic Scholar)
    - Package versions, changelogs, or release notes
    - Any information that may have changed since the model's training cutoff

    NOTE: Requires the lab server to have active internet access. If the firewall
    session on aleatico2 has expired, this tool will return a connectivity error.
    Any user can re-authenticate the network connection — no admin needed.
    Once reconnected, simply call this tool again; no service restart required.
    Local tools (search_codebase, search_knowledge) always work regardless.

    Args:
        query:     Search query. Be specific — include package names, error text,
                   or paper titles for best results.
        n_results: Number of results to return (1–10, default 5).

    Returns:
        Numbered list of results with title, URL, and snippet.
    """
    n_results = max(1, min(10, n_results))
    params = urlencode({"q": query, "format": "json", "pageno": 1})
    url = f"{SEARXNG_URL}/search?{params}"

    try:
        with urlopen(url, timeout=15) as resp:
            data = json.loads(resp.read())
    except URLError as e:
        reason = str(e)
        if "Connection refused" in reason or "[Errno 111]" in reason:
            return (
                "ERROR: SearXNG is not running on this server.\n"
                "Admin fix: docker compose -f ~/lab-llm-server/searxng-compose.yml up -d"
            )
        return (
            f"ERROR: Web search unavailable — the server may have lost internet access.\n"
            f"Any user can re-authenticate the network connection (no admin needed).\n"
            f"Once reconnected, try calling search_web again — no service restart needed.\n"
            f"Local tools (search_codebase, search_knowledge) still work.\n"
            f"Details: {e}"
        )
    except Exception as e:
        return f"ERROR: Search failed unexpectedly: {e}"

    results = data.get("results", [])[:n_results]
    if not results:
        return f"No results found for: {query}"

    lines = [f"Web search results for: **{query}**\n"]
    for i, r in enumerate(results, 1):
        title   = r.get("title", "No title")
        url_r   = r.get("url", "")
        snippet = (r.get("content") or "").strip() or "No description available."
        lines.append(f"{i}. **{title}**\n   {url_r}\n   {snippet}\n")

    return "\n".join(lines)


if __name__ == "__main__":
    print(f"Lab web search MCP server listening on http://0.0.0.0:8000/sse", flush=True)
    mcp.run(transport="sse")
