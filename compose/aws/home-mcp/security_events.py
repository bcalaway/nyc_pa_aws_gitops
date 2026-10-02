"""security_events: a week of security-relevant log activity, as counts (Milestone 19, ADR-0024).

Read-only. Everything comes from Loki (30-day retention), so this answers
"what happened this week?" where recent_logs only reaches back 24 hours.
It returns aggregates only -- counts per source and the busiest client
addresses -- never raw log lines, so nothing secret can leak through it.

Sources (all already shipped to Loki except Traefik's access log, which
ADR-0024 turned on, 4xx/5xx only):
- hub SSH (journald, sshd.service) and fail2ban
- router/switch/NUC syslog: failed logins and config changes
- home-mcp's own audit log: who called it, rejected tokens, failed calls,
  and calls that change things (start_task, run_job)
- Traefik access log: failed and refused web requests per app, and the
  busiest sources of 401/403s

Authentik's own login failures come from authentik_audit (its events API),
not from here.
"""

import asyncio
import os
import time

import httpx

LOKI_URL = os.environ.get("LOKI_URL", "http://loki:3100")
ALLOWED_USER = os.environ.get("ALLOWED_USERNAMES", "bcalaway").split(",")[0].strip()
MAX_DAYS = 30

QUERIES = {
    "hub_ssh": 'sum(count_over_time({job="systemd-journal", unit="sshd.service"} |~ "(?i)(failed password|invalid user|authentication failure)" [%(r)s]))',
    "fail2ban": 'sum(count_over_time({job="systemd-journal", unit="fail2ban.service"} |= " Ban " [%(r)s]))',
    "device_login_fail": 'sum by (device) (count_over_time({job="network-syslog"} |~ "(?i)(login failure|failed password|invalid user|authentication fail)" [%(r)s]))',
    "device_config": 'sum by (device) (count_over_time({job="network-syslog", device=~"rt-.*|sw-.*"} |~ "(?i)(changed|added|removed) by" [%(r)s]))',
    "mcp_calls": 'sum(count_over_time({container="home-mcp"} |= "\\"event\\": \\"tool_call\\"" [%(r)s]))',
    "mcp_other_user": 'sum(count_over_time({container="home-mcp"} |= "\\"event\\": \\"tool_call\\"" != "\\"user\\": \\"%(u)s\\"" [%(r)s]))',
    "mcp_rejected": 'sum(count_over_time({container="home-mcp"} |= "rejected token" [%(r)s]))',
    "mcp_failed": 'sum(count_over_time({container="home-mcp"} |= "\\"event\\": \\"tool_call\\"" |= "\\"ok\\": false" [%(r)s]))',
    "mcp_changes": 'sum by (tool) (count_over_time({container="home-mcp"} |= "\\"event\\": \\"tool_call\\"" | regexp "\\"tool\\": \\"(?P<tool>start_task|run_job)\\"" | tool != "" [%(r)s]))',
    "web_errors": 'sum by (RouterName, DownstreamStatus) (count_over_time({container="traefik"} |= "DownstreamStatus" | json | DownstreamStatus >= 400 [%(r)s]))',
    "web_denied_sources": 'topk(5, sum by (ClientHost) (count_over_time({container="traefik"} |= "DownstreamStatus" | json | DownstreamStatus =~ "401|403" [%(r)s])))',
}


async def _query(client: httpx.AsyncClient, q: str) -> list[dict]:
    r = await client.get(f"{LOKI_URL}/loki/api/v1/query", params={"query": q, "time": time.time_ns()}, timeout=30)
    r.raise_for_status()
    return r.json().get("data", {}).get("result", [])


def _n(results: list[dict]) -> int:
    return sum(int(float(r["value"][1])) for r in results)


def _router(name: str) -> str:
    # Traefik names Docker-label routers "<router>@docker".
    return (name or "unrouted").split("@")[0]


async def security_events(days: int = 7) -> str:
    days = max(1, min(int(days or 7), MAX_DAYS))
    rng = f"{days}d"
    async with httpx.AsyncClient() as client:
        names = list(QUERIES)
        raw = await asyncio.gather(
            *(_query(client, QUERIES[k] % {"r": rng, "u": ALLOWED_USER}) for k in names), return_exceptions=True
        )
    res = dict(zip(names, raw))
    couldnt = sorted(k for k, v in res.items() if isinstance(v, Exception))

    def get(k: str) -> list[dict]:
        return [] if isinstance(res[k], Exception) else res[k]

    flags: list[str] = []
    lines: list[str] = []

    other_user = _n(get("mcp_other_user"))
    if other_user:
        flags.append(f"{other_user} home-mcp call{'s' if other_user != 1 else ''} by someone other than you")
    changes = {r["metric"].get("tool"): int(float(r["value"][1])) for r in get("mcp_changes")}
    lines.append(
        f"home-mcp: {_n(get('mcp_calls'))} calls, {_n(get('mcp_rejected'))} rejected tokens, "
        f"{_n(get('mcp_failed'))} failed calls"
        + (f", {changes.get('start_task', 0)} coding tasks and {changes.get('run_job', 0)} jobs started" if changes else "")
        + "."
    )

    ssh, bans = _n(get("hub_ssh")), _n(get("fail2ban"))
    lines.append(f"Hub SSH: {ssh} failed login attempt{'s' if ssh != 1 else ''}, {bans} fail2ban ban{'s' if bans != 1 else ''}.")
    if ssh:
        # SSH is only open to the WireGuard and site subnets, so any failure
        # came from inside the network.
        flags.append(f"{ssh} failed SSH logins on the hub (only reachable from the site LANs and WireGuard)")

    dev_fail = {r["metric"].get("device", "?"): int(float(r["value"][1])) for r in get("device_login_fail")}
    dev_fail = {d: n for d, n in dev_fail.items() if n}
    if dev_fail:
        lines.append("Device login failures: " + ", ".join(f"{d} {n}" for d, n in sorted(dev_fail.items())) + ".")
        flags.append("failed logins on " + ", ".join(sorted(dev_fail)))
    else:
        lines.append("Device login failures: none on routers, switches, NUCs or the NAS.")
    dev_cfg = {r["metric"].get("device", "?"): int(float(r["value"][1])) for r in get("device_config")}
    dev_cfg = {d: n for d, n in dev_cfg.items() if n}
    if dev_cfg:
        lines.append(
            "Router/switch config changes logged: " + ", ".join(f"{d} {n}" for d, n in sorted(dev_cfg.items()))
            + " (expected only when you or a RouterOS deploy changed something)."
        )

    by_router: dict[str, dict[str, int]] = {}
    for r in get("web_errors"):
        m = r["metric"]
        by_router.setdefault(_router(m.get("RouterName", "")), {})[m.get("DownstreamStatus", "?")] = int(float(r["value"][1]))
    if by_router:
        total = sum(sum(v.values()) for v in by_router.values())
        top = sorted(by_router.items(), key=lambda kv: -sum(kv[1].values()))[:6]
        parts = [
            f"{name} " + "/".join(f"{n}x{code}" for code, n in sorted(codes.items(), key=lambda kv: -kv[1])[:3])
            for name, codes in top
        ]
        lines.append(f"Web: {total} failed or refused requests: " + "; ".join(parts) + ".")
        sources = [
            f"{r['metric'].get('ClientHost', '?')} ({int(float(r['value'][1]))})"
            for r in sorted(get("web_denied_sources"), key=lambda r: -float(r["value"][1]))
        ]
        if sources:
            lines.append("Most 401/403s came from: " + ", ".join(sources) + ".")
    elif "web_errors" not in couldnt:
        lines.append("Web: no failed or refused requests logged (Traefik's access log only covers 4xx/5xx).")

    head = (
        f"Last {days} days: " + ("; ".join(flags) + "." if flags else "nothing that needs you.")
    )
    out = [head] + lines
    if couldnt:
        out.append("Couldn't query: " + ", ".join(couldnt) + ".")
    return "\n".join(out)
