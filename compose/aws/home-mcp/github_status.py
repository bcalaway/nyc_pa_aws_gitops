"""github_status: PRs, CI and deploy runs for Bill's repos, for voice.

Read-only, and tokenless: every repo listed here is public, so this uses
GitHub's anonymous REST API, the same way context.py reads docs. No
credential is added to home-mcp, and none could be used to write anything.

Anonymous calls are limited to 60 an hour from the hub's IP. One full
check is two calls per repo (open PRs + recent Actions runs), cached for
CACHE_SECONDS, so voice can ask about ten fresh times an hour. If the limit
is hit, the answer says so instead of failing.

Output is meant to be read aloud: one short line per repo, leading with
whatever needs Bill (a run waiting for approval, a failure), then open PRs,
then the latest run of each workflow on main.
"""

import asyncio
import datetime
import os
import re
import time

import httpx

OWNER = os.environ.get("GITHUB_STATUS_OWNER", "bcalaway")
REPOS = [r.strip() for r in os.environ.get("GITHUB_STATUS_REPOS", "todo-app,hue,nyc_pa_aws_gitops").split(",") if r.strip()]
# Spoken names; anything not listed is read as-is.
SPOKEN = {"nyc_pa_aws_gitops": "platform repo", "todo-app": "todo-app", "hue": "hue"}
API = "https://api.github.com"
CACHE_SECONDS = 60
MAX_PRS = 3

_cache: dict[str, tuple[float, dict]] = {}


class RateLimited(Exception):
    pass


async def _get(client: httpx.AsyncClient, path: str, params: dict | None = None):
    r = await client.get(
        f"{API}{path}",
        params=params,
        headers={"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"},
        timeout=10,
    )
    if r.status_code in (403, 429) and r.headers.get("x-ratelimit-remaining") == "0":
        raise RateLimited(r.headers.get("x-ratelimit-reset", ""))
    r.raise_for_status()
    return r.json()


async def _fetch(client: httpx.AsyncClient, repo: str) -> dict:
    hit = _cache.get(repo)
    if hit and time.monotonic() - hit[0] < CACHE_SECONDS:
        return hit[1]
    pulls, runs = await asyncio.gather(
        _get(client, f"/repos/{OWNER}/{repo}/pulls", {"state": "open", "per_page": 20}),
        _get(client, f"/repos/{OWNER}/{repo}/actions/runs", {"per_page": 30}),
    )
    data = {"pulls": pulls, "runs": runs.get("workflow_runs", [])}
    _cache[repo] = (time.monotonic(), data)
    return data


def _ago(iso: str, now: datetime.datetime) -> str:
    then = datetime.datetime.fromisoformat(iso.replace("Z", "+00:00"))
    minutes = int((now - then).total_seconds() // 60)
    if minutes < 1:
        return "just now"
    if minutes < 60:
        return f"{minutes} minute{'s' if minutes != 1 else ''} ago"
    hours = minutes // 60
    if hours < 48:
        return f"{hours} hour{'s' if hours != 1 else ''} ago"
    return f"{hours // 24} days ago"


def _run_state(run: dict) -> str:
    status, conclusion = run.get("status"), run.get("conclusion")
    if status == "waiting":
        return "waiting for your approval"
    if status in ("queued", "in_progress", "requested", "pending"):
        return "running"
    return {
        "success": "succeeded",
        "failure": "failed",
        "cancelled": "was cancelled",
        "timed_out": "timed out",
        "skipped": "was skipped",
        "action_required": "needs action",
    }.get(conclusion or "", conclusion or status or "unknown")


def _what(run: dict) -> str:
    """'PR #3' for a merge commit, else the commit's first line, shortened."""
    title = run.get("display_title") or ""
    if title.startswith("voice-job "):
        # Voice jobs (ADR-0022) run on main's latest commit; what matters is
        # the job itself, e.g. "restart-app hue".
        import jobs  # local: jobs imports this module

        return jobs._label_from_title(title)
    msg = ((run.get("head_commit") or {}).get("message") or "").splitlines()[0:1]
    first = msg[0] if msg else ""
    m = re.match(r"Merge pull request #(\d+)", first)
    if m:
        return f"PR #{m.group(1)}"
    return (first[:50] + "...") if len(first) > 50 else first


def _pr_ci(pr: dict, runs: list[dict]) -> str:
    sha = pr["head"]["sha"]
    mine = [r for r in runs if r.get("head_sha") == sha and r.get("event") == "pull_request"]
    if not mine:
        return "no CI yet"
    states = {_run_state(r) for r in mine}
    if "failed" in states or "timed out" in states:
        return "CI failed"
    if "running" in states:
        return "CI running"
    if states <= {"succeeded", "was skipped"}:
        return "CI passed"
    return "CI " + ", ".join(sorted(states))


def _summarize(repo: str, data: dict, now: datetime.datetime) -> str:
    name = SPOKEN.get(repo, repo)
    runs = data["runs"]
    parts: list[str] = []

    waiting = [r for r in runs if r.get("status") == "waiting"]
    for r in waiting:
        parts.append(f"{r['name']} for {_what(r)} is waiting for your approval")

    pulls = data["pulls"]
    if pulls:
        shown = [f"#{p['number']} {p['title'][:60]} ({_pr_ci(p, runs)})" for p in pulls[:MAX_PRS]]
        more = f", plus {len(pulls) - MAX_PRS} more" if len(pulls) > MAX_PRS else ""
        parts.append(f"{len(pulls)} open PR{'s' if len(pulls) != 1 else ''}: " + "; ".join(shown) + more)
    else:
        parts.append("no open PRs")

    # Latest run of each workflow on main (newest first in the API).
    latest: dict[str, dict] = {}
    for r in runs:
        if (
            r.get("head_branch") == "main"
            and r.get("event") in ("push", "workflow_dispatch")
            and r.get("status") != "waiting"  # already said above
        ):
            latest.setdefault(r["name"], r)
    if latest:
        newest = sorted(latest.values(), key=lambda r: r["created_at"], reverse=True)[:3]
        parts.append(
            "On main: "
            + "; ".join(f"{r['name']} for {_what(r)}: {_run_state(r)}, {_ago(r['created_at'], now)}" for r in newest)
        )
    return f"{name}: " + ". ".join(parts) + "."


async def github_status(repo: str = "") -> str:
    repo = repo.strip()
    if repo:
        # Accept spoken forms like "platform repo" or "todo app".
        wanted = {v.lower(): k for k, v in SPOKEN.items()} | {k.lower(): k for k in REPOS}
        key = wanted.get(repo.lower()) or wanted.get(repo.lower().replace(" ", "-"))
        if key not in REPOS:
            return f"I can check {', '.join(SPOKEN.get(r, r) for r in REPOS)}."
        repos = [key]
    else:
        repos = REPOS

    now = datetime.datetime.now(datetime.timezone.utc)
    async with httpx.AsyncClient() as client:
        results = await asyncio.gather(*(_fetch(client, r) for r in repos), return_exceptions=True)

    lines = []
    for r, res in zip(repos, results):
        name = SPOKEN.get(r, r)
        if isinstance(res, RateLimited):
            reset = ""
            if res.args and res.args[0].isdigit():
                mins = max(1, int((int(res.args[0]) - time.time()) // 60) + 1)
                reset = f", try again in about {mins} minutes"
            lines.append(f"{name}: GitHub's rate limit is used up{reset}.")
        elif isinstance(res, Exception):
            lines.append(f"{name}: couldn't reach GitHub ({type(res).__name__}).")
        else:
            lines.append(_summarize(r, res, now))
    return " ".join(lines)


async def pending_approvals() -> list[str] | None:
    """Runs waiting for Bill's approval, as short spoken phrases, for
    platform_status. Shares github_status's cache, so asking both in a row
    costs no extra GitHub calls. None means GitHub couldn't be checked (rate
    limit or network): platform_status says so instead of failing."""
    async with httpx.AsyncClient() as client:
        results = await asyncio.gather(*(_fetch(client, r) for r in REPOS), return_exceptions=True)
    if all(isinstance(res, Exception) for res in results):
        return None
    waiting = []
    for repo, res in zip(REPOS, results):
        if isinstance(res, Exception):
            continue
        for run in res["runs"]:
            if run.get("status") == "waiting":
                waiting.append(f"{SPOKEN.get(repo, repo)} {run['name']} for {_what(run)}")
    return waiting
