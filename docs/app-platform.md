# App Platform Contract

This is the interface between an app repo and this platform repo (`nyc_pa_aws_gitops`). Every app repo's README should link here instead of re-explaining platform mechanics (ADR-0014). If something here turns out wrong or incomplete once a real app is onboarded, fix it here — an app repo should never need to reverse-engineer platform behavior by reading this repo's Terraform or Compose files directly.

## What lives where

- **This repo**: network, Terraform, shared services (Postgres, Redis, Authentik, Traefik, the observability stack), and this doc.
- **App repo**: application code, its own Dockerfile (with `lint` and `test` build stages ahead of its final runtime stage — see "CI/CD and deploy" below), its own CI/CD workflow (calling the reusable workflows described below), its own deploy-time Compose fragment at `deploy/docker-compose.yml`, and app-specific tests.

An app repo never edits this repo's Terraform or the hub stack's Compose files (`compose/aws/`) directly. A platform-side change (new shared service, new IAM role, a network change) lands here first; app repos then adopt it.

## Compute placement (ADR-0015)

Default: the AWS hub (`10.0.3.1`). Every app in scope today (TODO app, dashboards, Hue's central UI/API) runs there.

A NUC (`nuc4` in NYC, `nuc5` in Rambles) is only used when an app has a hard local-latency requirement — currently just the Hue automation agent's per-site color-transition logic. This is a per-app exception earned by a real constraint, not a default; if your app thinks it needs NUC placement, that's a decision for this doc/an ADR update, not something to decide silently inside the app repo.

## Database (ADR-0016)

One shared Postgres instance on the hub. Each app gets its own logical database and a least-privilege role — never the shared admin credential (`/home-platform/postgres/admin-password`).

**Onboarding a new app's database** is automatic since 2026-10-03 (ADR-0028): set `database: true` on the app's entry in `apps/registry.yml`. Merging that runs `scripts/hub/onboard-app-dbs.sh` from `platform-deploy.yml` (behind `production` approval, after the hub stack), which for each such app makes sure that:

1. `/home-platform/postgres/<app>-password` exists in SSM — generated if absent, never overwritten
2. a `LOGIN` role named `<app>` exists (`NOSUPERUSER NOCREATEDB NOCREATEROLE`) — an existing role's password is only set when SSM had none
3. a database named `<app>` exists, owned by that role
4. the database's `public` schema is owned by the role — **required** on Postgres 15+: database privileges alone no longer let a non-owner `CREATE TABLE` in `public` (docs/gotchas.md; hit for real onboarding `todo-app`)
5. the app can actually log in with the SSM password over TCP and `CREATE TABLE`/`DROP TABLE` — if the password doesn't log in, the run fails and changes nothing

It never drops a database or role; removing an app stays manual. Run it by hand from the Actions tab (`Platform deploy`, target `app-dbs`). Its `RESULT` line (read back by home-mcp's `last_deploys`) lists what was unchanged, what it changed, and anything that failed.

The app connects to `postgres:5432` by Docker network hostname (see "Networking" below), user and database `<app>`, `sslmode=disable` — matches the existing internal-only pattern (`postgres-exporter`, Authentik); the instance is never exposed beyond WireGuard peers. `app-deploy.sh` injects the password as `POSTGRES_PASSWORD`.

**Schema changes after initial onboarding:** apps built from the Python template (since 2026-10-03) use **Alembic**: a model change ships with a migration in `migrations/versions/`, the container runs `alembic upgrade head` on start, and the template's `tests/test_migrations.py` fails CI if models and migrations disagree (see `templates/python/README.md`). **todo-app and hue predate this** and still use SQLAlchemy's `create_all()`, which only creates missing tables and never alters existing ones. For them a schema change is still a manual `ALTER TABLE` applied before or with the deploy. Hit for real adding todo-app's `category_id` column (2026-08-15): the new `categories` table appeared on its own, the existing `todos` table didn't get the column, and `/api/todos` 500'd in production until it was patched by hand. Moving either app to Alembic means adding a baseline migration that matches its current schema and stamping the live database with it (`alembic stamp head`) before the first real migration.

## Auth (ADR-0017)

Authentik at `auth.billandjessie.com` is the shared OIDC provider. Two integration patterns — pick based on what the app supports:

**Pattern A — native OIDC (preferred).** The app implements a standard OIDC relying-party flow (authorization code, not implicit) and Authentik issues tokens directly.

1. A new blueprint, `compose/aws/authentik/blueprints/<app>-oidc.yaml`, declares an OAuth2 Provider + Application — same shape as `grafana-oidc.yaml`, GitOps-managed rather than clicked through the admin UI.
2. Client ID/secret generated, stored in SSM at `/home-platform/authentik/<app>-client-id` / `<app>-client-secret`.
3. Redirect URI: `https://<app>.billandjessie.com/<the app's own OIDC callback path>`, `matching_mode: strict`.
4. The app reads `AUTHENTIK_<APP>_CLIENT_ID` / `_CLIENT_SECRET` from its environment, populated at deploy time from SSM (same mechanism `deploy-aws-stack.ps1` already uses for Grafana's OIDC client).

**Pattern B — forward-auth gate.** For an app with no OIDC support at all — same shape as Uptime Kuma's `kuma-proxy.yaml` blueprint + the `authentik-forward-auth` Traefik middleware already defined on the `traefik` service. Coarser than Pattern A (all-or-nothing access; the app only sees identity if it reads the forwarded `X-authentik-*` headers) — only use it when Pattern A genuinely isn't possible.

## Service-to-service communication (ADR-0020)

For one app's backend calling another app's backend directly — not a browser calling either of them, that's still the "Ingress and DNS" section below.

- **Protocol**: gRPC. Every app template built from here forward exposes a gRPC server for its service API, in addition to its HTTP/JSON surface — the two aren't alternatives, they cover different callers (browser vs. another service).
- **Port**: 9090, by convention, alongside the app's HTTP port (conventionally 8000). Document both in the app's `deploy/docker-compose.yml`.
- **Networking**: internal-only, on the shared `home-platform` Docker network, reachable by other containers by hostname — same trust boundary as Postgres/Redis. Never a Traefik route, never published to the internet, no TLS at this hop (the Docker network boundary is the security boundary here, same as Postgres's `sslmode=disable` internal-only pattern above).
- **Proto ownership**: each app's `.proto` files live in its own repo under `proto/`, per ADR-0014 — not centralized here. If a second app ever needs to consume another app's contract, that's a call for a future ADR, not something to solve speculatively for one participant.
- **Health checks**: gRPC services implement the standard `grpc.health.v1.Health` service rather than relying on the HTTP `/health` route — a gRPC-only caller shouldn't need to speak HTTP just to check liveness.

The Python and React templates don't have a gRPC server yet — they have no current gRPC caller, and adding one speculatively would be the exact mistake ADR-0020 explicitly avoided when it rejected a message queue for the same reason. Add it to a template when a real caller needs to reach it.

External or browser-facing gRPC (grpc-web, or a consumer outside the Docker network) isn't supported yet — no current app needs it. See ADR-0020 for why that's deliberate, not an oversight.

## Ingress and DNS (ADR-0018)

Every app gets its own subdomain, `<app>.billandjessie.com`. Unlike Traefik routing (label-driven, no per-app repo PR needed here), **DNS is not a wildcard** — `grafana.`/`status.`/`auth.` are each an explicit `aws_route53_record` in `terraform/aws/tls.tf` pointing at the hub's Elastic IP. A new app needs the same: one more `aws_route53_record` resource added here, following that exact pattern. This is a small, one-time platform-side Terraform change per app, not something the app repo can do itself.

The app's own deploy-time Compose fragment carries its Traefik routing labels:

```yaml
labels:
  - "traefik.enable=true"
  - "traefik.http.routers.<app>.rule=Host(`<app>.billandjessie.com`)"
  - "traefik.http.routers.<app>.entrypoints=websecure"
  - "traefik.http.routers.<app>.tls.certresolver=route53"
  - "traefik.http.routers.<app>.middlewares=hsts@docker"
  - "traefik.http.services.<app>.loadbalancer.server.port=<the app's container port>"
```

Append `,authentik-forward-auth@docker` to the `middlewares` line only if using Pattern B auth above.

## Secrets (ADR-0005)

Every credential an app needs lives in SSM under `/home-platform/<app-or-service>/*`, following the convention already documented in this repo's `CLAUDE.md`. An app never hardcodes a secret in its own repo, in a committed `.env`, or as a GitHub Actions secret.

At deploy time, the **hub's own instance role** — not the GitHub Actions workflow, not S3 — reads an app's secrets and writes them to a `.env` file next to its Compose fragment on the hub, by convention:
- every parameter under `/home-platform/<app>/*` becomes an env var named from its last path segment (`.../session-secret` → `SESSION_SECRET`)
- `/home-platform/postgres/<app>-password` → `POSTGRES_PASSWORD` (if present)
- `/home-platform/authentik/<app>-client-id` → `AUTHENTIK_CLIENT_ID` (if present)
- `/home-platform/authentik/<app>-client-secret` → `AUTHENTIK_CLIENT_SECRET` (if present)

The app's Compose fragment references these via `env_file: .env`. Secrets never pass through the GitHub Actions workflow, its logs, or S3 — see "CI/CD and deploy" below for exactly where this runs.

## Networking

Traefik's Docker provider only discovers containers reachable on the same Docker network, and an app needs to reach `postgres`/`redis` by hostname the same way. **This requires one platform-side change before the first app can deploy**: `compose/aws/docker-compose.yml` needs an explicit external network (e.g. `home-platform`) that all of its services join, replacing the implicit default network Compose creates today. That's a one-time migration — every existing container recreates when it lands — so it's deliberately not done speculatively in this pass; it happens once, alongside the first real app deploy, not ahead of time.

Until that network exists, an app's own Compose fragment should declare it as `external: true` and expect that one-time platform migration as a prerequisite to its first deploy.

## CI/CD and deploy (ADR-0019)

**Registry**: AWS ECR, one repository per app. Each app gets its own IAM role in `terraform/aws/apps.tf` — OIDC trust scoped to that repo's `main` branch and `production` environment (ADR-0025; pull requests get a separate `<app>-github-preview` role) and that app's own ECR repo ARN, following the exact least-privilege pattern the `github_actions` role already uses. An app's role never gets access to this platform's own resources: not other apps' ECR repos, not Terraform state, no SSM parameters at all (the hub reads the app's secrets itself), and on the hub it can run only its own fixed `<app>-deploy` SSM document, not arbitrary commands.

**Reusable workflows** (this repo, `workflow_call`, invoked from each app repo's own thin `.github/workflows/*.yml`):

- **`app-ci.yml`** — every PR, required check: build, test, lint. Language-agnostic by convention: every app's Dockerfile defines `lint` and `test` build stages ahead of its final runtime stage, so this workflow just runs `docker build --target lint`, `--target test`, then a plain build — no per-language tooling lives here.
- **`app-build-push.yml`** — on merge to main: builds the final Dockerfile stage, tags it `<git-sha>` and `latest`, pushes both to the app's ECR repo via its own OIDC role. This job alone *is* manual-promote mode.
- **`app-deploy.yml`** — the actual deploy: stages the app's Compose fragment (default path `deploy/docker-compose.yml` in the app repo) to the shared `home-platform-ansible-deploy-<account>` S3 bucket under `apps/<app>/` (reusing the bucket the RouterOS/NUC pipeline already established, not a new one), then triggers the hub via `ssm:SendCommand` — hosted runners can't reach the hub directly (security group restricted to WireGuard subnets), same constraint and same fix as `routeros.yml`. The hub-side script (`scripts/hub/app-deploy.sh`, fixed in the `<app>-deploy` SSM document by `terraform/aws/ci-roles.tf`) pulls the Compose file and the new image, builds the app's `.env` from SSM (see "Secrets" above), checks that every service has a memory limit, and runs `docker compose pull && docker compose up -d`.

**Memory limits (ADR-0026)**: every service in an app's Compose fragment must set `mem_limit` (or `deploy.resources.limits.memory`). `scripts/hub/compose-mem-check.py` enforces it twice: in `app-deploy.yml` on the runner, so the app's own run fails early with the offending service names, and on the hub in `app-deploy.sh`, which is the real gate — a rejected fragment never replaces the running one. Size it from Grafana's **Containers** dashboard: the sizing table's peak over 7 days plus ~30% (its "Suggested limit" column). The starter templates begin at `256m`; previews are fixed at `384m` regardless (ADR-0023).

An app repo composes these itself to pick its mode: call `app-build-push.yml` then immediately `app-deploy.yml` for **auto-deploy**, or call `app-build-push.yml` on merge and leave `app-deploy.yml` behind a separate `workflow_dispatch` trigger for **manual-promote**.

**Environment**: production only — no staging tier, per Bill's explicit call in ADR-0019. Since 2026-10-01, opted-in apps also get **per-PR previews** (ADR-0023): a thin `preview.yml` (workflow name `Preview`) calling `app-preview.yml` on `pull_request`, which deploys each same-repo PR automatically to `<app>-pr<n>.preview.billandjessie.com` behind forward-auth, with a copy of the app's database and no production secrets, and removes it on close. Opting in needs: the app runs (open) without its Authentik secrets, `preview: true` on the app's entry in `apps/registry.yml`, which gives it its own `<app>-github-preview` role and `<app>-preview` ECR repo (ADR-0025, ADR-0028), and the caller granting `id-token: write`, `contents: read`, `pull-requests: write`.

## Scheduled pipelines: Airflow (ADR-0027, ADR-0031)

A shared Airflow 3 on the hub (`compose/aws/data.yml`), UI at `https://airflow.billandjessie.com` behind Authentik. It's for data pipelines: dependencies, retries, backfills, per-run history. Platform operations stay as GitHub Actions schedules and voice jobs.

- **DAG folders**: `/home/ec2-user/airflow/dags/<project>/` on the hub, mounted read-only. `dags/platform/` comes from this repo (`compose/aws/airflow/dags/platform/`) and holds only platform health DAGs; each app's DAGs go in `dags/<app>/`, delivered by the app's own deploy (below).
- **DAG ids**: the app's name with underscores, then `__`, then the DAG (`mkt_data__sifma_calendar`). Lowercase, no dots. The metrics mapping (`compose/aws/airflow/statsd-mapping.yml`) splits StatsD names on dots, so a dotted id would land in the wrong labels.
- **New DAGs start paused** (`dags_are_paused_at_creation`); unpause in the UI once it parses cleanly.
- **Concurrency**: LocalExecutor, at most 4 task processes at once across all DAGs; tasks run inside the scheduler container (1 GiB limit, ADR-0026). App tasks only make HTTP calls, so the real work's memory counts against the app's own `mem_limit`.
- **Credentials**: Airflow can't reach the hub's AWS instance role (it's on `home-platform`, behind the IMDS guard), and it never holds an app's secrets (ADR-0031). The only per-app credential it has is the app's job token.

**App pipelines (ADR-0031): DAGs orchestrate, apps do the work.** No app code runs inside Airflow and there's no Docker socket. To use it:

1. Set `airflow: true` on the app's registry entry. The next platform deploy generates the job token at `/home-platform/<app>/airflow-token` and gives the scheduler `AIRFLOW_CONN_<APP>` (`http://:<token>@<app>:8000`, in `/home/ec2-user/airflow/connections.env`, built from the registry by `deploy-hub-stack.sh`). The app's next deploy gets the same token as `AIRFLOW_TOKEN`.
2. The app exposes job endpoints under `/jobs/...` on port 8000. They require `Authorization: Bearer $AIRFLOW_TOKEN` (todo-app, hue and previews share the network), are idempotent per date or chunk (Airflow retries), and return a JSON summary. Work over ~5 minutes starts with a `POST` that returns a job ID and is polled from the DAG by a sensor in reschedule mode.
3. DAGs live in the app repo under `dags/`, standard library and Airflow imports only, and call the app with the platform helper:
   ```python
   from home_platform_jobs import call_app_job   # installed at the DAG root

   @task
   def capture():
       return call_app_job("mkt-data", "calendars/sifma/capture")
   ```
   A non-2xx answer fails the task with the app's error text.
4. Market calendars in schedules: a plain cron, with a first task that asks the app whether it's a business day and skips the run if not (`@task.short_circuit`).
5. Delivery: `app-deploy.yml` stages the repo's `dags/` (regular `.py` files only) on every deploy. After the app is up, `app-deploy.sh` checks the archive (`scripts/hub/app-dags.py`: no links, no odd paths, size limits) and syncs it into `dags/<app>/` with `--delete`. An app that drops its `dags/` has its DAGs removed. DAGs from an app without `airflow: true` aren't delivered, and the deploy's result line says so.

- **Monitoring**: StatsD → `airflow-statsd-exporter` → Prometheus job `airflow`. Grafana alerts: **Airflow heartbeat stale** (the hourly `platform_heartbeat` DAG hasn't succeeded in 2 h) and **Airflow task failed** (any task that failed after its retries, labelled with DAG and task). Container logs go to Loki like everything else; task logs are in the UI (`airflow-logs` volume).

## Starter templates

Live in this repo under `templates/<language>/`, not a separate GitHub template repository — same rationale as the reusable CI/CD workflows above (ADR-0014's "no business logic in the platform repo" is about apps, not platform-provided scaffolding). To use one: copy its contents into a new app repo and follow its own README.

- **Python** (`templates/python/`) — done. FastAPI + Uvicorn, SQLAlchemy (Postgres, ADR-0016) with Alembic migrations, a gRPC server with `grpc.health.v1` on port 9090 (ADR-0020, added 2026-10-03), Authlib (Authentik OIDC, ADR-0017 Pattern A), pytest, ruff. Dockerfile follows the `lint`/`test`/final-stage convention `app-ci.yml` expects. `deploy/docker-compose.yml` and `.github/workflows/cd.yml` wired to `app-build-push.yml` + `app-deploy.yml` (auto-deploy by default), with `REPLACE_WITH_APP_NAME` placeholders per app. Verified locally: full test suite passes, `ruff check` clean, and the app boots under real `uvicorn` with `/health`, `/`, `/db-check`, `/login` all behaving correctly with no Postgres/Authentik configured (graceful degradation, not a crash) — Docker itself wasn't available to test the multi-stage build locally, so that specific path is unverified until CI runs it for real.
- **C++** (`templates/cpp/`) — done. Clang (C++23), CMake + Ninja, vcpkg manifest mode, clang-tidy, GoogleTest. `cpp-httplib` for the HTTP surface, `libpqxx` (Postgres, ADR-0016), and a runtime-discovered Authentik OIDC authorization-code flow (ADR-0017 Pattern A, no dedicated C++ OIDC library exists the way Authlib/express-openid-connect do — see `src/oidc_client.cpp` for the reasoning, including why the id_token's signature isn't cryptographically verified for this specific flow). Also the first template to implement ADR-0020: a `grpc`/`protobuf` service (`proto/example_service.proto`) on port 9090, internal-only on the `home-platform` network, running alongside the HTTP server (port 8000) in the same process/container. Same `lint`/`test`/final-stage Dockerfile convention as the other templates. Auth gating mirrors the fix applied to `todo-app` and the Python/React templates. Verified for real, same rigor as the React template: `docker build --target lint`/`--target test`/final all built clean (6/6 tests, clang-tidy clean across all source files), and the final image ran as a real container with both the HTTP routes and the gRPC `Ping` RPC (plus the standard `grpc.health.v1.Health` service) confirmed working via `grpcurl` against the actual running container.
- **React** (`templates/react/`) — done. React + Vite frontend, Express backend (one process serves the built frontend and the API — no separate frontend server in production), `pg` (Postgres, ADR-0016), `express-openid-connect` (Authentik OIDC, ADR-0017 Pattern A), Vitest/Supertest/Testing Library, ESLint. Same `lint`/`test`/final-stage Dockerfile convention as the Python template, `deploy/docker-compose.yml` and `.github/workflows/cd.yml` wired to `app-build-push.yml` + `app-deploy.yml`, `REPLACE_WITH_APP_NAME` placeholders per app. Auth gating (everything except `/health`, `/login`, `/auth/callback` requires a session once Authentik credentials are configured, open otherwise) mirrors the fix applied to `todo-app` and the Python template — see CLAUDE.md's Gotchas if adding the equivalent to a future template. Verified for real: `docker build --target lint`/`--target test`/final all built clean, and the final image ran as a real container reachable over HTTP (`/health`, `/db-check`, `/login`, and the built frontend live-fetching from the backend all confirmed) — unlike the Python template, the multi-stage Docker build itself was verified, not left as a CI-only unknown.

## GitHub repos (ADR-0030)

`terraform/github/` creates and configures every registry app's repo: ruleset on `main` (PR with passing CI, no force-push or deletion), `production` environment with Bill as reviewer, `preview` for apps with previews, Dependabot security updates, secret scanning with push protection, GitHub's default (immutable-ID) OIDC subject, and (from the apply workflow) CodeQL default setup. New repos start with a README; the first PR brings the starter template. The platform repo itself is configured by hand.

**One-time token setup (Bill):** two fine-grained personal access tokens at github.com → Settings → Developer settings → Fine-grained tokens, each with **Repository access: All repositories** and an expiry you're happy to renew:

| Token | Repository permissions | Where it goes |
|---|---|---|
| `TF_GITHUB_ADMIN_TOKEN` | Administration: **Read and write**; Environments: **Read and write**; Actions: **Read and write** (Metadata read is automatic) | nyc_pa_aws_gitops → Settings → Environments → **production** → Environment secrets |
| `TF_GITHUB_READ_TOKEN` | Administration, Environments, Actions: **Read-only** | nyc_pa_aws_gitops → Settings → Secrets and variables → Actions → **Repository secrets** |

Both are also kept in SSM (`/home-platform/github/terraform-admin-token`, `/home-platform/github/terraform-read-token`) as the source of truth; the GitHub secrets are copies. From a workstation with the AWS CLI and gh: read the token into a variable without echoing it (PowerShell `Read-Host -AsSecureString`), then `aws ssm put-parameter --type SecureString --overwrite --name /home-platform/github/terraform-<admin|read>-token --value $t` and `gh secret set TF_GITHUB_ADMIN_TOKEN --repo bcalaway/nyc_pa_aws_gitops --env production --body $t` (or `TF_GITHUB_READ_TOKEN` without `--env`). Set up this way on 2026-10-03.

When one expires, `terraform-github.yml` fails at its "Check the … token" step or with an auth error; make a new one with the same permissions and repeat the above.

## Onboarding checklist for a new app

1. [ ] Add the app to `apps/registry.yml` (step 5 below has the fields); merging creates the GitHub repo with all its settings (ADR-0030). **Then add the new repo's `github_repo_id`** (`gh api repos/bcalaway/<app> --jq .id`) in a follow-up registry PR and approve its Terraform (AWS) apply: until it's there, the app's AWS roles refuse its OIDC subject and CD fails at "Configure AWS credentials". Then a first PR in the new repo copies in `templates/<language>/` and replaces `REPLACE_WITH_APP_NAME`
2. [ ] Platform side: `database: true` in the app's `apps/registry.yml` entry — the platform deploy creates the database, role and SSM password (see Database above)
3. [ ] Platform side: add the app's Authentik OIDC blueprint (or forward-auth middleware), store client credentials in SSM
4. [ ] Platform side: add the app's `aws_route53_record` in `terraform/aws/tls.tf`
5. [ ] Platform side: add the app to `apps/registry.yml` (ADR-0028) — name, `github_repo_id` (once the repo exists; step 1), `database`, `authentik`, `preview`, any `extra_ecr_repos`. Terraform builds the rest from it: ECR repo, `<app>-github-actions` role (trusts `main` + `production` only), `<app>-deploy` document, the hub role's ECR-pull/SSM-read grants and the CI role's ARNs. Check the PR's plan only adds that app's resources, merge, approve
6. [ ] Platform side (first app only): migrate `compose/aws/docker-compose.yml` onto the shared external Docker network
7. [ ] App repo: Dockerfile with `lint`/`test`/runtime stages, Traefik labels on its `deploy/docker-compose.yml`
8. [ ] App repo: `mem_limit` on every service in `deploy/docker-compose.yml` (the deploy rejects a fragment without one, ADR-0026); start from the template's `256m`, then resize from the Containers dashboard after a week
9. [ ] App repo: thin workflow(s) calling `app-ci.yml` on PR, `app-build-push.yml` + `app-deploy.yml` on merge (chained for auto-deploy, or `app-deploy.yml` behind `workflow_dispatch` for manual-promote)
10. [ ] Verify end-to-end: PR merges → image lands in ECR → app deploys → reachable at `https://<app>.billandjessie.com` → auth flow (Pattern A or B) actually gates access
