"""airflow_status: is the shared Airflow healthy, and how have its DAGs done?

Reads Prometheus only (Airflow's StatsD metrics via airflow-statsd-exporter,
ADR-0027), like containers and scrape_targets, so home-mcp needs no Airflow
credentials. Read-only. Answers "is Airflow OK?", "did the Fed calendar job
run?", "any Airflow failures today?".

What it can't say from metrics: whether a DAG is paused, or when it runs
next. Those live in Airflow's own API and UI (airflow.billandjessie.com).
"""

import asyncio
import time

import httpx

from hub_view import PROMETHEUS_URL, _age

TI = "airflow_ti_finish"


async def _query(client: httpx.AsyncClient, q: str) -> list[dict]:
    r = await client.get(f"{PROMETHEUS_URL}/api/v1/query", params={"query": q}, timeout=15)
    r.raise_for_status()
    return r.json()["data"]["result"]


def _by(results: list[dict], label: str) -> dict[str, float]:
    return {s["metric"].get(label, ""): float(s["value"][1]) for s in results}


def _one(results: list[dict]) -> float | None:
    return float(results[0]["value"][1]) if results else None


def _last_event(state: str) -> str:
    # Time each DAG last finished a task in `state`, to the minute: the
    # counter went up, or its series first appeared (statsd_exporter only
    # creates a series on its first event).
    sel = f'{TI}{{state="{state}"}}'
    return (
        f"max by (dag_id) (last_over_time(("
        f"(timestamp({sel}) and (changes({sel}[2m]) > 0))"
        f" or (timestamp({sel}) unless {sel} offset 2m)"
        f")[7d:1m]))"
    )


async def airflow_status(dag: str = "", detail: bool = False) -> str:
    queries = {
        "heartbeat": "sum(rate(airflow_scheduler_heartbeat[5m])) * 60",
        "import_errors": "max(airflow_dag_processing_import_errors)",
        "running": "sum(airflow_pool_running_slots)",
        "queued": "sum(airflow_pool_queued_slots)",
        "ok24": f'sum by (dag_id) (increase({TI}{{state="success"}}[24h]))',
        "fail24": f'sum by (dag_id) (increase({TI}{{state="failed"}}[24h]))',
        "fail7d": f'sum by (dag_id) (increase({TI}{{state="failed"}}[7d]))',
        "last_ok": _last_event("success"),
        "last_fail": _last_event("failed"),
        "dags": f"count by (dag_id) ({TI})",
    }
    try:
        async with httpx.AsyncClient() as client:
            res = await asyncio.gather(*(_query(client, q) for q in queries.values()))
            names = []
            if detail:
                r = await client.get(
                    f"{PROMETHEUS_URL}/api/v1/label/__name__/values",
                    params={"match[]": '{__name__=~"airflow_.*"}'}, timeout=15,
                )
                r.raise_for_status()
                names = r.json()["data"]
    except (httpx.HTTPError, KeyError, ValueError, IndexError) as exc:
        return f"I couldn't read Airflow's metrics from Prometheus ({type(exc).__name__})."
    d = dict(zip(queries, res))

    now = time.time()
    heartbeat = _one(d["heartbeat"])
    errors = _one(d["import_errors"])
    running, queued = _one(d["running"]), _one(d["queued"])
    ok24, fail24, fail7d = _by(d["ok24"], "dag_id"), _by(d["fail24"], "dag_id"), _by(d["fail7d"], "dag_id")
    last_ok, last_fail = _by(d["last_ok"], "dag_id"), _by(d["last_fail"], "dag_id")
    dags = sorted(_by(d["dags"], "dag_id"))

    lines = []
    if not dag:
        if heartbeat is None:
            health = "I can't see the scheduler's heartbeat metric, so I can't tell if Airflow is running"
        elif heartbeat > 0:
            health = "Airflow's scheduler is running"
        else:
            health = "Airflow's scheduler has stopped heartbeating"
        extras = []
        if errors:
            extras.append(f"{errors:.0f} DAG file{'s' if errors != 1 else ''} failing to load")
        elif errors is not None:
            extras.append("no DAG load errors")
        if running is not None:
            extras.append(f"{running:.0f} of 4 task slots busy" + (f", {queued:.0f} queued" if queued else ""))
        lines.append(health + (": " + ", ".join(extras) if extras else "") + ".")
        total_ok, total_fail = sum(ok24.values()), sum(fail24.values())
        lines.append(
            f"Last 24 hours: {total_ok:.0f} task{'s' if round(total_ok) != 1 else ''} succeeded, "
            f"{total_fail:.0f} failed"
            + (" (" + ", ".join(f"{k} {v:.0f}" for k, v in sorted(fail24.items()) if v >= 0.5) + ")" if total_fail >= 0.5 else "")
            + "."
        )

    wanted = [n for n in dags if not dag or dag.lower().replace("-", "_") in n.lower()]
    if dag and not wanted:
        return f"No DAG matching {dag!r} has run in Prometheus's history. Known DAGs: {', '.join(dags) or 'none'}."
    if wanted:
        lines.append("By DAG:" if not dag else "")
        for n in wanted:
            bits = []
            if n in last_ok:
                bits.append(f"last success {_age(now - last_ok[n])} ago")
            else:
                bits.append("no success in 7 days")
            f7 = fail7d.get(n, 0)
            if f7 >= 0.5:
                bits.append(f"{f7:.0f} failed task{'s' if round(f7) != 1 else ''} in 7 days"
                            + (f", last {_age(now - last_fail[n])} ago" if n in last_fail else ""))
            else:
                bits.append("no failures in 7 days")
            lines.append(f"- {n}: " + ", ".join(bits) + ".")
    if detail and names:
        lines.append("Airflow metrics in Prometheus: " + ", ".join(names) + ".")
    lines.append("Paused state and next runs are in the Airflow UI; the Grafana 'Airflow' dashboard has the history.")
    return "\n".join(x for x in lines if x)
