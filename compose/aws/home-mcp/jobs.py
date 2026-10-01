"""Named jobs by voice (ADR-0022, Milestone 18 phase 4).

home-mcp never runs a job itself. run_job checks the request against
jobs/registry.yml on `main` and asks GitHub to start
.github/workflows/voice-job.yml; that workflow re-checks the request, waits
for Bill's approval in the `production` environment, then runs the job on
the hub via SSM. job_status reads the run back through GitHub's anonymous
API, including the one-sentence `result` annotation the job publishes.

The only credential is VOICE_JOBS_GITHUB_TOKEN: a fine-grained token for
nyc_pa_aws_gitops with Actions read/write and nothing else -- it can start
workflows but can't change code, merge, or approve the deployment.

Kill switch: VOICE_JOBS_ENABLED=false (compose env) refuses new jobs while
leaving list_jobs and job_status working.
"""

import asyncio
import calendar
import json
import logging
import os
import secrets
import time

import httpx
import yaml

import github_status

log = logging.getLogger("home-mcp.jobs")

OWNER = github_status.OWNER
REPO = os.environ.get("VOICE_JOBS_REPO", "nyc_pa_aws_gitops")
WORKFLOW = "voice-job.yml"
REGISTRY_URL = f"https://raw.githubusercontent.com/{OWNER}/{REPO}/main/jobs/registry.yml"
ENABLED = os.environ.get("VOICE_JOBS_ENABLED", "false").lower() == "true"
TOKEN = os.environ.get("VOICE_JOBS_GITHUB_TOKEN", "")
if TOKEN == "none":  # deploy placeholder until the SSM parameter exists
    TOKEN = ""
REGISTRY_CACHE_SECONDS = 600
TOKEN_CHECK_SECONDS = 6 * 3600
TOKEN_WARN_DAYS = 21

_registry: dict = {"at": 0.0, "jobs": {}}
_token_health: dict = {"at": 0.0, "warnings": []}
_last_request: dict = {"id": "", "label": ""}
_lock = asyncio.Lock()


async def _load_registry() -> dict:
    async with _lock:
        if _registry["jobs"] and time.monotonic() - _registry["at"] < REGISTRY_CACHE_SECONDS:
            return _registry["jobs"]
        async with httpx.AsyncClient() as client:
            r = await client.get(REGISTRY_URL, timeout=10)
            r.raise_for_status()
        jobs = yaml.safe_load(r.text) or {}
        _registry.update(at=time.monotonic(), jobs=jobs)
        return jobs


def _label(job: str, args: dict) -> str:
    return " ".join([job, *[str(v) for v in args.values()]])


async def list_jobs() -> str:
    try:
        jobs = await _load_registry()
    except httpx.HTTPError as exc:
        return f"I couldn't read the job list from GitHub ({type(exc).__name__})."
    parts = [f"{spec.get('say', name)}: {spec.get('description', '')}" for name, spec in jobs.items()]
    tail = "Every job waits for your approval in GitHub before it runs."
    if not ENABLED or not TOKEN:
        tail += " Jobs are switched off right now, so I can list them but not start them."
    return "I can run: " + "; ".join(parts) + ". " + tail


async def run_job(job: str, args: dict | None = None) -> str:
    if not ENABLED:
        return "Voice jobs are switched off right now."
    if not TOKEN:
        return "Voice jobs aren't set up yet: home-mcp has no GitHub token for them."
    args = {k: str(v) for k, v in (args or {}).items()}
    try:
        jobs = await _load_registry()
    except httpx.HTTPError as exc:
        return f"I couldn't read the job list from GitHub ({type(exc).__name__}), so I didn't start anything."
    spec = jobs.get(job)
    if spec is None:
        return f"There's no job called {job}. I can run: {', '.join(jobs)}."
    allowed = spec.get("args") or {}
    extra = set(args) - set(allowed)
    if extra:
        return f"{job} doesn't take {', '.join(sorted(extra))}."
    for name, values in allowed.items():
        if args.get(name) not in values:
            return f"{job} needs {name} to be one of {', '.join(values)}."
    # Registry order, so the label and the workflow's argv agree.
    args = {name: args[name] for name in allowed}

    request_id = "vj-" + secrets.token_hex(4)
    async with httpx.AsyncClient() as client:
        r = await client.post(
            f"https://api.github.com/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW}/dispatches",
            headers={
                "Authorization": f"Bearer {TOKEN}",
                "Accept": "application/vnd.github+json",
                "X-GitHub-Api-Version": "2022-11-28",
            },
            json={"ref": "main", "inputs": {"job": job, "args": json.dumps(args), "request_id": request_id}},
            timeout=15,
        )
    if r.status_code not in (200, 201, 204):
        log.warning("dispatch failed: %s %s", r.status_code, r.text[:300])
        return f"GitHub didn't accept the job (HTTP {r.status_code}), so nothing is running."
    label = _label(job, args)
    _last_request.update(id=request_id, label=label)
    return (
        f"Started {label} (request {request_id}). It's waiting for your approval in GitHub, "
        "then usually takes a minute or two to run. Ask me for the job status any time."
    )


async def _find_run(client: httpx.AsyncClient, request_id: str) -> dict | None:
    data = await github_status._get(
        client, f"/repos/{OWNER}/{REPO}/actions/workflows/{WORKFLOW}/runs", {"per_page": 20}
    )
    runs = data.get("workflow_runs", [])
    if not request_id:
        return runs[0] if runs else None
    tag = f"[{request_id}]"
    return next((r for r in runs if tag in (r.get("display_title") or r.get("name") or "")), None)


async def _result_annotation(client: httpx.AsyncClient, run_id: int) -> str:
    jobs = await github_status._get(client, f"/repos/{OWNER}/{REPO}/actions/runs/{run_id}/jobs")
    for j in reversed(jobs.get("jobs", [])):
        notes = await github_status._get(client, f"/repos/{OWNER}/{REPO}/check-runs/{j['id']}/annotations")
        for a in notes:
            if a.get("title") == "result":
                return a.get("message", "").strip()
    return ""


def _label_from_title(title: str) -> str:
    # run-name is "voice-job <job> <args JSON> [<request id>]"
    body = title.removeprefix("voice-job ").rsplit(" [", 1)[0]
    job, _, raw = body.partition(" ")
    try:
        args = json.loads(raw) if raw else {}
    except json.JSONDecodeError:
        args = {}
    return _label(job, args if isinstance(args, dict) else {}) if job else "the job"


async def job_status(request_id: str = "") -> str:
    request_id = request_id.strip() or _last_request["id"]
    try:
        async with httpx.AsyncClient() as client:
            run = await _find_run(client, request_id)
            if run is None:
                if request_id and request_id == _last_request["id"]:
                    return f"{_last_request['label']} hasn't shown up in GitHub yet; it was only just requested."
                return "I can't find that job." if request_id else "No voice jobs have run yet."
            label = _label_from_title(run.get("display_title") or "")
            status, conclusion = run.get("status"), run.get("conclusion")
            if status == "waiting":
                return f"{label} is waiting for your approval in GitHub."
            if status != "completed":
                return f"{label} is {'running' if status == 'in_progress' else 'queued'}."
            result = await _result_annotation(client, run["id"])
    except github_status.RateLimited:
        return "GitHub's rate limit is used up; ask again in a few minutes."
    except httpx.HTTPError as exc:
        return f"I couldn't reach GitHub ({type(exc).__name__})."
    if conclusion == "success":
        return f"{label} is done: {result or 'it finished without a summary.'}"
    if conclusion == "cancelled":
        return f"{label} was cancelled{' or rejected' if not result else ''}."
    return f"{label} failed: {result or 'no reason given; check the run in GitHub.'}"


async def token_warnings() -> list[str]:
    """For platform_status: the jobs token's expiry, read from GitHub's
    github-authentication-token-expiration header (checked every 6 hours)."""
    if not ENABLED or not TOKEN:
        return []
    if time.monotonic() - _token_health["at"] < TOKEN_CHECK_SECONDS and _token_health["at"]:
        return _token_health["warnings"]
    warnings: list[str] = []
    try:
        async with httpx.AsyncClient() as client:
            r = await client.get(
                f"https://api.github.com/repos/{OWNER}/{REPO}",
                headers={"Authorization": f"Bearer {TOKEN}", "X-GitHub-Api-Version": "2022-11-28"},
                timeout=10,
            )
        if r.status_code == 401:
            warnings.append("the voice jobs GitHub token is being rejected")
        else:
            exp = r.headers.get("github-authentication-token-expiration")  # "2027-10-01 11:00:00 UTC"
            if exp:
                expires = calendar.timegm(time.strptime(exp, "%Y-%m-%d %H:%M:%S UTC"))
                days = int((expires - time.time()) // 86400)
                if days < 0:
                    warnings.append("the voice jobs GitHub token has expired")
                elif days <= TOKEN_WARN_DAYS:
                    warnings.append(f"the voice jobs GitHub token expires in {days} day{'s' if days != 1 else ''}")
    except httpx.HTTPError:
        return _token_health["warnings"]  # transient; keep the last answer
    _token_health.update(at=time.monotonic(), warnings=warnings)
    return warnings
