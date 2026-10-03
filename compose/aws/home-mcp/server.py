"""home-mcp: remote MCP server for voice Claude (ADR-0021, Milestone 18).

Reached by Claude's custom connector from Anthropic's cloud at
https://mcp.billandjessie.com/mcp. Layers, outermost first: Traefik only
admits Anthropic's egress range; Authentik issues tokens only to Bill,
after an MFA step in this app's own authorization flow; this server
re-validates every token itself (auth.py). Tools are named and fixed --
there is no shell or arbitrary-command tool, by design.

Every tool call is logged as one JSON line to stdout, which the hub's
journald log driver + Alloy's journal source ship to Loki
({container="home-mcp"}), giving an audit trail for free.
"""

import asyncio
import functools
import json
import logging
import os
import time

import uvicorn
from mcp.server.auth.middleware.auth_context import get_access_token
from mcp.server.auth.settings import AuthSettings
from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings
from starlette.requests import Request
from starlette.responses import JSONResponse

import authentik_audit as authentik_audit_mod
import aws_posture as aws_posture_mod
import context
import deploys
import exposure
import github_security as github_security_mod
import github_status as github_status_mod
import hub_view
import jobs
import logs
import security_events as security_events_mod
import status
import tasks
import updates
from auth import AuthentikTokenVerifier

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
# httpx logs every request URL at INFO. Those lines include Loki queries
# whose text contains "tool_call", which security_events then miscounted as
# audit entries from an unknown user (2026-10-02). Errors still surface.
logging.getLogger("httpx").setLevel(logging.WARNING)
audit = logging.getLogger("home-mcp.audit")

PUBLIC_URL = os.environ.get("PUBLIC_URL", "https://mcp.billandjessie.com")
ISSUER = os.environ["OIDC_ISSUER"]  # https://auth.billandjessie.com/application/o/home-mcp/
JWKS_URL = os.environ["OIDC_JWKS_URL"]  # internal: http://authentik-server:9000/application/o/home-mcp/jwks/
CLIENT_ID = os.environ["OIDC_CLIENT_ID"]
ALLOWED_USERNAMES = {u.strip() for u in os.environ.get("ALLOWED_USERNAMES", "bcalaway").split(",") if u.strip()}

mcp = MCPServer(
    name="home-platform",
    instructions=(
        "Tools for Bill's home platform (two sites, NYC and Rambles, plus an AWS hub). "
        "Answers are meant to be read aloud: keep replies short and lead with the result."
    ),
    token_verifier=AuthentikTokenVerifier(
        issuer=ISSUER, jwks_url=JWKS_URL, client_id=CLIENT_ID, allowed_usernames=ALLOWED_USERNAMES
    ),
    auth=AuthSettings(
        issuer_url=ISSUER,
        resource_server_url=f"{PUBLIC_URL}/mcp",
        required_scopes=["openid", "profile"],
        # Authentik's aud is the client id, not this URL (no RFC 8707
        # resource binding) -- AuthentikTokenVerifier checks aud itself.
        validate_token_resource=False,
    ),
)


def audited(fn):
    @functools.wraps(fn)
    async def wrapper(*args, **kwargs):
        token = get_access_token()
        started = time.monotonic()
        entry = {
            "event": "tool_call",
            "tool": fn.__name__,
            "args": kwargs,
            "user": (token.claims or {}).get("preferred_username") if token else None,
        }
        try:
            result = await fn(*args, **kwargs)
            entry.update(ok=True, result=str(result)[:500])
            return result
        except Exception as exc:
            entry.update(ok=False, error=repr(exc)[:500])
            raise
        finally:
            entry["ms"] = round((time.monotonic() - started) * 1000)
            audit.info(json.dumps(entry))

    return wrapper


@mcp.tool()
@audited
async def platform_status() -> str:
    """One-sentence health summary of the whole home platform: both sites' internet
    and routers, the NUCs (nuc4 NYC, nuc5 Rambles), the hub's core services, the
    public apps, AWS spend this month, and any deploys waiting for Bill's approval
    on GitHub. Read-only. Use for "how's everything?"."""
    return await status.platform_status()


@mcp.tool()
@audited
async def search_context(query: str, limit: int = 3) -> str:
    """Search the home platform's own project docs (roadmap, gotchas, ADRs, network and
    hardware inventory, SSM catalog, platform reference, CLAUDE.md rules) and return
    the best-matching sections. Read-only. Use for questions like "what was the nuc4
    problem?", "how do I add a DNS record to the router?", "what's the Authentik setup?".
    Summarize the result aloud briefly; don't read it verbatim."""
    return await context.search_context(query, limit)


@mcp.tool()
@audited
async def get_context(doc: str = "", section: str = "") -> str:
    """Read one project doc, or one section of it. Read-only. `doc` is a short name
    ("roadmap", "gotchas", "archive", "ssm", "reference", "network", "hardware",
    "app platform", "new machine", "claude") or an ADR like "adr 21". Call with no
    arguments to list docs. Long docs return their section list -- ask again with
    `section`. Use "roadmap" for "what's left?" / "what's next?"."""
    return await context.get_context(doc, section)


@mcp.tool()
@audited
async def start_task(repo: str, instructions: str) -> str:
    """Start a coding task: an AI agent on the home build server (nuc4) makes the
    change in `repo`, runs its tests, and opens a pull request for Bill to review.
    It NEVER merges or deploys. Allowed repos: todo-app, hue. Takes 5-20 minutes.
    hue: the agent can build and test hue's Python hub backend and its React
    frontend; the C++ agent can be edited but not built or tested by the agent,
    so for agent/ changes tell Bill that CI on the PR is the only check.
    This changes things: before calling, read the instructions back to Bill in one
    sentence and get a clear yes. Write `instructions` as a complete, specific task
    description (what to change and what "done" looks like)."""
    token = get_access_token()
    user = (token.claims or {}).get("preferred_username") if token else None
    return await tasks.start_task(repo, instructions, user)


@mcp.tool()
@audited
async def task_status(task_id: str = "") -> str:
    """Status of a voice coding task: queued, running (and which step), done (with
    the PR link and a short summary), or failed (with why). Read-only. Omit task_id
    for the most recent task; pass "all" for the last five."""
    return await tasks.task_status(task_id)


@mcp.tool()
@audited
async def github_status(repo: str = "") -> str:
    """GitHub status for Bill's repos (todo-app, hue, and the platform repo
    nyc_pa_aws_gitops): runs waiting for his approval, open pull requests with
    their CI result, and the latest CI/deploy runs on main (e.g. "did my merge
    deploy?"). Read-only. Omit `repo` for all three. Read the result aloud in
    short form, leading with anything waiting for approval or failed."""
    return await github_status_mod.github_status(repo)


@mcp.tool()
@audited
async def list_jobs() -> str:
    """List the named jobs Bill can run by voice (e.g. restart an app, deploy
    the NUCs, back up Postgres now), with how to ask and allowed values.
    Read-only."""
    return await jobs.list_jobs()


@mcp.tool()
@audited
async def run_job(job: str, args: dict | None = None) -> str:
    """Start a named job from the job registry on the hub, e.g.
    run_job("restart-app", {"app": "hue"}) or run_job("deploy-nucs").
    Arguments must be one of the allowed values shown by list_jobs. The job
    waits for Bill's approval in GitHub before it runs, then reports one
    sentence that job_status reads back.
    This changes things: before calling, say which job and arguments in one
    sentence and get a clear yes."""
    return await jobs.run_job(job, args)


@mcp.tool()
@audited
async def job_status(request_id: str = "") -> str:
    """Status of a voice job: waiting for approval, running, done (with its
    one-sentence result), or failed (with why). Read-only. Omit request_id
    for the most recent job."""
    return await jobs.job_status(request_id)


@mcp.tool()
@audited
async def recent_logs(container: str, minutes: int = 30, contains: str = "") -> str:
    """Recent log lines from one hub container, for debugging (e.g. "authentik"
    for login problems, "traefik", "todo-app", "home-mcp", or a preview
    container like "todo-app-pr7-app-1"). Optional `contains` filters to lines
    with that text (case-insensitive); `minutes` looks back up to 24 hours.
    Read-only; secrets are redacted and at most 40 lines come back. Summarize
    what the lines show rather than reading them out verbatim."""
    return await logs.recent_logs(container, minutes, contains)


# --- Hub visibility (Milestone 21). All read-only.


@mcp.tool()
@audited
async def containers(detail: bool = False) -> str:
    """Every container on the hub from cAdvisor: how many, total memory
    against the hub's RAM, which started in the last hour (did a deploy
    restart anything?), kernel OOM kills in 24 hours, and any above 80% of
    its memory limit. detail=true adds one line per container (memory vs
    limit, CPU, uptime). Read-only."""
    return await hub_view.containers(detail)


@mcp.tool()
@audited
async def scrape_targets(detail: bool = False) -> str:
    """Prometheus scrape health: how many targets are up, and for each one
    that's down its job, instance and last scrape error (Rambles targets are
    marked expected while the site is closed, November to April).
    detail=true adds up/total per job. Read-only. Use to check a new
    exporter or scrape job is working."""
    return await hub_view.scrape_targets(detail)


@mcp.tool()
@audited
async def last_deploys(repo: str = "") -> str:
    """What the latest deploys did, from each run's result line: the hub
    stack (Compose version, what restarted, anything not running) or the
    NUCs, the last Terraform apply ("Apply complete! Resources: ..."), and
    the todo-app and hue CD deploys. Optional repo ("platform repo",
    "todo-app", "hue"). Read-only."""
    return await deploys.last_deploys(repo)


# --- Security and update visibility (Milestone 19, ADR-0024). All read-only.


@mcp.tool()
@audited
async def update_status(detail: bool = False) -> str:
    """What's out of date across the platform: pending OS updates and reboots
    on the hub and NUCs, OS end-of-life dates, RouterOS/RouterBOOT on the
    MikroTiks, DSM on the NAS, legacy switch firmware, and container images
    pinned in the compose files that have newer releases. Read-only. Leads
    with what's worth doing soon; pass detail=true for the full list
    (including every image that's behind). Use for "anything need updating?"."""
    return await updates.update_status(detail)


@mcp.tool()
@audited
async def security_events(days: int = 7) -> str:
    """A week (or up to 30 days) of security-relevant activity as counts:
    failed SSH and device logins, fail2ban bans, router config changes,
    home-mcp calls (by whom, rejected tokens, coding tasks and jobs started),
    and failed/refused web requests per app with the busiest sources.
    Read-only, aggregates only. Use for "anything odd this week?"."""
    return await security_events_mod.security_events(days)


@mcp.tool()
@audited
async def github_security(repo: str = "", detail: bool = False) -> str:
    """Open GitHub security alerts per repo (vulnerable dependencies,
    committed secrets, code-scanning findings) and whether each repo's main
    branch still has its protection rules. Read-only. Omit `repo` for all
    three (todo-app, hue, platform repo). detail=true names every finding:
    the CodeQL rule and file:line, or the package, manifest and fixed
    version (secret values are never shown)."""
    return await github_security_mod.github_security(repo, detail)


@mcp.tool()
@audited
async def aws_posture() -> str:
    """AWS account security: GuardDuty threat findings, IAM Access Analyzer
    (anything shared outside the account), security groups open to the
    internet beyond the expected hub ports, root or no-MFA console sign-ins
    this week, and old IAM access keys. Read-only."""
    return await aws_posture_mod.aws_posture()


@mcp.tool()
@audited
async def authentik_audit() -> str:
    """Authentik (the login system for every app): active users, who's an
    admin, anyone without MFA, failed logins and suspicious requests this
    week with their sources, successful logins per user, and changes to
    users, groups, tokens or apps. Read-only."""
    return await authentik_audit_mod.authentik_audit()


@mcp.tool()
@audited
async def exposure_check() -> str:
    """What the internet can reach: the latest weekly port scan of the hub
    and both sites' public IPs (anything open that isn't expected), plus
    TLS certificate expiry for every public hostname. Read-only. To rescan
    now, use run_job("exposure-check-now")."""
    return await exposure.exposure_check()


@mcp.tool()
@audited
async def security_summary() -> str:
    """One line each from every security check -- updates, a week of events,
    GitHub alerts, AWS, Authentik, and internet exposure -- for "how's
    security?". Read-only. Follow up with the individual tool for detail."""
    names = ["Updates", "Events", "GitHub", "AWS", "Authentik", "Exposure"]
    results = await asyncio.gather(
        updates.update_status(False),
        security_events_mod.security_events(7),
        github_security_mod.github_security(""),
        aws_posture_mod.aws_posture(),
        authentik_audit_mod.authentik_audit(),
        exposure.exposure_check(),
        return_exceptions=True,
    )
    lines = []
    for name, res in zip(names, results):
        if isinstance(res, Exception):
            lines.append(f"{name}: couldn't check ({type(res).__name__}).")
        else:
            lines.append(f"{name}: {res.splitlines()[0]}")
    return "\n".join(lines)


@mcp.custom_route("/health", methods=["GET"])
async def health(_: Request) -> JSONResponse:
    return JSONResponse({"ok": True})


app = mcp.streamable_http_app(
    streamable_http_path="/mcp",
    transport_security=TransportSecuritySettings(
        enable_dns_rebinding_protection=True,
        allowed_hosts=["mcp.billandjessie.com", "home-mcp:8000", "localhost:8000"],
        allowed_origins=["https://claude.ai"],
    ),
)

if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=8000, proxy_headers=True, forwarded_allow_ips="*")
