"""mkt_data_captures and mkt_data_capture_text: the market data platform's raw captures.

mkt-data (bcalaway/mkt-data) keeps every page it fetches byte for byte. These
tools read them through its job API's GET endpoints with a read-only token
(/home-platform/mkt-data/read-token, MKT_DATA_READ_TOKEN here), which can't
start captures or reparses. mkt-data is internal: home-mcp reaches it on the
home-platform network as mkt-data:8000.

Uses: "did the SIFMA capture parse?", "what does NYSE's page say about early
closes now?", and checking a parser against a page's real wording. For a
byte-exact copy (a test fixture) the README's docker exec one-liner is the
route; these tools return text.
"""

import os

import httpx

MKT_DATA_URL = os.environ.get("MKT_DATA_URL", "http://mkt-data:8000")
TOKEN = os.environ.get("MKT_DATA_READ_TOKEN", "")
TIMEOUT_SECONDS = 20
MAX_LINES = 120
MAX_LINE_CHARS = 300


def _ready() -> str | None:
    if not TOKEN or TOKEN == "none":
        return "The market data read token isn't set up yet (MKT_DATA_READ_TOKEN)."
    return None


async def _get(path: str, params: dict) -> tuple[int, dict | str]:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{MKT_DATA_URL}/jobs/{path}",
                params=params,
                headers={"Authorization": f"Bearer {TOKEN}"},
                timeout=TIMEOUT_SECONDS,
            )
    except httpx.HTTPError as exc:
        return 0, f"I couldn't reach mkt-data ({type(exc).__name__})."
    try:
        body = r.json()
    except ValueError:
        body = {}
    if r.status_code != 200:
        detail = body.get("detail") if isinstance(body, dict) else None
        return r.status_code, f"mkt-data answered {r.status_code}: {detail or r.text[:200]}"
    return 200, body


def _kb(n: int) -> str:
    return f"{n / 1024:.0f} KB" if n >= 1024 else f"{n} bytes"


async def mkt_data_captures(calendar: str = "", limit: int = 10) -> str:
    if msg := _ready():
        return msg
    params: dict = {"limit": max(1, min(limit, 50))}
    if calendar.strip():
        params["calendar"] = calendar.strip()
    status, body = await _get("captures", params)
    if status != 200:
        return body
    caps = body["captures"]
    if not caps:
        return f"No captures{' for ' + calendar if calendar else ''} yet."
    lines = []
    for c in caps:
        state = "applied" if c["applied"] else "NOT applied (parse failed, or since replaced)"
        lines.append(
            f"- #{c['id']} {c['source']}, fetched {c['fetched_at'][:16].replace('T', ' ')} UTC, "
            f"{_kb(c['size_bytes'])}, {state}"
        )
    head = f"{len(caps)} capture{'s' if len(caps) != 1 else ''}, newest first:"
    return "\n".join([head, *lines])


async def mkt_data_capture_text(capture_id: int, contains: str = "", context: int = 0, lines: int = 40) -> str:
    if msg := _ready():
        return msg
    params = {"limit": max(1, min(lines, MAX_LINES)), "context": max(0, min(context, 10))}
    if contains.strip():
        params["contains"] = contains.strip()
    status, body = await _get(f"captures/{int(capture_id)}/text", params)
    if status != 200:
        return body
    shown = body["lines"]
    if contains.strip():
        head = (
            f"Capture #{body['capture_id']} ({body['source']}): {body['matches']} of "
            f"{body['lines_total']} lines contain {contains.strip()!r}."
        )
    else:
        head = f"Capture #{body['capture_id']} ({body['source']}): {body['lines_total']} lines."
    out = [head]
    out += [f"{ln['n']}: {ln['text'][:MAX_LINE_CHARS]}" for ln in shown]
    if body["truncated"]:
        out.append(f"(First {len(shown)} shown; narrow with contains, or raise lines up to {MAX_LINES}.)")
    return "\n".join(out)
