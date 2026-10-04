"""grafana_alerts: Grafana's alert rules and their state, read-only.

Reads Grafana's Prometheus-compatible rules endpoint
(/api/prometheus/grafana/api/v1/rules) with a Viewer service account token
(GRAFANA_HOME_MCP_TOKEN, /home-platform/grafana/home-mcp-token). The hub
deploy creates the service account and token once, with the admin login
(scripts/hub/deploy-hub-stack.sh). home-mcp reaches Grafana on the stack's
default network as grafana:3000.

Uses: "are the market data alerts loaded and quiet?", "what's firing?". This
would have shown at once that the mkt-data rules weren't loaded after PR #110.
"""

import os

import httpx

GRAFANA_URL = os.environ.get("GRAFANA_URL", "http://grafana:3000")
TOKEN = os.environ.get("GRAFANA_HOME_MCP_TOKEN", "")
TIMEOUT_SECONDS = 20


def _when(ts: str | None) -> str:
    if not ts or ts.startswith("0001"):
        return "never"
    return ts[:16].replace("T", " ") + " UTC"


async def grafana_alerts(group: str = "", show_all: bool = False) -> str:
    if not TOKEN or TOKEN == "none":
        return "Grafana alert access isn't set up yet (GRAFANA_HOME_MCP_TOKEN; the next hub deploy creates it)."
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"{GRAFANA_URL}/api/prometheus/grafana/api/v1/rules",
                headers={"Authorization": f"Bearer {TOKEN}"},
                timeout=TIMEOUT_SECONDS,
            )
    except httpx.HTTPError as exc:
        return f"I couldn't reach Grafana ({type(exc).__name__})."
    if r.status_code != 200:
        return f"Grafana answered {r.status_code}: {r.text[:200]}"
    groups = r.json().get("data", {}).get("groups", [])
    want = group.strip().lower()
    if want:
        groups = [g for g in groups if want in g.get("name", "").lower() or want in g.get("file", "").lower()]
        if not groups:
            return f"No alert group matching {group!r}."
    rules = [(g, rule) for g in groups for rule in g.get("rules", [])]
    counts: dict[str, int] = {}
    for _, rule in rules:
        counts[rule.get("state", "unknown")] = counts.get(rule.get("state", "unknown"), 0) + 1
    summary = ", ".join(f"{n} {state}" for state, n in sorted(counts.items()))
    lines = [f"{len(rules)} alert rule{'s' if len(rules) != 1 else ''} in {len(groups)} group(s): {summary}."]
    for g, rule in rules:
        state, health = rule.get("state"), rule.get("health")
        if not (show_all or want or state != "inactive" or health not in ("ok", None)):
            continue
        firing = len([a for a in rule.get("alerts", []) if a.get("state") in ("Alerting", "firing")])
        extra = f", {firing} firing instance(s)" if firing else ""
        err = f", error: {rule['lastError'][:150]}" if rule.get("lastError") else ""
        lines.append(
            f"- [{g.get('name')}] {rule.get('name')}: {state}, health {health}, "
            f"last evaluated {_when(rule.get('lastEvaluation'))}{extra}{err}"
        )
    if len(lines) == 1 and rules:
        lines.append("All inactive and healthy. Pass group (e.g. 'mkt-data') or show_all to list them.")
    return "\n".join(lines)
