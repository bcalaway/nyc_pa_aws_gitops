from authlib.integrations.starlette_client import OAuth
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, RedirectResponse
from starlette.middleware.sessions import SessionMiddleware

from app.config import settings
from app.db import check_connection

app = FastAPI(title=settings.app_name)
app.add_middleware(SessionMiddleware, secret_key=settings.session_secret)

# Registered only when real credentials are present (post-onboarding, see
# docs/app-platform.md's Auth section in nyc_pa_aws_gitops) -- the
# discovery URL matches Authentik's per-application OIDC endpoint,
# https://auth.billandjessie.com/application/o/<app-slug>/.well-known/openid-configuration.
oauth = OAuth()
_auth_configured = bool(settings.authentik_client_id and settings.authentik_client_secret)
if _auth_configured:
    oauth.register(
        name="authentik",
        client_id=settings.authentik_client_id,
        client_secret=settings.authentik_client_secret,
        server_metadata_url=(
            f"{settings.authentik_base_url}/application/o/{settings.app_name}/"
            ".well-known/openid-configuration"
        ),
        client_kwargs={"scope": "openid profile email"},
    )


@app.get("/health")
def health():
    return {"status": "ok"}


@app.get("/")
def root():
    return {"app": settings.app_name, "status": "running"}


@app.get("/db-check")
def db_check():
    return {"connected": check_connection()}


@app.get("/login")
async def login(request: Request):
    if not _auth_configured:
        return JSONResponse({"error": "auth not configured"}, status_code=501)
    redirect_uri = str(request.url_for("auth_callback"))
    return await oauth.authentik.authorize_redirect(request, redirect_uri)


@app.get("/auth/callback")
async def auth_callback(request: Request):
    if not _auth_configured:
        return JSONResponse({"error": "auth not configured"}, status_code=501)
    token = await oauth.authentik.authorize_access_token(request)
    request.session["user"] = token.get("userinfo")
    return RedirectResponse(url="/")
