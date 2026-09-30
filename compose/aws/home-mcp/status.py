"""platform_status: the whole platform in one spoken-friendly sentence.

Everything is read from sources that already exist (Prometheus, the apps'
own health endpoints, cost-exporter's metrics) -- this module adds no new
collection, it only summarizes. Output leads with a single sentence meant
to be read aloud, then one short line per problem.
"""

import asyncio
import datetime
import os

import httpx

PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")

APPS = {
    "portal": "https://billandjessie.com/",
    "todo-app": "https://todo-app.billandjessie.com/health",
    "hue": "https://hue.billandjessie.com/health",
    "grafana": "https://grafana.billandjessie.com/api/health",
    "authentik": "https://auth.billandjessie.com/-/health/live/",
}

HUB_JOBS = ["prometheus", "postgres", "redis", "authentik", "traefik", "cost-exporter"]

# Load per core above this is "something is stuck", not "busy" -- nuc4 sat
# at ~113 per core for 10 days (2026-09-20 nouveau wedge) with nothing
# watching for it.
LOAD_PER_CORE_ALERT = 4.0


async def _prom(client: httpx.AsyncClient, query: str) -> list[dict]:
    r = await client.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": query}, timeout=5)
    r.raise_for_status()
    return r.json()["data"]["result"]


async def _app_ok(client: httpx.AsyncClient, url: str) -> bool:
    try:
        r = await client.get(url, timeout=5, follow_redirects=False)
        return r.status_code < 400
    except httpx.HTTPError:
        return False


def _rambles_off_season(today: datetime.date) -> bool:
    # Rambles is closed November through April.
    return today.month >= 11 or today.month <= 4


async def platform_status() -> str:
    problems: list[str] = []
    async with httpx.AsyncClient() as client:
        (internet, routers, nodes, load, cores, hub, mtd, forecast), app_results = await asyncio.gather(
            asyncio.gather(
                _prom(client, 'max by (site) (probe_success{job="blackbox-icmp"})'),
                _prom(client, 'up{job="snmp", device=~"rt-.*"}'),
                _prom(client, 'up{job="node-exporter", instance=~"nuc.*"}'),
                _prom(client, 'node_load1{instance=~"nuc.*"}'),
                _prom(client, 'count by (instance) (node_cpu_seconds_total{mode="idle", instance=~"nuc.*"})'),
                _prom(client, "max by (job) (up{job=~\"" + "|".join(HUB_JOBS) + "\"})"),
                _prom(client, "aws_cost_month_to_date_usd"),
                _prom(client, "aws_cost_forecast_month_usd"),
            ),
            asyncio.gather(*(_app_ok(client, url) for url in APPS.values())),
        )

    # Sites: internet (pings from that site's NUC) + the router answering SNMP.
    site_ok = {r["metric"]["site"]: r["value"][1] == "1" for r in internet}
    for r in routers:
        site = "nyc" if r["metric"]["device"] == "rt-nyc" else "rambles"
        site_ok[site] = site_ok.get(site, True) and r["value"][1] == "1"
    rambles_expected_down = _rambles_off_season(datetime.date.today())
    for site in ("nyc", "rambles"):
        if not site_ok.get(site, False):
            if site == "rambles" and rambles_expected_down:
                continue
            problems.append(f"{site.upper() if site == 'nyc' else 'Rambles'} looks offline")

    # NUCs: reachable, and not wedged.
    core_count = {r["metric"]["instance"]: int(float(r["value"][1])) for r in cores}
    for r in nodes:
        inst = r["metric"]["instance"]
        if r["value"][1] != "1" and not (inst == "nuc5" and rambles_expected_down):
            problems.append(f"{inst} is not reporting")
    for r in load:
        inst = r["metric"]["instance"]
        n = core_count.get(inst, 1)
        value = float(r["value"][1])
        if value / n > LOAD_PER_CORE_ALERT:
            problems.append(f"{inst} load is {value:.0f} on {n} cores, likely stuck")

    for r in hub:
        if r["value"][1] != "1":
            problems.append(f"hub service {r['metric']['job']} is down")

    apps_up = sum(app_results)
    for name, ok in zip(APPS, app_results):
        if not ok:
            problems.append(f"{name} is down")

    cost = ""
    if mtd:
        cost = f"AWS is at ${float(mtd[0]['value'][1]):.0f} this month"
        if forecast:
            cost += f", forecast ${float(forecast[0]['value'][1]):.0f}"

    if problems:
        head = f"{len(problems)} issue{'s' if len(problems) > 1 else ''}: " + "; ".join(problems) + "."
    else:
        head = f"All good: sites online, NUCs healthy, {apps_up} of {len(APPS)} apps up."
    lines = [head]
    if cost:
        lines.append(cost + ".")
    if rambles_expected_down:
        lines.append("Rambles is in its closed season, so it isn't counted.")
    return " ".join(lines)
