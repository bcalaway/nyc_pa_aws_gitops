"""containers and scrape_targets: what's running on the hub and what Prometheus can reach.

Both read Prometheus only (cAdvisor's per-container metrics, Milestone 21 /
ADR-0026, and Prometheus's own target list), so home-mcp gains no Docker
socket and no new credentials. Read-only.

containers answers "did that deploy restart anything?" and "how much memory
is each service using?" in one call: start times, working set against each
container's mem_limit, CPU, and kernel OOM kills.

scrape_targets answers "is the new exporter actually being scraped?": every
active target's health, with the last scrape error for the ones that are down.
"""

import asyncio
import datetime
import os
import time

import httpx

PROMETHEUS_URL = os.environ.get("PROMETHEUS_URL", "http://prometheus:9090")
SEL = 'job="cadvisor"'
RECENT_SECONDS = 3600
NEAR_LIMIT = 0.8
MB = 1024 * 1024


async def _prom(client: httpx.AsyncClient, query: str) -> dict[str, float]:
    """Instant query -> {container name: value}."""
    r = await client.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": query}, timeout=10)
    r.raise_for_status()
    return {
        s["metric"].get("name", ""): float(s["value"][1])
        for s in r.json()["data"]["result"]
    }


def _size(b: float) -> str:
    return f"{b / 1024**3:.1f} GB" if b >= 1024**3 else f"{b / MB:.0f} MB"


def _age(seconds: float) -> str:
    m = int(seconds // 60)
    if m < 60:
        return f"{m} min"
    h = m // 60
    return f"{h} h" if h < 48 else f"{h // 24} days"


async def containers(detail: bool = False) -> str:
    queries = {
        "start": f"max by (name) (container_start_time_seconds{{{SEL}}})",
        "mem": f"max by (name) (container_memory_working_set_bytes{{{SEL}}})",
        "limit": f"max by (name) (container_spec_memory_limit_bytes{{{SEL}}})",
        "cpu": f"sum by (name) (rate(container_cpu_usage_seconds_total{{{SEL}}}[5m]))",
        "oom": f"sum by (name) (increase(container_oom_events_total{{{SEL}}}[24h])) > 0",
        "host_total": 'node_memory_MemTotal_bytes{instance="aws-hub"}',
        "host_avail": 'node_memory_MemAvailable_bytes{instance="aws-hub"}',
    }
    try:
        async with httpx.AsyncClient() as client:
            vals = await asyncio.gather(*(_prom(client, q) for q in queries.values()))
    except (httpx.HTTPError, KeyError, ValueError) as exc:
        return f"I couldn't read container metrics from Prometheus ({type(exc).__name__})."
    d = dict(zip(queries, vals))
    names = sorted(d["mem"], key=lambda n: -d["mem"][n])
    if not names:
        return "No container metrics yet: cAdvisor isn't reporting to Prometheus."

    now = time.time()
    total = sum(d["mem"].values())
    host_total = next(iter(d["host_total"].values()), 0.0)
    host_avail = next(iter(d["host_avail"].values()), 0.0)
    head = f"{len(names)} containers on the hub, using {_size(total)}"
    if host_total:
        head += f"; the hub has {_size(host_total)} with {100 * (1 - host_avail / host_total):.0f}% in use"
    lines = [head + "."]

    recent = sorted((n for n in names if now - d["start"].get(n, 0) < RECENT_SECONDS),
                    key=lambda n: -d["start"][n])
    lines.append("Started in the last hour: " + (
        ", ".join(f"{n} ({_age(now - d['start'][n])} ago)" for n in recent) if recent else "none") + ".")
    oom = {n: v for n, v in d["oom"].items() if n}
    lines.append("OOM kills in 24 hours: " + (
        ", ".join(f"{n} ({v:.0f})" for n, v in sorted(oom.items())) if oom else "none") + ".")
    near = [n for n in names if d["limit"].get(n) and d["mem"][n] / d["limit"][n] >= NEAR_LIMIT]
    lines.append("Above 80% of their memory limit: " + (
        ", ".join(f"{n} ({_size(d['mem'][n])} of {_size(d['limit'][n])})" for n in near) if near else "none") + ".")
    unlimited = [n for n in names if not d["limit"].get(n)]
    if unlimited:
        lines.append(f"{len(unlimited)} of {len(names)} have no memory limit yet.")

    if detail:
        lines.append("Each container, by memory:")
        for n in names:
            lim = d["limit"].get(n)
            lines.append(
                f"- {n}: {_size(d['mem'][n])}"
                + (f" of {_size(lim)}" if lim else ", no limit")
                + f", CPU {d['cpu'].get(n, 0):.2f} cores"
                + (f", up {_age(now - d['start'][n])}" if n in d["start"] else "")
            )
    return "\n".join(lines)


def _rambles_off_season(today: datetime.date) -> bool:
    return today.month >= 11 or today.month <= 4


async def scrape_targets(detail: bool = False) -> str:
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(f"{PROMETHEUS_URL}/api/v1/targets", params={"state": "active"}, timeout=10)
            r.raise_for_status()
            targets = r.json()["data"]["activeTargets"]
    except (httpx.HTTPError, KeyError, ValueError) as exc:
        return f"I couldn't read Prometheus's targets ({type(exc).__name__})."
    if not targets:
        return "Prometheus has no active scrape targets."

    off_season = _rambles_off_season(datetime.date.today())
    by_job: dict[str, list[int]] = {}
    down = []
    for t in targets:
        labels = t.get("labels", {})
        job = labels.get("job", "?")
        up = t.get("health") == "up"
        counts = by_job.setdefault(job, [0, 0])
        counts[0] += up
        counts[1] += 1
        if not up:
            where = labels.get("instance") or labels.get("device") or t.get("scrapeUrl", "")
            rambles = labels.get("site") == "rambles" or labels.get("instance") == "nuc5" or "10.0.2." in t.get("scrapeUrl", "")
            note = " (Rambles is closed, expected)" if rambles and off_season else ""
            err = (t.get("lastError") or "no error reported")[:150]
            down.append(f"- {job} / {where}{note}: {err}")

    up_total = sum(c[0] for c in by_job.values())
    lines = [f"{up_total} of {len(targets)} scrape targets are up across {len(by_job)} jobs."]
    if down:
        lines.append(f"Down ({len(down)}):")
        lines.extend(down)
    if detail:
        lines.append("By job: " + ", ".join(f"{j} {u}/{n}" for j, (u, n) in sorted(by_job.items())) + ".")
    return "\n".join(lines)
