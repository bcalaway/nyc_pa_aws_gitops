"""mkt_data_* tools: the market data platform's raw captures, checks, calendars, yields, Treasuries and auctions.

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
# decimal strings (decimals, each with a percent display form beside it). It's internal, with no login of its own (mkt-ui's
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


def _pct(x: dict, field: str) -> str:
    """A value's percent display from mkt-api: `display` for a curve point's value, `<field>_display` on a
    bar (values are decimals since mkt-api #11, 2026-10-06)."""
    return x["display"] if field == "value" else x[f"{field}_display"]


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
    now = _pct(last, "close")
    text = f"{short_tenor(name)} ({name}) on {last['date']}: {now}%, from {SOURCE_SAID.get(last['source'], last['source'])}"
    if len(points) > 1:
        prev = points[-2]
        then = _pct(prev, "close")
        text += f"; {_bp(now, then)} from {then}% on {prev['date']}"
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
        line = f"- {short_tenor(p['name'])}: {_pct(p, 'value')}%"
        changes = [f"{_bp(_pct(p, 'value'), _pct(prev, 'value'))} vs {label}" for label, pts in then.items()
                   if (prev := pts.get(p["name"]))]
        if changes:
            line += f" ({', '.join(changes)})"
        lines.append(line)
    sources = {SOURCE_SAID.get(p["source"], p["source"]) for p in base["points"]}
    lines.append(f"From {' and '.join(sorted(sources))}.")
    if base["missing"]:
        lines.append(f"No value that day for {', '.join(short_tenor(n) for n in base['missing'])}.")
    return "\n".join(lines)


# --- Treasury securities and auctions, from mkt-api (phase 3, step 10) ---
#
# The same gateway: securities by CUSIP from secmaster-svc with their latest
# price from quote-svc (/api/securities), and the auction calendar
# (/api/auctions).

_CUSIP = re.compile(r"^[0-9]{3}[0-9A-Z]{5}[0-9]$")
_OTR_WORDS = re.compile(r"\b(ON[\s-]*THE[\s-]*RUN|OTR|CURRENT|TREASURY|UST|NOTE|BOND)\b")
# Bills are auctioned in weeks; people say months.
BILL_WEEKS = {"1": "4", "2": "8", "3": "13", "4": "17", "6": "26", "12": "52"}
_FRACTION = re.compile(r"^(\d+)\s+(\d+)/(\d+)$")
_COUPON_YEAR = re.compile(r"^(\d+(?:\.\d+)?|\d+\s+\d+/\d+|\d+/\d+)\s*%?\s*S?\s*(?:OF\s+|DUE\s+)?'?(\d{4}|\d{2})$")
PRICE_SOURCE = {"TD-PRICES": "FedInvest"}


def otr_name(text: str) -> str | None:
    """"10Y", "10-year on the run", "10 year TIPS", "2Y FRN", "3 month bill", "13W" -> an on-the-run alias
    (UST-10Y-OTR, UST-10Y-TII-OTR, UST-2Y-FRN-OTR, UST-13W-OTR); None if it isn't a tenor."""
    t = text.strip().upper().replace("_", "-")
    suffix = ""
    if re.search(r"\b(TIPS|TII)\b", t):
        suffix = "-TII"
    elif re.search(r"\bFRNS?\b|FLOAT", t):
        suffix = "-FRN"
    bill = bool(re.search(r"\bBILLS?\b|T-BILL", t))
    t = re.sub(r"\b(TIPS|TII|FRNS?|FLOATERS?|FLOATING|RATE|BILLS?|T-BILL)\b", " ", t)
    t = _OTR_WORDS.sub(" ", t).replace("-OTR", " ")
    t = " ".join(t.replace("THE ", " ").split()).strip(" -")
    m = _TENOR.match(t)
    if not m:
        return None
    n, unit = m.group(1), m.group(2)[0]
    if unit == "M":
        if n not in BILL_WEEKS:
            return None
        n, unit = BILL_WEEKS[n], "W"
    elif unit == "Y" and n == "1" and not suffix:
        n, unit = "52", "W"  # "the 1-year bill"
    elif bill and unit == "Y":
        return None
    return f"UST-{n}{unit}{suffix}-OTR"


def coupon_year(text: str) -> tuple[Decimal, int] | None:
    """"4.25 2035", "4 1/4 2035", "4 1/4s of 35", "4.25% 2035" -> (Decimal('4.25'), 2035); None otherwise."""
    m = _COUPON_YEAR.match(" ".join(text.strip().upper().split()))
    if not m:
        return None
    c, y = m.group(1), m.group(2)
    if f := _FRACTION.match(c):
        coupon = Decimal(f.group(1)) + Decimal(f.group(2)) / Decimal(f.group(3))
    elif "/" in c:
        a, b = c.split("/")
        coupon = Decimal(a) / Decimal(b)
    else:
        coupon = Decimal(c)
    year = int(y) if len(y) == 4 else 2000 + int(y)
    return coupon.normalize(), year


def _percent(rate: str) -> str:
    """A rate as a decimal string ("0.0425") in percent ("4.25"); "" stays ""."""
    if not rate:
        return ""
    try:
        return format((Decimal(rate) * 100).normalize(), "f")
    except ArithmeticError:
        return rate


def _billions(dollars: str) -> str:
    if not dollars:
        return ""
    try:
        b = (Decimal(dollars) / Decimal(1_000_000_000)).quantize(Decimal("0.1")).normalize()
    except ArithmeticError:
        return f"${dollars}"
    return f"${format(b, 'f')} billion"


def _auction_result(a: dict) -> str:
    """A held auction's result in a few words, from a security's auction dict or an /api/auctions row."""
    parts = []
    if a.get("high_yield"):
        parts.append(f"high yield {_percent(a['high_yield'])}%")
    elif a.get("high_discount_rate"):
        parts.append(f"high discount rate {_percent(a['high_discount_rate'])}%")
    elif a.get("high_discount_margin"):
        parts.append(f"high discount margin {_percent(a['high_discount_margin'])}%")
    if a.get("bid_to_cover"):
        try:
            btc = format(Decimal(a["bid_to_cover"]).normalize(), "f")
        except ArithmeticError:
            btc = a["bid_to_cover"]
        parts.append(f"bid-to-cover {btc}")
    return ", ".join(parts)


async def _resolve_security(text: str) -> tuple[str | None, str]:
    """What the person said -> (a name mkt-api's /api/securities/{name} knows, ""), or (None, why not)."""
    t = text.strip()
    if not t:
        return None, "Which security? Say a CUSIP, a tenor like 10Y or 10Y TIPS, or a coupon and year like 4.25 2035."
    up = t.upper()
    if _CUSIP.match(up) or up.startswith("UST-"):
        return up, ""
    if name := otr_name(t):
        return name, ""
    if cy := coupon_year(t):
        coupon, year = cy
        status, body = await _api("/api/securities", {
            "maturing_from": f"{year}-01-01", "maturing_to": f"{year}-12-31", "include_inactive": "true",
            "limit": "6000"})
        if status != 200:
            return None, body
        hits = [r for r in body["securities"]
                if r.get("coupon_display") and Decimal(r["coupon_display"]) == coupon and r["type"] != "tips"]
        hits = hits or [r for r in body["securities"]
                        if r.get("coupon_display") and Decimal(r["coupon_display"]) == coupon]
        if not hits:
            return None, f"No Treasury with a {format(coupon, 'f')}% coupon matures in {year}."
        if len(hits) > 1:
            listed = "; ".join(f"{r['name']} (CUSIP {r['cusip']}, {r['type']})" for r in hits[:8])
            return None, (f"{len(hits)} Treasuries with a {format(coupon, 'f')}% coupon mature in {year}: "
                          f"{listed}. Which one?")
        return hits[0]["name"], ""
    return up, ""  # mkt-api answers with what it knows, or that it doesn't


async def mkt_data_security(security: str) -> str:
    name, why = await _resolve_security(security)
    if name is None:
        return why
    status, body = await _api(f"/api/securities/{name}", {})
    if status == 404:
        return (f"There's no Treasury security {name}. "
                "Try a CUSIP, a tenor like 10Y, or a coupon and year like 4.25 2035.")
    if status != 200:
        return body
    d = body
    terms = d.get("terms") or {}
    ids = {i["scheme"]: i["value"] for i in d.get("identifiers", []) if not i.get("valid_to")}
    head = f"{d['name']}"
    described = d.get("description") or d["type"]
    # secmaster-svc's descriptions of Treasuries already end with the CUSIP; say it once.
    if (cusip := ids.get("CUSIP") or terms.get("cusip")) and cusip not in described:
        head += f" (CUSIP {cusip})"
    lines = [f"{head}: {described}, {d['status']}."]
    dates = []
    if terms.get("issue_date"):
        dates.append(f"issued {terms['issue_date']}")
    if terms.get("maturity_date"):
        dates.append(f"matures {terms['maturity_date']}")
    if dates:
        lines.append(", ".join(dates).capitalize() + ".")
    current = [o for o in d.get("on_the_run", []) if not o.get("until") and not o["alias"].endswith("-ISSUED")]
    if current:
        lines.append(f"On the run as {', '.join(o['alias'] for o in current)} since {current[0]['since']}.")
    elif name.endswith("-OTR"):
        lines.append(f"(That's today's {name}.)")
    if p := d.get("price"):
        lines.append(f"Price {p['display']} per 100 on {p['date']}, from {PRICE_SOURCE.get(p['source'], p['source'])}.")
    if r := d.get("index_ratio"):
        ratio = r.get("ratio") or r.get("index_ratio")
        if ratio:
            lines.append(f"Index ratio today {ratio}.")
    auctions = d.get("auctions") or []
    if auctions:
        last = auctions[-1]
        text = f"{len(auctions)} auction{'s' if len(auctions) > 1 else ''}; the last on {last.get('auction_date', '?')}"
        if result := _auction_result(last):
            text += f": {result}"
        lines.append(text + ".")
    return " ".join(lines)


def _week(which: str) -> tuple[date, date] | str:
    w = which.strip().lower().removesuffix(" week").strip() or "this"
    shift = {"this": 0, "next": 1, "last": -1, "previous": -1}.get(w)
    if shift is None:
        return f"I need week as this, next or last, not {which!r}."
    today = _today_ny()
    monday = date.fromordinal(today.toordinal() - today.weekday() + 7 * shift)
    return monday, date.fromordinal(monday.toordinal() + 4)


async def mkt_data_auctions(week: str = "", start: str = "", end: str = "") -> str:
    if start.strip() or end.strip():
        lo = _day(start) if start.strip() else None
        hi = _day(end) if end.strip() else None
        for x in (lo, hi):
            if isinstance(x, str):
                return x
        lo = lo or hi
        hi = hi or lo
    else:
        span = _week(week)
        if isinstance(span, str):
            return span
        lo, hi = span
    status, body = await _api("/api/auctions", {"start": lo.isoformat(), "end": hi.isoformat()})
    if status != 200:
        return body
    rows = body["auctions"]
    when = f"{body['start']} to {body['end']}"
    if not rows:
        return f"No Treasury auctions from {when}."
    lines = [f"{len(rows)} Treasury auction{'s' if len(rows) > 1 else ''} from {when}:"]
    for a in rows:
        day = date.fromisoformat(a["auction_date"]).strftime("%a %b %-d") if a.get("auction_date") else "?"
        kind = {"bill": "bill", "note": "note", "bond": "bond", "tips": "TIPS", "frn": "FRN"}.get(a["type"], a["type"])
        line = f"- {day}: {a['term']} {kind}{' reopening' if a.get('reopening') else ''} ({a['security']})"
        if amount := _billions(a.get("offering_amount", "")):
            line += f", {amount}"
        if a.get("held"):
            line += f"; {_auction_result(a) or 'held'}"
        line += "."
        lines.append(line)
    return "\n".join(lines)


# --- Futures, baskets, positioning and fixings (mkt-data's docs/phase-4.md, step 7) ---

FUTURES_KIND = {"treasury": "deliverable Treasury", "treasury_cash": "cash-settled Treasury", "stir": "interest rate",
                "fx": "deliverable FX", "fx_cash": "cash-settled FX"}
# The TFF report's trader categories, as mkt-api's positioning fields name them.
POSITIONING = (("dealer", "Dealers"), ("asset_mgr", "Asset managers"), ("lev_funds", "Leveraged funds"),
               ("other", "Other reportables"), ("nonrept", "Nonreportable"))
POSITIONING_REPORT = {"futures": "CFTC-TFF", "combined": "CFTC-TFF-COMBINED"}


async def _futures_root(text: str) -> tuple[dict | None, str]:
    """A product by root (TY), CME code (ZN) or a word of its name ("ultra bond"), from mkt-api's list."""
    status, body = await _api("/api/futures", {})
    if status != 200:
        return None, body
    want = text.strip().upper()
    for p in body:
        if want in (p["root"].upper(), p["cme_code"].upper()):
            return p, ""
    named = [p for p in body if want and want in p["name"].upper()]
    if len(named) == 1:
        return named[0], ""
    if named:
        return None, f"{text!r} could be {', '.join(p['root'] for p in named)}. Which one?"
    return None, f"There's no futures product {text!r}. Try a root like TY or a CME code like ZN."


def _contracts(n: int) -> str:
    return f"{n:,} contract{'s' if n != 1 else ''}"


async def mkt_data_futures(product: str = "") -> str:
    if not product.strip():
        status, body = await _api("/api/futures", {})
        if status != 200:
            return body
        by: dict[str, list[str]] = {}
        for p in body:
            by.setdefault(p["kind"], []).append(f"{p['root']} ({p['front'] or p['status']})")
        lines = [f"{len(body)} futures products, with today's front contract:"]
        lines += [f"- {FUTURES_KIND.get(k, k)[:1].upper()}{FUTURES_KIND.get(k, k)[1:]}: {', '.join(v)}." for k, v in by.items()]
        return "\n".join(lines)
    p, why = await _futures_root(product)
    if p is None:
        return why
    status, d = await _api(f"/api/futures/{p['root']}", {})
    if status != 200:
        return d
    lines = [f"{d['root']} (CME {d['cme_code']}): {d['name']}, {FUTURES_KIND.get(d['kind'], d['kind'])}, in {d['currency']}."]
    if d["generics"]:
        lines.append("Generics today: " + ", ".join(f"{g['generic']} is {g['contract']}" for g in d["generics"][:3]) + ".")
    front = next((c for c in d["contracts"] if c["name"] == d["front"]), None)
    if front:
        dates = [(label, front[k]) for k, label in (("last_trade_date", "last trade"), ("first_notice_date", "first notice"),
                                                   ("final_settlement_date", "final settlement"),
                                                   ("last_delivery_date", "last delivery")) if front.get(k)]
        if dates:
            lines.append(f"{front['name']}: " + ", ".join(f"{label} {v}" for label, v in dates) + ".")
        if front.get("basket_size") is not None:
            lines.append(f"Its basket has {front['basket_size']} deliverable securities.")
    if not d["cftc_code"]:
        lines.append("The CFTC doesn't report its positioning.")
    return " ".join(lines)


async def mkt_data_basket(contract: str) -> str:
    name = contract.strip().upper()
    if not re.fullmatch(r"[A-Z0-9]{1,4}[FGHJKMNQUVXZ]\d{2}", name):  # a root, CME code or name: its front
        p, why = await _futures_root(contract)
        if p is None:
            return why
        if not p["front"]:
            return f"{p['root']} has no contract listed today."
        name = p["front"]
    status, b = await _api(f"/api/futures/contracts/{name}/basket", {})
    if status == 404:
        return f"There's no basket for {name}: only deliverable Treasury contracts have one."
    if status != 200:
        return b
    ds = b["deliverables"]
    if not ds:
        return f"{b['contract']} ({b['month']}) has no deliverable securities yet."
    many = f"{len(ds)} deliverable securit{'ies' if len(ds) > 1 else 'y'}"
    lines = [f"{b['contract']} ({b['month']}, {b['status']}): {many}, {b['rule']}."]
    shown = ds if len(ds) <= 6 else [ds[0], ds[-1]]
    for x in shown:
        lines.append(f"- {x['security']} (CUSIP {x['cusip']}): conversion factor {x['conversion_factor']}.")
    if len(ds) > 6:
        lines.insert(1, "The shortest and the longest:")
    return "\n".join(lines)


async def mkt_data_positioning(product: str, report: str = "futures") -> str:
    source = POSITIONING_REPORT.get(report.strip().lower() or "futures")
    if source is None:
        return f"I need report as futures or combined, not {report!r}."
    p, why = await _futures_root(product)
    if p is None:
        return why
    if not p["cftc_code"]:
        return f"The CFTC doesn't report positioning for {p['root']}."
    start = date.fromordinal(_today_ny().toordinal() - 35).isoformat()
    status, d = await _api(f"/api/futures/{p['root']}/positioning", {"source": source, "start": start})
    if status != 200:
        return d
    f = d["fields"]
    weeks = sorted({x["date"] for x in f.get("oi", [])})
    if not weeks:
        return f"No CFTC report for {p['root']} in the last five weeks."
    last, prior = weeks[-1], (weeks[-2] if len(weeks) > 1 else "")

    def on(field: str, day: str) -> Decimal | None:
        v = next((x["value"] for x in f.get(field, []) if x["date"] == day), None)
        return Decimal(v) if v is not None else None

    what = "futures and options" if source.endswith("COMBINED") else "futures only"
    lines = [f"{p['root']} positioning as of {last} ({what}): open interest {_contracts(int(on('oi', last) or 0))}."]
    for key, label in POSITIONING:
        long_, short = on(f"{key}_long", last), on(f"{key}_short", last)
        if long_ is None or short is None:
            continue
        net = long_ - short
        text = f"- {label}: long {int(long_):,}, short {int(short):,}, net {'long' if net >= 0 else 'short'} {abs(int(net)):,}"
        pl, ps = on(f"{key}_long", prior), on(f"{key}_short", prior)
        if prior and pl is not None and ps is not None:
            change = int(net - (pl - ps))
            text += f" ({abs(change):,} {'longer' if change > 0 else 'shorter'} on the week)" if change else " (unchanged on the week)"
        lines.append(text + ".")
    return "\n".join(lines)


async def mkt_data_fixing(name: str) -> str:
    want = name.strip()
    status, d = await _api(f"/api/instruments/{want}", {})
    if status == 404:
        return f"There's no fixing called {want!r}. Try SOFR, EFFR, or an FX rate like EURUSD-ECB or USDJPY-H10."
    if status != 200:
        return d
    if d["type"] not in ("rate_fixing", "fx_fixing", "fx_index"):
        return f"{d['name']} isn't a fixing: it's a {d['type']}."
    x = d.get("latest")
    if not x:
        return f"{d['name']} ({d['description']}) has no value yet."
    value = f"{x['display']}%" if d.get("unit") == "%" else x["display"]
    return f"{d['name']}, {d['description']}: {value} on {x['date']}, from {x['source']}."
