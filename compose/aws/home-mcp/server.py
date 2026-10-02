"""home-mcp: remote MCP server for voice Claude (ADR-0021, Milestone 18).

Reached by Claude's custom connector from Anthropic's cloud at
https://mcp.billandjessie.com/mcp. Layers, outermost first: Traefik only
admits Anthropic's egress range; Authentik issues tokens only to Bill,
after an MFA step in this app's own authorization flow; this server
re-validates every token itself (auth.py). Tools are named and fixed --
there is no shell or arbitrary-command tool, by design.

Every tool call is logged as one JSON line to stdout, which the hub's
journald log driver + Promtail's journal job ship to Loki
({container="home-mcp"}), giving an audit trail for free.
"""

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

import context
import github_status as github_status_mod
import jobs
import status
import tasks
from auth import AuthentikTokenVerifier

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(name)s %(levelname)s %(message)s")
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
