"""recent_logs: read-only container logs from Loki, for debugging by chat or voice.

Every container on the hub logs through journald, and Alloy ships it to
Loki with a `container` label (compose/aws/alloy). This module only
queries Loki over the stack's internal network, so it adds no collection
and no credentials.

Guard rails, since log lines go into a Claude conversation:
- containers: an allowlist of hub services, plus per-PR preview containers
  (<app>-pr<n>-<service>-1, ADR-0023). No free-form LogQL
- filter text: a plain substring, stripped of anything that could change
  the query
- secrets: values after keys like token/password/secret/code/state/cookie/
  authorization, JWTs, and long opaque strings are replaced with
  [redacted] before anything leaves this server
- size: at most 40 lines from the last 24 hours, each shortened
"""

import json
import os
import re
import time

import httpx

LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100")
MAX_LINES = 40
MAX_MINUTES = 24 * 60
MAX_LINE_CHARS = 400

CONTAINERS = {
    "authentik-server", "authentik-worker", "traefik", "home-mcp", "postgres",
    "postgres-backup", "grafana", "uptime-kuma", "umami", "prometheus", "loki",
    "alloy", "redis", "cost-exporter", "rachio-exporter", "todo-app", "hue",
}
# Short names Bill might say.
ALIASES = {
    "authentik": "authentik-server", "auth": "authentik-server", "outpost": "authentik-server",
    "mcp": "home-mcp", "home platform": "home-mcp", "kuma": "uptime-kuma",
    "status": "uptime-kuma", "analytics": "umami", "todo": "todo-app", "backup": "postgres-backup",
}
PREVIEW_CONTAINER = re.compile(r"[a-z0-9-]+-pr[0-9]+(-[a-z0-9_-]+-[0-9]+)?")

_SECRET_KEYS = r"(?:authorization|bearer|token|access_token|refresh_token|id_token|password|passwd|secret|client_secret|api[_-]?key|cookie|set-cookie|session|code|state|sig|signature)"
_REDACTIONS = [
    # key=value, key: value, "key": "value"
    (re.compile(rf'(?i)("?{_SECRET_KEYS}"?\s*[:=]\s*"?)([^\s"&,}}]+)'), r"\1[redacted]"),
    (re.compile(r"(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]+"), r"\1 [redacted]"),
    (re.compile(r"eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"), "[redacted-jwt]"),
    (re.compile(r"\b[A-Za-z0-9_+/=-]{40,}\b"), "[redacted]"),
]


def redact(line: str) -> str:
    for pattern, repl in _REDACTIONS:
        line = pattern.sub(repl, line)
    return line


def _resolve(container: str) -> str | None:
    c = container.strip().lower()
    c = ALIASES.get(c, c)
    if c in CONTAINERS or PREVIEW_CONTAINER.fullmatch(c):
        return c
    return None


def _shorten(raw: str) -> str:
    """JSON log lines (Authentik, Traefik, home-mcp) -> 'level event key=value'."""
    try:
        d = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        d = None
    if isinstance(d, dict):
        level = d.get("level") or d.get("lvl") or ""
        msg = d.get("event") or d.get("msg") or d.get("message") or ""
        extra = {
            k: v for k, v in d.items()
            if k not in ("level", "lvl", "event", "msg", "message", "timestamp", "time", "ts", "logger", "pid")
            and isinstance(v, (str, int, float, bool))
        }
        raw = " ".join(str(x) for x in (level, msg) if x) + (" " + json.dumps(extra) if extra else "")
    raw = redact(raw)
    return raw if len(raw) <= MAX_LINE_CHARS else raw[:MAX_LINE_CHARS] + "..."


async def recent_logs(container: str, minutes: int = 30, contains: str = "") -> str:
    name = _resolve(container)
    if not name:
        return (
            f"I can read logs for: {', '.join(sorted(CONTAINERS))}, "
            "and preview containers like todo-app-pr7-app-1."
        )
    minutes = max(1, min(int(minutes or 30), MAX_MINUTES))
    # Plain substring only; drop characters that could break out of the
    # LogQL string literal.
    needle = re.sub(r'[\\"`]', "", contains or "")[:80]
    # Backtick (raw) string in LogQL, so re.escape's backslashes pass through.
    # Go's regexp rejects Python's escaping of spaces, so escape only the
    # regex metacharacters.
    pattern = re.sub(r"([.^$*+?()\[\]{}|\\])", r"\\\1", needle)
    query = f'{{container="{name}"}}' + (f" |~ `(?i){pattern}`" if needle else "")
    end = time.time_ns()
    start = end - minutes * 60 * 1_000_000_000
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{LOKI_URL}/loki/api/v1/query_range",
                params={"query": query, "start": start, "end": end, "limit": MAX_LINES, "direction": "backward"},
                timeout=15,
            )
            r.raise_for_status()
    except httpx.HTTPError as exc:
        return f"I couldn't read logs from Loki ({type(exc).__name__})."
    entries = []
    for stream in r.json().get("data", {}).get("result", []):
        entries.extend(stream.get("values", []))
    if not entries:
        what = f" matching '{needle}'" if needle else ""
        return f"No {name} log lines{what} in the last {minutes} minutes."
    entries.sort(key=lambda e: int(e[0]))  # oldest first, to read as a story
    lines = [
        time.strftime("%H:%M:%S", time.gmtime(int(ts) / 1e9)) + "Z " + _shorten(raw)
        for ts, raw in entries[-MAX_LINES:]
    ]
    head = f"{len(lines)} {name} log line{'s' if len(lines) != 1 else ''}"
    head += f" matching '{needle}'" if needle else ""
    head += f" from the last {minutes} minutes (secrets redacted):"
    return head + "\n" + "\n".join(lines)
