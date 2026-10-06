"""mkt_data_* tools: the market data platform's raw captures, checks, calendars and yields.

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
import re
from datetime import date, datetime
from decimal import Decimal
from zoneinfo import ZoneInfo

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


# --- Yields, from mkt-api (phase 2, B10) ---
#
# mkt-api is the market data platform's gateway (bcalaway/mkt-api): golden
# yields from quote-svc with short names from secmaster-svc, values as exact
# decimal strings in percent. It's internal, with no login of its own (mkt-ui's
# server calls it the same way), so these tools need no token: home-mcp reaches
# it on the home-platform network as mkt-api:8000 (Bill, 2026-10-06).

MKT_API_URL = os.environ.get("MKT_API_URL", "http://mkt-api:8000")
SOURCE_SAID = {"UST-PAR": "Treasury's par curve", "H15-TCM": "the Fed's H.15"}
_TENOR = re.compile(r"^(?:UST-)?(\d+(?:\.\d+)?)\s*-?\s*(Y|YR|YRS|YEAR|YEARS|M|MO|MOS|MONTH|MONTHS|W|WK|WEEK|WEEKS)(?:-CMT)?$")


def instrument_name(tenor: str) -> str:
    """"10Y", "10-year", "10 year", "3 month", "6W", "UST-10Y-CMT" -> a short name mkt-api knows."""
    t = tenor.strip().upper().replace("_", "-")
    m = _TENOR.match(t)
    if not m:
        return t  # mkt-api answers with what it knows, or that it doesn't
    unit = {"Y": "Y", "M": "M", "W": "W"}[m.group(2)[0]]
    return f"UST-{m.group(1)}{unit}-CMT"


def short_tenor(name: str) -> str:
    return name.removeprefix("UST-").removesuffix("-CMT")


async def _api(path: str, params: dict | list) -> tuple[int, dict | str]:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{MKT_API_URL}{path}", params=params, timeout=TIMEOUT_SECONDS)
    except httpx.HTTPError as exc:
        return 0, f"I couldn't reach mkt-api ({type(exc).__name__})."
    try:
        body = r.json()
    except ValueError:
        body = {}
    if r.status_code != 200:
        detail = body.get("detail") if isinstance(body, dict) else None
        return r.status_code, f"mkt-api answered {r.status_code}: {detail or r.text[:200]}"
    return 200, body


def _today_ny() -> date:
    return datetime.now(ZoneInfo("America/New_York")).date()


def _day(on: str) -> date | str:
    if not on.strip():
        return _today_ny()
    try:
        return date.fromisoformat(on.strip())
    except ValueError:
        return f"I need the date as YYYY-MM-DD, not {on!r}."


def _bp(now: str, then: str) -> str:
    bp = ((Decimal(now) - Decimal(then)) * 100).normalize()  # percent to basis points
    if bp == 0:
        return "unchanged"
    return f"{'up' if bp > 0 else 'down'} {format(abs(bp), 'f')} bp"


async def mkt_data_yield(tenor: str, on: str = "") -> str:
    day = _day(on)
    if isinstance(day, str):
        return day
    name = instrument_name(tenor)
    # The day's bars from /api/bars (a block is a calendar year): the last value on or before the day and
    # the one before it, reaching into the previous year early in January.
    points: list[dict] = []
    for year in (day.year, day.year - 1):
        status, body = await _api("/api/bars", {"series": name, "interval": "day", "block": f"{year:04d}"})
        if status == 404:
            return f"There's no instrument {name}. Try a tenor like 10Y, 2Y or 3M."
        if status != 200:
            return body
        series = body["series"][0]
        name = series["key"]
        points = [b for b in series["bars"] if b["date"] <= day.isoformat()] + points
        if len(points) >= 2:
            break
    if not points:
        return f"{short_tenor(name)} has no yield on or before {day}."
    last = points[-1]
    text = f"{short_tenor(name)} ({name}) on {last['date']}: {last['close']}%, from {SOURCE_SAID.get(last['source'], last['source'])}"
    if len(points) > 1:
        prev = points[-2]
        text += f"; {_bp(last['close'], prev['close'])} from {prev['close']}% on {prev['date']}"
    text += "."
    if last["date"] != day.isoformat():
        text += f" ({day} has no value: the latest on or before it is shown.)"
    return text


async def mkt_data_curve(on: str = "", compare: str = "") -> str:
    day = _day(on)
    if isinstance(day, str):
        return day
    params: list = [("date", day.isoformat())] if on.strip() else []
    if compare.strip():
        params.append(("compare", compare.strip().upper()))
    status, body = await _api("/api/curve", params)
    if status != 200:
        return body
    base, *others = body["curves"]
    if not base["date"]:
        return f"No Treasury curve on or in the ten days before {base['requested']}."
    then = {c["label"]: {p["name"]: p for p in c["points"]} for c in others if c["date"]}
    head = f"Treasury CMT curve on {base['date']}"
    if base["date"] != base["requested"] and on.strip():
        head += f" (the last business day on or before {base['requested']})"
    if others:
        head += "; changes from " + ", ".join(f"{c['label']} earlier ({c['date'] or 'no curve'})" for c in others)
    lines = [head + ":"]
    for p in base["points"]:
        line = f"- {short_tenor(p['name'])}: {p['percent']}%"
        changes = [f"{_bp(p['percent'], prev['percent'])} vs {label}" for label, pts in then.items()
                   if (prev := pts.get(p["name"]))]
        if changes:
            line += f" ({', '.join(changes)})"
        lines.append(line)
    sources = {SOURCE_SAID.get(p["source"], p["source"]) for p in base["points"]}
    lines.append(f"From {' and '.join(sorted(sources))}.")
    if base["missing"]:
        lines.append(f"No value that day for {', '.join(short_tenor(n) for n in base['missing'])}.")
    return "\n".join(lines)
