# Python App Starter Template

Starter template for a Python app on the home platform. Pre-wired with CI/CD, a Dockerfile, and the Postgres/Authentik/Traefik integration points from the [platform contract](../../docs/app-platform.md) — see that doc for what each piece means and how onboarding actually works. This template doesn't re-explain platform mechanics; it just implements them.

## Stack

FastAPI + Uvicorn, SQLAlchemy (Postgres) with Alembic migrations, gRPC (grpcio, with the standard health service), Authlib (Authentik OIDC), pytest, ruff.

Two servers, one process: HTTP on port 8000 (browser-facing, routed by Traefik) and gRPC on port 9090 (service-to-service, internal to the `home-platform` network only, ADR-0020). The gRPC server starts from the FastAPI lifespan in `app/main.py`.

## Using this template

1. Copy this directory's contents into a new app repo (`github.com/bcalaway/<app-name>`).
2. Replace every `REPLACE_WITH_APP_NAME` (in `deploy/docker-compose.yml` and `.github/workflows/cd.yml`) with the app's real name — it must match the ECR repo / IAM role name from `terraform/aws/apps.tf` in `nyc_pa_aws_gitops`.
3. Set `APP_NAME` in the deploy environment to the same value (comes from SSM per the platform's secrets convention, or just hardcode it as a plain env var in `deploy/docker-compose.yml` since it's not a secret).
4. Follow the onboarding checklist in `docs/app-platform.md` (database, Authentik client, Route53 record, IAM role) — these are platform-side steps, not something this template does for you.
5. Build out `app/` into the real app. `/health`, `/`, `/db-check`, `/login`, `/auth/callback`, the `Item` model with its `0001` migration, and the `ExampleService.Ping` RPC are working examples, not requirements — replace or extend them.

## Database migrations (Alembic)

Schema changes are migrations, never hand-run SQL. The container applies them on start (`start.sh` runs `alembic upgrade head` when a database is configured), so a deploy that ships a model change also ships its migration.

1. Change `app/models.py`.
2. `alembic revision --autogenerate -m "add category to items"` (with `DATABASE_URL` or `POSTGRES_PASSWORD` set so Alembic can compare against a database), then **read and fix** the generated file in `migrations/versions/`. Autogenerate misses renames and some constraint changes.
3. Commit both. `tests/test_migrations.py` fails if the models and migrations disagree, so a forgotten migration is caught in CI.

Previews (ADR-0023) start from a copy of production's database, so they run the same pending migrations a real deploy would.

## gRPC

`proto/example_service.proto` is the API; `./gen_proto.sh` generates `app/grpc_gen/*_pb2*.py` (not committed; the Dockerfile generates them too). Edit the proto, regenerate, then implement the servicer in `app/grpc_server.py`. The server also serves `grpc.health.v1.Health`. `GRPC_PORT=0` turns gRPC off for a quick local run.

## Local development

```
pip install -r requirements.txt -r requirements-dev.txt
./gen_proto.sh
uvicorn app.main:app --reload
```

`POSTGRES_PASSWORD` / `AUTHENTIK_CLIENT_ID` / `AUTHENTIK_CLIENT_SECRET` are all optional locally — the app degrades gracefully (see `app/db.py` and the `/login` 501 behavior in `app/main.py`) rather than requiring live Postgres/Authentik to run.

## Tests and lint

```
pytest
ruff check app/ tests/
```

Both also run inside Docker via the `test` / `lint` build stages — `docker build --target test .` / `docker build --target lint .` — which is what `app-ci.yml` actually runs in CI.
