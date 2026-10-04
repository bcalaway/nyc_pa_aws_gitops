"""airflow_runs, airflow_task_log and airflow_trigger: Airflow's REST API.

home-mcp reaches the API server on the home-platform network
(airflow-api-server:8080) over the internal airflow-api network. Airflow runs
the simple auth manager with every user an admin (compose/aws/data.yml), so
GET /auth/token issues a token with no credentials. That's why the API server
is only on that network (2026-10-04): apps on home-platform can't reach it,
only Airflow itself, Traefik and home-mcp.

airflow_trigger is the only tool here that changes anything, and only for
DAGs named mkt_data__*: their runs are idempotent captures (Bill, 2026-10-04),
so Claude can re-run them without a GitHub approval. Everything else is
read-only.

Uses: "did the SIFMA DAG run, and how did it go?", "show me the failed task's
log", "run the NYSE calendar now".
"""

import os
import re
import time

import httpx

AIRFLOW_URL = os.environ.get("AIRFLOW_URL", "http://airflow-api-server:8080")
TIMEOUT_SECONDS = 20
TRIGGERABLE = re.compile(r"^mkt_data__[a-z0-9_]+$")
DAG_ID = re.compile(r"^[A-Za-z0-9_.-]{1,250}$")
MAX_LOG_LINES = 200

_token: tuple[str, float] | None = None  # (token, fetched at)


async def _auth(client: httpx.AsyncClient) -> dict:
    global _token
    if _token is None or time.monotonic() - _token[1] > 600:
        r = await client.get(f"{AIRFLOW_URL}/auth/token", timeout=TIMEOUT_SECONDS)
        r.raise_for_status()
        _token = (r.json()["access_token"], time.monotonic())
    return {"Authorization": f"Bearer {_token[0]}"}


async def _call(method: str, path: str, params: dict | None = None, json: dict | None = None) -> tuple[int, dict | str]:
    try:
        async with httpx.AsyncClient() as client:
            headers = await _auth(client) | {"Accept": "application/json"}
            r = await client.request(
                method, f"{AIRFLOW_URL}/api/v2/{path}", params=params, json=json, headers=headers,
                timeout=TIMEOUT_SECONDS,
            )
    except httpx.HTTPError as exc:
        return 0, f"I couldn't reach Airflow's API ({type(exc).__name__})."
    try:
        body = r.json()
    except ValueError:
        body = {}
    if r.status_code >= 300:
        detail = body.get("detail") if isinstance(body, dict) else None
        return r.status_code, f"Airflow answered {r.status_code}: {detail or r.text[:200]}"
    return r.status_code, body


def _when(ts: str | None) -> str:
    return ts[:16].replace("T", " ") + " UTC" if ts else "-"


def _duration(run: dict) -> str:
    start, end = run.get("start_date"), run.get("end_date")
    if not (start and end):
        return ""
    from datetime import datetime

    secs = (datetime.fromisoformat(end) - datetime.fromisoformat(start)).total_seconds()
    return f", {secs:.0f}s" if secs < 120 else f", {secs / 60:.0f} min"


async def airflow_runs(dag: str = "", limit: int = 10) -> str:
    dag = dag.strip() or "~"
    if dag != "~" and not DAG_ID.match(dag):
        return f"{dag!r} isn't a DAG id."
    status, body = await _call(
        "GET", f"dags/{dag}/dagRuns", params={"order_by": "-run_after", "limit": max(1, min(limit, 50))}
    )
    if status != 200:
        return body
    runs = body.get("dag_runs", [])
    if not runs:
        return f"No runs{' for ' + dag if dag != '~' else ''} yet."
    lines = [f"{len(runs)} run{'s' if len(runs) != 1 else ''}, newest first:"]
    for r in runs:
        lines.append(
            f"- {r['dag_id']}: {r.get('state')} ({r.get('run_type')}), started {_when(r.get('start_date'))}"
            f"{_duration(r)}. Run id {r['dag_run_id']}"
        )
    return "\n".join(lines)


async def airflow_task_log(dag: str, run_id: str = "", task: str = "", try_number: int = 0, lines: int = 60) -> str:
    if not DAG_ID.match(dag.strip()):
        return f"{dag!r} isn't a DAG id."
    dag = dag.strip()
    if not run_id.strip():
        status, body = await _call("GET", f"dags/{dag}/dagRuns", params={"order_by": "-run_after", "limit": 1})
        if status != 200:
            return body
        if not body.get("dag_runs"):
            return f"{dag} has no runs yet."
        run_id = body["dag_runs"][0]["dag_run_id"]
    status, body = await _call("GET", f"dags/{dag}/dagRuns/{run_id}/taskInstances")
    if status != 200:
        return body
    tis = body.get("task_instances", [])
    if not tis:
        return f"Run {run_id} of {dag} has no task instances."
    if task.strip():
        ti = next((t for t in tis if t["task_id"] == task.strip()), None)
        if ti is None:
            return f"No task {task!r} in that run; tasks: {', '.join(t['task_id'] for t in tis)}."
    else:  # the failed one if any, else the last
        ti = next((t for t in tis if t.get("state") == "failed"), tis[-1])
    attempt = try_number or ti.get("try_number") or 1
    status, body = await _call(
        "GET", f"dags/{dag}/dagRuns/{run_id}/taskInstances/{ti['task_id']}/logs/{attempt}",
        params={"full_content": "true"},
    )
    if status != 200:
        return body
    text = []
    for m in body.get("content", []):
        if isinstance(m, str):
            text.append(m)
        else:
            stamp = (m.get("timestamp") or "")[11:19]
            level = (m.get("level") or "").upper()
            text.append(" ".join(x for x in (stamp, level, str(m.get("event", ""))) if x))
    keep = max(1, min(lines, MAX_LOG_LINES))
    head = (
        f"{dag} / {ti['task_id']} (run {run_id}, try {attempt}, {ti.get('state')}): "
        f"last {min(keep, len(text))} of {len(text)} log lines."
    )
    return "\n".join([head, *[ln[:400] for ln in text[-keep:]]])


async def airflow_trigger(dag: str) -> str:
    dag = dag.strip()
    if not TRIGGERABLE.match(dag):
        return f"I can only trigger the market data DAGs (mkt_data__*), not {dag!r}."
    status, info = await _call("GET", f"dags/{dag}")
    if status != 200:
        return info
    status, body = await _call(
        "POST", f"dags/{dag}/dagRuns", json={"logical_date": None, "note": "Triggered from home-mcp"}
    )
    if status not in (200, 201):
        return body
    paused = " The DAG is paused, so the run waits until it's unpaused." if info.get("is_paused") else ""
    return f"Started {dag}: run {body['dag_run_id']}, {body.get('state')}.{paused} Check it with airflow_runs."
