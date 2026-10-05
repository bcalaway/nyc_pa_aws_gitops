"""last_deploys: what the latest deploys actually did, read back from GitHub.

GitHub's job-log downloads aren't reachable from Claude's sessions, but a
run's annotations are, through the same anonymous API github_status uses.
So each deploy path ends with one `result` annotation (run-on-hub.sh,
run-document.sh and terraform-apply.sh), and this tool reads the latest
run's per workflow:

- platform repo "Platform release": one line per step that ran, in order:
  Terraform (AWS) and (GitHub) ("Apply complete! Resources: ..." or the
  error), app databases, the hub stack (Compose version, what restarted,
  anything not running), NUCs deployed or skipped
- each app's "CD": the hub-side deploy result (e.g. a mem_limit rejection)

Read-only and tokenless. Runs come from github_status's cache; annotations
cost one call per job that ran, cached for CACHE_SECONDS.
"""

import asyncio
import datetime
import time

import httpx

import github_status

OWNER = github_status.OWNER
# (repo, workflow name) pairs, in the order they're read out.
WATCHED = [
    ("nyc_pa_aws_gitops", "Platform release"),
    ("todo-app", "CD"),
    ("hue", "CD"),
    ("mkt-data", "CD"),
    ("calendar-svc", "CD"),
    ("secmaster-svc", "CD"),
    ("quote-svc", "CD"),
    ("mkt-api", "CD"),
    ("mkt-ui", "CD"),
]
CACHE_SECONDS = 120
_notes_cache: dict[int, tuple[float, list[str]]] = {}


async def _results(client: httpx.AsyncClient, repo: str, run: dict) -> list[str]:
    hit = _notes_cache.get(run["id"])
    if hit and time.monotonic() - hit[0] < CACHE_SECONDS:
        return hit[1]
    jobs = await github_status._get(client, f"/repos/{OWNER}/{repo}/actions/runs/{run['id']}/jobs")
    out = []
    for j in jobs.get("jobs", []):
        if j.get("conclusion") == "skipped" or not j.get("started_at"):
            continue
        notes = await github_status._get(client, f"/repos/{OWNER}/{repo}/check-runs/{j['id']}/annotations")
        out += [f"{j['name']}: {a.get('message', '').strip()}" for a in notes if a.get("title") == "result"]
    if run.get("status") == "completed":  # a running deploy's notes aren't final
        _notes_cache[run["id"]] = (time.monotonic(), out)
    return out


async def _one(client: httpx.AsyncClient, repo: str, workflow: str, now: datetime.datetime) -> str:
    name = f"{github_status.SPOKEN.get(repo, repo)} {workflow}"
    data = await github_status._fetch(client, repo)
    runs = [r for r in data["runs"] if r.get("name") == workflow and r.get("head_branch") == "main"
            and r.get("event") in ("push", "workflow_dispatch")]
    if not runs:
        return f"{name}: no recent run on main."
    run = runs[0]
    head = f"{name} for {github_status._what(run)} {github_status._run_state(run)}, {github_status._ago(run['created_at'], now)}"
    results = await _results(client, repo, run)
    if not results:
        return head + "." + ("" if run.get("status") != "completed" else " Nothing to report (no deploy steps ran).")
    return head + ":\n  " + "\n  ".join(results)


async def last_deploys(repo: str = "") -> str:
    watched = [(r, w) for r, w in WATCHED if not repo or repo.strip().lower() in
               (r.lower(), github_status.SPOKEN.get(r, r).lower())]
    if not watched:
        return "I track deploys for: " + ", ".join(sorted({github_status.SPOKEN.get(r, r) for r, _ in WATCHED})) + "."
    now = datetime.datetime.now(datetime.timezone.utc)
    async with httpx.AsyncClient() as client:
        res = await asyncio.gather(*(_one(client, r, w, now) for r, w in watched), return_exceptions=True)
    lines = []
    for (r, w), x in zip(watched, res):
        if isinstance(x, github_status.RateLimited):
            lines.append(f"{github_status.SPOKEN.get(r, r)} {w}: GitHub's rate limit is used up.")
        elif isinstance(x, Exception):
            lines.append(f"{github_status.SPOKEN.get(r, r)} {w}: couldn't reach GitHub ({type(x).__name__}).")
        else:
            lines.append(x)
    return "\n".join(lines)
