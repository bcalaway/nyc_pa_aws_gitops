"""Project context for voice Claude: the repo's own docs, read-only.

Source of truth is Git (ADR-0021's "Project context"): CLAUDE.md and
docs/**/*.md on `main`, fetched from GitHub (the repo is public, so no
token) and cached for CACHE_SECONDS -- a merged doc change shows up here
within minutes, no home-mcp redeploy. Unpushed local edits are invisible
by design.

Docs are chunked by markdown heading; very long sections (docs/gotchas.md's
areas) are further split per top-level bullet so a search hit is one
gotcha, not a whole area. Search is plain BM25 over those chunks -- a
semantic (pgvector) index is a planned later RAG project, not needed here.
"""

import asyncio
import math
import os
import re
import time
from dataclasses import dataclass

import httpx

REPO = os.environ.get("CONTEXT_REPO", "bcalaway/nyc_pa_aws_gitops")
BRANCH = os.environ.get("CONTEXT_BRANCH", "main")
LOCAL_DIR = os.environ.get("CONTEXT_LOCAL_DIR")  # tests: read a checkout instead of GitHub
CACHE_SECONDS = 600
MAX_CHUNK = 2500
MAX_REPLY = 6000

# Short names voice can say, mapped to paths. ADRs are matched by number.
ALIASES = {
    "roadmap": "docs/roadmap.md",
    "archive": "docs/roadmap-archive.md",
    "roadmap archive": "docs/roadmap-archive.md",
    "gotchas": "docs/gotchas.md",
    "ssm": "docs/ssm-parameters.md",
    "secrets": "docs/ssm-parameters.md",
    "reference": "docs/platform-reference.md",
    "platform reference": "docs/platform-reference.md",
    "topology": "docs/platform-reference.md",
    "network": "docs/network-inventory.md",
    "network inventory": "docs/network-inventory.md",
    "hardware": "docs/hardware-inventory.md",
    "ip plan": "docs/ip-plan.md",
    "app platform": "docs/app-platform.md",
    "new machine": "docs/new-machine-setup.md",
    "setup": "docs/new-machine-setup.md",
    "claude": "CLAUDE.md",
    "rules": "CLAUDE.md",
}


@dataclass
class Chunk:
    path: str
    heading: str
    text: str
    tokens: list[str]


_cache: dict = {"at": 0.0, "docs": {}, "chunks": []}
_lock = asyncio.Lock()
_WORD = re.compile(r"[a-z0-9][a-z0-9_.-]*")


def _tokenize(s: str) -> list[str]:
    return [w.strip(".-") for w in _WORD.findall(s.lower()) if len(w.strip(".-")) > 1]


def _chunk(path: str, text: str) -> list[Chunk]:
    out: list[Chunk] = []
    trail: list[tuple[int, str]] = []  # (level, heading) stack
    buf: list[str] = []

    def flush():
        body = "\n".join(buf).strip()
        if not body:
            return
        # The doc's own title (a lone level-1 heading) repeats on every chunk
        # -- drop it from the breadcrumb, the path already names the doc.
        names = [h for lvl, h in trail if lvl > 1] or [h for _, h in trail]
        heading = " > ".join(names) or path
        pieces = [body]
        if len(body) > MAX_CHUNK:
            pieces = [p.strip() for p in re.split(r"(?m)^(?=- )", body) if p.strip()]
        for p in pieces:
            out.append(Chunk(path, heading, p, _tokenize(heading + " " + p)))

    for line in text.split("\n"):
        m = re.match(r"^(#{1,4})\s+(.*)", line)
        if m:
            flush()
            buf = []
            level = len(m.group(1))
            # Pop to the parent level, so a skipped level (## then ####, or
            # # then ###) can't leave a sibling in the breadcrumb.
            while trail and trail[-1][0] >= level:
                trail.pop()
            trail.append((level, m.group(2).strip()))
        else:
            buf.append(line)
    flush()
    return out


async def _load() -> tuple[dict[str, str], list[Chunk]]:
    async with _lock:
        if time.time() - _cache["at"] < CACHE_SECONDS and _cache["docs"]:
            return _cache["docs"], _cache["chunks"]
        docs: dict[str, str] = {}
        if LOCAL_DIR:
            from pathlib import Path

            base = Path(LOCAL_DIR)
            for p in [base / "CLAUDE.md", *sorted((base / "docs").rglob("*.md"))]:
                docs[p.relative_to(base).as_posix()] = p.read_text(encoding="utf-8")
        else:
            async with httpx.AsyncClient(timeout=10) as client:
                tree = await client.get(f"https://api.github.com/repos/{REPO}/git/trees/{BRANCH}?recursive=1")
                tree.raise_for_status()
                paths = [
                    e["path"]
                    for e in tree.json()["tree"]
                    if e["type"] == "blob" and (e["path"] == "CLAUDE.md" or (e["path"].startswith("docs/") and e["path"].endswith(".md")))
                ]
                raw = f"https://raw.githubusercontent.com/{REPO}/{BRANCH}/"
                bodies = await asyncio.gather(*(client.get(raw + p) for p in paths))
                docs = {p: r.text for p, r in zip(paths, bodies) if r.status_code == 200}
        chunks = [c for path, text in docs.items() for c in _chunk(path, text.replace("\r\n", "\n"))]
        _cache.update(at=time.time(), docs=docs, chunks=chunks)
        return docs, chunks


def _resolve(docs: dict[str, str], name: str) -> str | None:
    n = name.strip().lower().removesuffix(".md")
    if n in ALIASES and ALIASES[n] in docs:
        return ALIASES[n]
    adr = re.search(r"adr[\s-]*0*(\d+)", n)
    if adr:
        num = int(adr.group(1))
        return next((p for p in docs if re.match(rf"docs/adr/0*{num}-", p)), None)
    return next((p for p in docs if n in p.lower()), None)


def _bm25(chunks: list[Chunk], query: str) -> list[tuple[float, Chunk]]:
    q = _tokenize(query)
    if not q or not chunks:
        return []
    n = len(chunks)
    avg = sum(len(c.tokens) for c in chunks) / n
    df = {t: sum(1 for c in chunks if t in c.tokens) for t in set(q)}
    scored = []
    for c in chunks:
        s = 0.0
        for t in q:
            tf = c.tokens.count(t)
            if not tf:
                continue
            idf = math.log(1 + (n - df[t] + 0.5) / (df[t] + 0.5))
            s += idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * len(c.tokens) / avg))
        if s:
            scored.append((s, c))
    return sorted(scored, key=lambda x: -x[0])


async def search_context(query: str, limit: int = 3) -> str:
    _, chunks = await _load()
    hits = _bm25(chunks, query)[: max(1, min(limit, 5))]
    if not hits:
        return f"Nothing in the project docs matches {query!r}."
    per = MAX_REPLY // len(hits)
    parts = [f"[{c.path} > {c.heading}]\n{c.text[:per]}" for _, c in hits]
    return "\n\n---\n\n".join(parts)


async def get_context(doc: str = "", section: str = "") -> str:
    docs, chunks = await _load()
    if not doc:
        names = sorted(set(ALIASES) - {"secrets", "topology", "rules", "setup", "roadmap archive", "platform reference", "network inventory"})
        adrs = sorted(p.split("/")[-1].removesuffix(".md") for p in docs if p.startswith("docs/adr/"))
        return "Docs: " + ", ".join(names) + ". ADRs: " + ", ".join(adrs) + "."
    path = _resolve(docs, doc)
    if not path:
        return f"No doc called {doc!r}. Call get_context with no arguments for the list."
    mine = [c for c in chunks if c.path == path]
    if section:
        want = section.lower()
        match = [c for c in mine if want in c.heading.lower()] or [s for _, s in _bm25(mine, section)[:2]]
        if not match:
            return f"No section like {section!r} in {path}."
        text = "\n\n".join(c.text for c in match)
        return f"[{path} > {match[0].heading}]\n{text[:MAX_REPLY]}"
    full = docs[path]
    if len(full) <= MAX_REPLY:
        return f"[{path}]\n{full}"
    headings = []
    for c in mine:
        if c.heading not in headings:
            headings.append(c.heading)
    return (
        f"[{path}] is long ({len(full) // 1000} KB); ask for a section. Sections: "
        + "; ".join(headings[:60])
        + f"\n\nStart of doc:\n{full[:2000]}"
    )
