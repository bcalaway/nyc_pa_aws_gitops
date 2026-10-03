# ADR-0027: Airflow as a Shared Platform Service

Date: 2026-10-03
Status: Accepted (2026-10-03)

## Context

The market data platform needs a scheduler for daily data capture, parsing, backfills and data-quality checks. Bill chose Airflow, partly because it is the industry default and this is a learning exercise.

Today the platform schedules work in two ways: GitHub Actions `schedule:` workflows (`woods-calendar.yml`, `preview-sweep.yml`) and named voice jobs (ADR-0022, `jobs/registry.yml`). Both suit occasional platform operations. Neither suits data pipelines: dependencies between tasks, retries, backfills over date ranges, per-run history and a UI to inspect them.

Other projects may want scheduled work later, so the question is whether Airflow belongs to one app or to the platform.

## Options Considered

**Option A: Airflow inside the mkt-data app**
- Simple ownership; nothing changes in this repo beyond normal app onboarding
- A second project wanting schedules would either run a second Airflow (memory, upgrades twice) or reach into mkt-data's

**Option B: Airflow as a shared platform service in `compose/aws/` (chosen)**
- One scheduler, one UI, one upgrade path; any project ships DAGs to it
- Fits the platform's pattern for shared services (Postgres, Redis, Authentik, Traefik)
- Needs a clear rule for how app repos deliver DAGs without editing this repo

**Option C: Managed Airflow (MWAA)**
- No ops, but a meaningful monthly floor for a personal platform, and outside the hub network (would need to reach Postgres over the VPC)

**Option D: Dagster or Prefect**
- Arguably better fits for asset-style data work, but not what Bill wants to learn here

## Decision

Run Airflow on the hub as a platform service:

- **Executor:** `LocalExecutor` (scheduler, webserver/API server, triggerer). No Celery or Redis queue until load requires it.
- **Metadata:** its own logical database and role in the shared Postgres (ADR-0016 onboarding steps).
- **UI:** behind Traefik at an internal hostname with Authentik forward-auth (ADR-0017/0018), never public.
- **Secrets:** Airflow's own under `/home-platform/airflow/*`; each project's connections and keys under its own `/home-platform/<app>/*`, exposed to Airflow at deploy time (ADR-0005).
- **DAG delivery:** each app repo owns its DAGs and builds them into a versioned image or bundle; its deploy stages them into a per-app DAG folder on the hub (`dags/<app>/`). This repo never contains app DAGs (ADR-0014).
- **Task isolation** *(superseded by ADR-0031: DAGs call the app's own HTTP job API instead; no Docker socket)*: app code runs in the app's own image (DockerOperator or KubernetesPodOperator-style isolation via Docker), so apps don't share Python dependencies with Airflow or each other.
- **Memory:** limits per ADR-0026, sized after measurement.
- **Observability:** Airflow StatsD/metrics into Prometheus, logs into Loki, task-failure alerts through Grafana.

Existing GitHub Actions schedules and voice jobs stay as they are. Airflow is for data pipelines, not platform operations.

*Implementation note (2026-10-03):* Airflow 3.3.2 in `compose/aws/data.yml`: scheduler (runs `db migrate` on start and the LocalExecutor's tasks; `parallelism` 4), API server, DAG processor, triggerer, plus a statsd exporter. Changes from the decision above:

- **UI**: `airflow.billandjessie.com` behind Authentik forward-auth, like Uptime Kuma, rather than internal-only. Bill's call, so it works from his phone; Airflow's own login is off (`simple_auth_manager_all_admins`) because Authentik is the gate.
- **Network**: Airflow joins only `home-platform`, like the apps, so the IMDS guard keeps it (and the app code its tasks will run) off the hub's instance-role credentials. Only the statsd exporter is on the stack's default network, for Prometheus.
- **Database**: a new `platform_databases:` list in `apps/registry.yml`, onboarded by the same script as app databases; platform-deploy.yml now runs that onboarding before the hub stack.
- **Secrets**: Fernet key, API secret and JWT secret are generated once into SSM by `deploy-hub-stack.sh`.
- **DAG delivery and DockerOperator** wait for mkt-data, as planned. Only `dags/platform/platform_heartbeat.py` ships now; it drives the "Airflow heartbeat stale" alert. There is no Docker socket mount yet.

## Consequences

- One more shared service to upgrade and back up (its metadata DB is covered by the existing Postgres backups).
- DAG delivery is a new mechanism; its exact shape (image vs. bundle, how the deploy document places it) is settled when mkt-data onboards, and recorded in `docs/app-platform.md`.
- DockerOperator needs access to the Docker socket from the Airflow worker. That is a privileged mount and must be scoped carefully, consistent with the IMDS guard and ADR-0025's hardening. If that can't be made safe, fall back to running app tasks as Python in a pinned, per-app virtualenv.
- Requires ADR-0026's resize first.
