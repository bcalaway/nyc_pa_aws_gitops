"""prometheus_query and prometheus_metrics: read-only PromQL for Claude.

For questions the named tools don't cover ("what was the hub's CPU at 3am?",
"which metrics does the new exporter expose?") and for checking a dashboard
or alert query against live data before writing it.

Guard rails, since a query can be expensive and answers are read aloud:
- read-only by nature (Prometheus's query API can't change anything);
- a server-side timeout, and a cap on how many series come back;
- range queries are capped in length and summarised per series (min,
  max, last) rather than returned point by point.
"""

import math
import time

import httpx

from hub_view import PROMETHEUS_URL

MAX_SERIES = 40
MAX_RANGE_MINUTES = 7 * 24 * 60
TIMEOUT_SECONDS = 20


def _labels(metric: dict) -> str:
    name = metric.get("__name__", "")
    rest = ", ".join(f'{k}="{v}"' for k, v in sorted(metric.items()) if k != "__name__")
    return f"{name}{{{rest}}}" if rest else (name or "{}")


def _num(v: str) -> str:
    try:
        f = float(v)
    except ValueError:
        return v
    if math.isnan(f):
        return "NaN"
    return f"{f:.0f}" if f.is_integer() and abs(f) < 1e15 else f"{f:.4g}"


async def prometheus_query(query: str, minutes: int = 0, step_seconds: int = 0) -> str:
    query = query.strip()
    if not query:
        return "Give me a PromQL expression to run."
    params = {"query": query, "timeout": f"{TIMEOUT_SECONDS}s"}
    if minutes > 0:
        minutes = min(minutes, MAX_RANGE_MINUTES)
        end = time.time()
        step = step_seconds or max(60, minutes * 60 // 200)
        params |= {"start": end - minutes * 60, "end": end, "step": step}
        path = "query_range"
    else:
        path = "query"
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{PROMETHEUS_URL}/api/v1/{path}", params=params, timeout=TIMEOUT_SECONDS + 5)
    except httpx.HTTPError as exc:
        return f"I couldn't reach Prometheus ({type(exc).__name__})."
    body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    if r.status_code != 200 or body.get("status") != "success":
        return f"Prometheus rejected the query: {body.get('error') or r.text[:300]}"
    data = body["data"]
    kind, result = data["resultType"], data["result"]
    if kind == "scalar" or kind == "string":
        return f"{kind}: {_num(result[1])}"
    if not result:
        return "No data: the query matched no series" + (f" in the last {minutes} minutes." if minutes else ".")
    lines = [f"{len(result)} series" + (f", showing the first {MAX_SERIES}" if len(result) > MAX_SERIES else "") + ":"]
    for s in result[:MAX_SERIES]:
        if kind == "vector":
            lines.append(f"- {_labels(s['metric'])} = {_num(s['value'][1])}")
        else:  # matrix
            vals = [float(v) for _, v in s["values"] if v not in ("NaN", "+Inf", "-Inf")]
            if vals:
                lines.append(
                    f"- {_labels(s['metric'])}: min {_num(str(min(vals)))}, max {_num(str(max(vals)))}, "
                    f"last {_num(s['values'][-1][1])} ({len(s['values'])} points)"
                )
            else:
                lines.append(f"- {_labels(s['metric'])}: no numeric values")
    return "\n".join(lines)


async def prometheus_metrics(match: str = "") -> str:
    """Metric names, optionally only those containing `match`."""
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{PROMETHEUS_URL}/api/v1/label/__name__/values", timeout=TIMEOUT_SECONDS)
            r.raise_for_status()
            names = r.json()["data"]
    except (httpx.HTTPError, KeyError, ValueError) as exc:
        return f"I couldn't list metrics from Prometheus ({type(exc).__name__})."
    m = match.strip().lower()
    hits = [n for n in names if m in n.lower()] if m else names
    if not hits:
        return f"No metric names contain {match!r} ({len(names)} metrics in total)."
    shown = hits[:200]
    head = f"{len(hits)} metric{'s' if len(hits) != 1 else ''}" + (f" containing {match!r}" if m else "")
    more = " (first 200 shown; narrow with match)" if len(hits) > 200 else ""
    return f"{head}{more}: " + ", ".join(shown)
