"""github_security: open GitHub security alerts and main-branch protection (Milestone 19, ADR-0024).

Read-only. For each repo: open Dependabot alerts (vulnerable dependencies),
secret-scanning alerts (credentials committed to the repo), code-scanning
alerts (CodeQL findings), and whether `main` still has its ruleset (PR
required, no force-push or deletion, CI required). With detail=True it also
names each finding: the CodeQL rule and file:line, or the vulnerable package,
its manifest and the first fixed version -- enough to fix it without opening
GitHub.

Credential: GITHUB_SECURITY_TOKEN, a fine-grained token over the three
repos with read-only Dependabot alerts, Secret scanning alerts, Code
scanning alerts and Metadata -- it can't change anything. Stored in SSM at
/home-platform/github/security-read-token; "none" until Bill creates it, in
which case this says so (branch rules still come back, since they're public).
"""

import asyncio
import os

import httpx

import github_status

OWNER = github_status.OWNER
REPOS = github_status.REPOS
SPOKEN = github_status.SPOKEN
API = "https://api.github.com"
TOKEN = os.environ.get("GITHUB_SECURITY_TOKEN", "")
if TOKEN == "none":
    TOKEN = ""
SEVERITY_ORDER = ["critical", "high", "medium", "low"]
SEVERITY_RANK = {s: i for i, s in enumerate(SEVERITY_ORDER)}
MAX_DETAIL_LINES = 40
WANTED_RULES = {"pull_request": "PR required", "non_fast_forward": "no force-push", "deletion": "no deletion", "required_status_checks": "CI required"}
# The platform repo has no PR CI, so its ruleset can't require a check.
NO_CI_REPOS = {"nyc_pa_aws_gitops"}


class NotEnabled(Exception):
    pass


async def _get(client: httpx.AsyncClient, path: str, params: dict | None = None, auth: bool = True):
    headers = {"Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"}
    if auth and TOKEN:
        headers["Authorization"] = f"Bearer {TOKEN}"
    r = await client.get(f"{API}{path}", params=params, headers=headers, timeout=15)
    if r.status_code in (403, 404):
        # 403 "...alerts are disabled", 404 "no analysis found": the feature
        # is off for this repo (or the token can't see it).
        msg = ""
        try:
            msg = r.json().get("message", "")
        except ValueError:
            pass
        raise NotEnabled(msg or str(r.status_code))
    r.raise_for_status()
    return r.json()


def _by_severity(sevs: list[str]) -> str:
    counts = {s: sevs.count(s) for s in SEVERITY_ORDER if s in sevs}
    return ", ".join(f"{n} {s}" for s, n in counts.items())


def _code_detail(name: str, a: dict) -> tuple[int, str]:
    rule = a.get("rule") or {}
    sev = rule.get("security_severity_level") or rule.get("severity") or "low"
    loc = (a.get("most_recent_instance") or {}).get("location") or {}
    where = f"{loc.get('path', '?')}:{loc.get('start_line', '?')}"
    what = rule.get("description") or rule.get("id") or "finding"
    return SEVERITY_RANK.get(sev, 9), f"{name} code-scanning {sev}: {what} [{rule.get('id', '?')}] at {where} (alert #{a.get('number')})"


def _dep_detail(name: str, a: dict) -> tuple[int, str]:
    adv = a.get("security_advisory") or {}
    sev = adv.get("severity", "low")
    dep = a.get("dependency") or {}
    pkg = (dep.get("package") or {}).get("name", "?")
    fixed = ((a.get("security_vulnerability") or {}).get("first_patched_version") or {}).get("identifier")
    summary = (adv.get("summary") or "").rstrip(".")
    return SEVERITY_RANK.get(sev, 9), (
        f"{name} dependency {sev}: {pkg} in {dep.get('manifest_path', '?')} -- {summary}; "
        + (f"fixed in {fixed}" if fixed else "no fixed version yet")
        + f" (alert #{a.get('number')})"
    )


async def _repo(client: httpx.AsyncClient, repo: str) -> tuple[list[str], list[str], list[str], list[tuple[int, str]]]:
    """(urgent, info, couldnt, details) for one repo; details are (severity rank, line)."""
    name = SPOKEN.get(repo, repo)
    urgent, info, couldnt = [], [], []
    details: list[tuple[int, str]] = []
    calls = {
        "rules": _get(client, f"/repos/{OWNER}/{repo}/rules/branches/main", auth=False),
    }
    if TOKEN:
        calls.update(
            dependabot=_get(client, f"/repos/{OWNER}/{repo}/dependabot/alerts", {"state": "open", "per_page": 100}),
            secrets=_get(client, f"/repos/{OWNER}/{repo}/secret-scanning/alerts", {"state": "open", "per_page": 100}),
            code=_get(client, f"/repos/{OWNER}/{repo}/code-scanning/alerts", {"state": "open", "per_page": 100}),
        )
    keys = list(calls)
    results = dict(zip(keys, await asyncio.gather(*calls.values(), return_exceptions=True)))

    rules = results["rules"]
    if isinstance(rules, Exception):
        couldnt.append(f"{name} branch rules")
    else:
        have = {r.get("type") for r in rules}
        missing = [
            label for t, label in WANTED_RULES.items()
            if t not in have and not (t == "required_status_checks" and repo in NO_CI_REPOS)
        ]
        if missing:
            urgent.append(f"{name}: main is missing " + ", ".join(missing))

    if not TOKEN:
        return urgent, info, couldnt, details

    dep = results["dependabot"]
    if isinstance(dep, NotEnabled):
        info.append(f"{name}: Dependabot alerts are off")
    elif isinstance(dep, Exception):
        couldnt.append(f"{name} Dependabot alerts")
    elif dep:
        sevs = [a.get("security_advisory", {}).get("severity", "low") for a in dep]
        pkgs = sorted({a.get("dependency", {}).get("package", {}).get("name", "?") for a in dep})
        details += [_dep_detail(name, a) for a in dep]
        line = f"{name}: {len(dep)} vulnerable dependenc{'ies' if len(dep) != 1 else 'y'} ({_by_severity(sevs)}) in " + ", ".join(pkgs[:6])
        (urgent if {"critical", "high"} & set(sevs) else info).append(line)

    sec = results["secrets"]
    if isinstance(sec, NotEnabled):
        info.append(f"{name}: secret scanning is off")
    elif isinstance(sec, Exception):
        couldnt.append(f"{name} secret-scanning alerts")
    elif sec:
        kinds = sorted({a.get("secret_type_display_name") or a.get("secret_type", "secret") for a in sec})
        for a in sec:
            loc = ((a.get("first_location_detected") or {}).get("details") or {}).get("path", "?")
            details.append((0, f"{name} secret: {a.get('secret_type_display_name') or a.get('secret_type', 'secret')} in {loc} (alert #{a.get('number')}); value not shown"))
        urgent.append(f"{name}: {len(sec)} exposed secret{'s' if len(sec) != 1 else ''} ({', '.join(kinds)}); rotate, then close the alert")

    code = results["code"]
    if isinstance(code, NotEnabled):
        info.append(f"{name}: code scanning isn't set up")
    elif isinstance(code, Exception):
        couldnt.append(f"{name} code-scanning alerts")
    elif code:
        sevs = [(a.get("rule", {}).get("security_severity_level") or "low") for a in code]
        details += [_code_detail(name, a) for a in code]
        line = f"{name}: {len(code)} code-scanning finding{'s' if len(code) != 1 else ''} ({_by_severity(sevs)})"
        (urgent if {"critical", "high"} & set(sevs) else info).append(line)
    return urgent, info, couldnt, details


async def github_security(repo: str = "", detail: bool = False) -> str:
    repos = [r for r in REPOS if not repo or repo in (r, SPOKEN.get(r))] or REPOS
    async with httpx.AsyncClient() as client:
        results = await asyncio.gather(*(_repo(client, r) for r in repos), return_exceptions=True)
    urgent, info, couldnt = [], [], []
    details: list[tuple[int, str]] = []
    for r, res in zip(repos, results):
        if isinstance(res, Exception):
            couldnt.append(SPOKEN.get(r, r))
            continue
        urgent += res[0]
        info += res[1]
        couldnt += res[2]
        details += res[3]
    if urgent:
        head = f"{len(urgent)} GitHub security item{'s' if len(urgent) != 1 else ''} need you: " + "; ".join(urgent) + "."
    elif TOKEN:
        head = "No open high or critical GitHub security alerts, and main is protected everywhere."
    else:
        head = "Main is protected everywhere." if not couldnt else "I could only partly check GitHub."
    lines = [head]
    if info:
        lines.append("Also: " + "; ".join(info) + ".")
    if not TOKEN:
        lines.append(
            "Security alerts aren't set up yet: home-mcp needs a read-only GitHub token "
            "in SSM at /home-platform/github/security-read-token (ADR-0024)."
        )
    if detail and details:
        details.sort(key=lambda d: d[0])
        shown = details[:MAX_DETAIL_LINES]
        lines.append("Details, most severe first:")
        lines += ["- " + d[1] for d in shown]
        if len(details) > len(shown):
            lines.append(f"- ...and {len(details) - len(shown)} more (lowest severity) not shown")
    elif details and not detail:
        lines.append("Ask for the detail to hear each finding.")
    if couldnt:
        lines.append("Couldn't check: " + ", ".join(couldnt) + ".")
    return "\n".join(lines)
