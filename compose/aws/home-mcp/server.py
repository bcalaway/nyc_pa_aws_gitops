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

import status
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
    public apps, and AWS spend this month. Read-only. Use for "how's everything?"."""
    return await status.platform_status()


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
