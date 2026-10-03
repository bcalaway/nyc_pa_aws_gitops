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
- **Task isolation:** app code runs in the app's own image (DockerOperator or KubernetesPodOperator-style isolation via Docker), so apps don't share Python dependencies with Airflow or each other.
- **Memory:** limits per ADR-0026, sized after measurement.
- **Observability:** Airflow StatsD/metrics into Prometheus, logs into Loki, task-failure alerts through Grafana.

Existing GitHub Actions schedules and voice jobs stay as they are. Airflow is for data pipelines, not platform operations.

## Consequences

- One more shared service to upgrade and back up (its metadata DB is covered by the existing Postgres backups).
- DAG delivery is a new mechanism; its exact shape (image vs. bundle, how the deploy document places it) is settled when mkt-data onboards, and recorded in `docs/app-platform.md`.
- DockerOperator needs access to the Docker socket from the Airflow worker. That is a privileged mount and must be scoped carefully, consistent with the IMDS guard and ADR-0025's hardening. If that can't be made safe, fall back to running app tasks as Python in a pinned, per-app virtualenv.
- Requires ADR-0026's resize first.
