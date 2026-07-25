import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Settings:
    # APP_NAME must match this app's ECR repo / IAM role name / Postgres
    # database name / Route53 subdomain -- one name ties the whole platform
    # integration together, see docs/app-platform.md in nyc_pa_aws_gitops.
    app_name: str = os.environ.get("APP_NAME", "app")

    # SESSION_SECRET should come from SSM (/home-platform/<app>/session-secret)
    # once deployed -- the default here is only for local dev/tests, never
    # use it in production.
    session_secret: str = os.environ.get("SESSION_SECRET", "dev-insecure-secret-change-me")

    # Postgres (ADR-0016). POSTGRES_PASSWORD arrives via the platform's
    # deploy-time .env convention -- unset locally means db-dependent
    # features degrade gracefully instead of crashing (see app/db.py).
    postgres_host: str = os.environ.get("POSTGRES_HOST", "postgres")
    postgres_password: str | None = os.environ.get("POSTGRES_PASSWORD")

    # Authentik OIDC (ADR-0017, Pattern A). Both unset means auth routes
    # respond 501 instead of crashing -- lets this template run standalone
    # before an app is actually onboarded to Authentik.
    authentik_base_url: str = os.environ.get("AUTHENTIK_BASE_URL", "https://auth.billandjessie.com")
    authentik_client_id: str | None = os.environ.get("AUTHENTIK_CLIENT_ID")
    authentik_client_secret: str | None = os.environ.get("AUTHENTIK_CLIENT_SECRET")


settings = Settings()
