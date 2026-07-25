# Python App Starter Template

Starter template for a Python app on the home platform. Pre-wired with CI/CD, a Dockerfile, and the Postgres/Authentik/Traefik integration points from the [platform contract](../../docs/app-platform.md) — see that doc for what each piece means and how onboarding actually works. This template doesn't re-explain platform mechanics; it just implements them.

## Stack

FastAPI + Uvicorn, SQLAlchemy (Postgres), Authlib (Authentik OIDC), pytest, ruff.

## Using this template

1. Copy this directory's contents into a new app repo (`github.com/bcalaway/<app-name>`).
2. Replace every `REPLACE_WITH_APP_NAME` (in `deploy/docker-compose.yml` and `.github/workflows/cd.yml`) with the app's real name — it must match the ECR repo / IAM role name from `terraform/aws/apps.tf` in `nyc_pa_aws_gitops`.
3. Set `APP_NAME` in the deploy environment to the same value (comes from SSM per the platform's secrets convention, or just hardcode it as a plain env var in `deploy/docker-compose.yml` since it's not a secret).
4. Follow the onboarding checklist in `docs/app-platform.md` (database, Authentik client, Route53 record, IAM role) — these are platform-side steps, not something this template does for you.
5. Build out `app/` into the real app. `/health`, `/`, `/db-check`, `/login`, `/auth/callback` are working examples, not requirements — replace or extend them.

## Local development

```
pip install -r requirements.txt -r requirements-dev.txt
uvicorn app.main:app --reload
```

`POSTGRES_PASSWORD` / `AUTHENTIK_CLIENT_ID` / `AUTHENTIK_CLIENT_SECRET` are all optional locally — the app degrades gracefully (see `app/db.py` and the `/login` 501 behavior in `app/main.py`) rather than requiring live Postgres/Authentik to run.

## Tests and lint

```
pytest
ruff check app/ tests/
```

Both also run inside Docker via the `test` / `lint` build stages — `docker build --target test .` / `docker build --target lint .` — which is what `app-ci.yml` actually runs in CI.
