"""mkt_data_* tools: the market data platform's raw captures, checks and calendars.

mkt-data (bcalaway/mkt-data) keeps every page it fetches byte for byte. These
tools read them through its job API's GET endpoints with a read-only token
(/home-platform/mkt-data/read-token, MKT_DATA_READ_TOKEN here), which can't
start captures or reparses. mkt-data is internal: home-mcp reaches it on the
home-platform network as mkt-data:8000.

Uses: "did the SIFMA capture parse?", "what does NYSE's page say about early
closes now?", and checking a parser against a page's real wording.

mkt_data_business_day answers from calendar-svc (bcalaway/calendar-svc), which
owns the golden calendars since phase 2 (mkt-data's docs/phase-2.md, step A5),
with its own read-only token (/home-platform/calendar-svc/read-token,
CALENDAR_SVC_READ_TOKEN here). The tool keeps its name so the claude.ai
connector needn't be reconnected. For a byte-exact copy (a test fixture), mkt-data's
capture-export workflow is the route; these tools return text.
"""

import os

import httpx

MKT_DATA_URL = os.environ.get("MKT_DATA_URL", "http://mkt-data:8000")
TOKEN = os.environ.get("MKT_DATA_READ_TOKEN", "")
CALENDAR_SVC_URL = os.environ.get("CALENDAR_SVC_URL", "http://calendar-svc:8000")
CALENDAR_TOKEN = os.environ.get("CALENDAR_SVC_READ_TOKEN", "")
TIMEOUT_SECONDS = 20
MAX_LINES = 120
MAX_LINE_CHARS = 300


def _ready() -> str | None:
    if not TOKEN or TOKEN == "none":
        return "The market data read token isn't set up yet (MKT_DATA_READ_TOKEN)."
    return None


async def _get(path: str, params: dict, base: str = "", token: str = "", app: str = "mkt-data") -> tuple[int, dict | str]:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{base or MKT_DATA_URL}/jobs/{path}",
                params=params,
                headers={"Authorization": f"Bearer {token or TOKEN}"},
                timeout=TIMEOUT_SECONDS,
            )
    except httpx.HTTPError as exc:
        return 0, f"I couldn't reach {app} ({type(exc).__name__})."
    try:
        body = r.json()
    except ValueError:
        body = {}
    if r.status_code != 200:
        detail = body.get("detail") if isinstance(body, dict) else None
        return r.status_code, f"{app} answered {r.status_code}: {detail or r.text[:200]}"
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
        if c.get("parsed", True) is False:
            state = "kept raw (no parser for this source yet)"
        else:
            state = "applied" if c["applied"] else "NOT applied (parse failed, or since replaced)"
        lines.append(
            f"- #{c['id']} {c['source']}, fetched {c['fetched_at'][:16].replace('T', ' ')} UTC, "
            f"{_kb(c['size_bytes'])}, {state}"
        )
    head = f"{len(caps)} capture{'s' if len(caps) != 1 else ''}, newest first:"
    return "\n".join([head, *lines])


async def mkt_data_capture_text(
    capture_id: int, contains: str = "", context: int = 0, lines: int = 40, embedded: bool = False
) -> str:
    if msg := _ready():
        return msg
    params = {"limit": max(1, min(lines, MAX_LINES)), "context": max(0, min(context, 10))}
    if contains.strip():
        params["contains"] = contains.strip()
    if embedded:
        params["embedded"] = "true"
    status, body = await _get(f"captures/{int(capture_id)}/text", params)
    if status != 200:
        return body
    shown = body["lines"]
    view = " embedded data" if body.get("view") == "embedded" else ""
    if contains.strip():
        head = (
            f"Capture #{body['capture_id']} ({body['source']}{view}): {body['matches']} of "
            f"{body['lines_total']} lines contain {contains.strip()!r}."
        )
    else:
        head = f"Capture #{body['capture_id']} ({body['source']}{view}): {body['lines_total']} lines."
    out = [head]
    out += [f"{ln['n']}: {ln['text'][:MAX_LINE_CHARS]}" for ln in shown]
    if body["truncated"]:
        out.append(f"(First {len(shown)} shown; narrow with contains, or raise lines up to {MAX_LINES}.)")
    return "\n".join(out)


async def mkt_data_business_day(calendar: str, on: str) -> str:
    if not CALENDAR_TOKEN or CALENDAR_TOKEN == "none":
        return "The calendar service's read token isn't set up yet (CALENDAR_SVC_READ_TOKEN)."
    status, body = await _get(
        f"calendars/{calendar.strip()}/business-day", {"on": on.strip()},
        base=CALENDAR_SVC_URL, token=CALENDAR_TOKEN, app="calendar-svc",
    )
    if status == 409:
        return f"{calendar} doesn't cover that year: {body.split(': ', 1)[-1]}"
    if status != 200:
        return body
    day = f"{body['calendar']} on {body['date']}: "
    if body["status"] == "weekend":
        return day + "a weekend."
    if body["status"] == "open":
        text = day + "open, a normal business day."
    elif body["status"] == "early_close":
        text = day + f"open but closing early at {body.get('close_time')} ({body.get('holiday')})."
    else:
        text = day + f"closed ({body.get('holiday')})."
    if body.get("projected"):
        text += " Projected from the rules: no publisher covers that year yet."
    return text


async def mkt_data_checks(calendar: str = "", source: str = "", limit: int = 10) -> str:
    if msg := _ready():
        return msg
    params: dict = {"limit": max(1, min(limit, 50))}
    if source.strip():
        params["source"] = source.strip()
    elif calendar.strip():
        params["calendar"] = calendar.strip()
    status, body = await _get("checks", params)
    if status != 200:
        return body
    checks = body["checks"]
    if not checks:
        return "No checks yet."
    lines = [f"{len(checks)} check{'s' if len(checks) != 1 else ''}, newest first:"]
    for c in checks:
        parse = {"ok": ", parsed OK", "error": ", PARSE FAILED"}.get(c.get("parse_outcome"), "")
        cap = f" capture #{c['capture_id']}" if c.get("capture_id") else ""
        note = c.get("parse_detail") if c.get("parse_outcome") == "error" else c.get("detail")
        lines.append(
            f"- {c['checked_at'][:16].replace('T', ' ')} UTC {c['source']}: {c['outcome']}{cap}{parse}"
            + (f" ({note[:200]})" if note else "")
        )
    return "\n".join(lines)
