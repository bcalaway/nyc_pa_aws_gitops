# ADR-0031: How App Pipelines Run on the Shared Airflow

Date: 2026-10-03
Status: Accepted (2026-10-03, Bill)

## Context

ADR-0027 made Airflow a shared hub service. It left three questions for the first app, mkt-data (Milestone 22):

1. **Where task code runs.** ADR-0027 assumed DockerOperator, so app code runs in the app's own image. Its Consequences already flagged the catch: that needs the Docker socket.
2. **How an app's DAGs reach `dags/<app>/`** without this repo containing app DAGs.
3. **How an app's secrets reach its tasks.**

Constraints already in place:

- Airflow is on the `home-platform` network only, so the IMDS guard keeps it off the hub role's credentials (ADR-0024).
- Its containers hold the Airflow database password and the Fernet key that decrypts every Airflow connection.
- `parallelism` is 4 on a 7.6 GB hub.
- App deploys happen only after Bill approves `production` (ADR-0025).
- Bill wants the security master and quotes delivered as services. The main data flow stays inside mkt-data.

## Options Considered

**A. DockerOperator with the Docker socket**
- Each task runs in the app's image, with its own dependencies.
- The socket is root on the hub. Whoever can create a container can mount `/`, and can attach the container to the stack's default network to reach IMDS and the hub role. Socket proxies filter by API endpoint, not by request body, so "create container" can't be made safe. Every Airflow container, and any dependency inside it, would effectively be the hub's root.

**B. App code as Python inside Airflow (per-app virtualenv or PythonVirtualenvOperator)**
- No socket needed, and nothing new to run.
- App code runs next to the Airflow database password and the Fernet key, so any app could read every other app's connections. App dependencies have to install into, or alongside, Airflow's image. Every new package becomes an Airflow image rebuild.

**C. DAGs orchestrate, apps do the work (chosen)**
- A DAG task is a call to the app's own internal HTTP API on `home-platform`, for example `POST http://mkt-data:8000/jobs/calendars/sifma/capture`. The app runs the job in its own container with its own image, dependencies, database credentials and memory limit, and returns a JSON summary.
- Airflow keeps what it's good at: schedules, dependencies, retries, backfills over date ranges, run history and the UI. It never holds an app's secrets or runs an app's code.
- Fits Bill's microservices leaning: each app owns its work behind an API.
- HTTP, not gRPC (ADR-0020): Airflow's HTTP tooling (operators, sensors, connections) is first-class, while gRPC from Airflow would need generated stubs inside the Airflow image. gRPC stays the choice for app-to-app calls.
- Costs:
  - Every job is an endpoint in the app.
  - Task logs in Airflow are the call and its summary. The detail is in the app's logs, in Loki.
  - Long jobs need a start-then-poll pattern instead of one long HTTP call.

**D. KubernetesPodOperator or ECS tasks**
- Proper isolation, but not on this platform: ADR-0026 kept Docker Compose and ruled out ECS/EKS.

## Decision

Option C.

**Tasks.**
- App DAGs only make HTTP calls to their own app. Use the HTTP provider's `HttpOperator` if the Airflow image includes it, otherwise a small stdlib helper shipped in `dags/platform/`.
- Jobs that finish in under about 5 minutes are one synchronous call with a timeout.
- Longer jobs (large backfills) start with `POST` (which returns a job ID) and are polled by a sensor in reschedule mode, so a waiting task doesn't hold one of the 4 slots.
- Backfills are split into date chunks so retries are cheap.
- Each app endpoint is idempotent for a given date or chunk, because Airflow retries.

**Calendars in schedules.** DAGs run on a plain cron. Their first task asks the app whether the date is a business day for the relevant market, and skips the run if not (a short-circuit). No custom timetable plugin is needed in the shared Airflow.

**DAG delivery.**
- DAGs live in the app repo under `dags/`.
- The app's CD stages `dags/` next to its Compose file (S3 `apps/<app>/`).
- `app-deploy.sh` on the hub rsyncs it into `/home/ec2-user/airflow/dags/<app>/` with `--delete`, after the app container is up.
- DAGs and the endpoints they call therefore ship together, only after Bill's approval, and Airflow picks them up on its next DAG scan.
- Rules:
  - DAG IDs start with the app name (`mkt_data__…`).
  - DAG files import only Airflow and the standard library.
  - New DAGs start paused (already the platform default).
- This repo still never contains app DAGs.

**Secrets.**
- An app's secrets stay with the app (`/home-platform/<app>/*`, delivered by its own deploy as today).
- Airflow gets one thing per app: a shared token that the app requires on its `/jobs/*` endpoints.
  - It lives in SSM at `/home-platform/<app>/airflow-token`, generated once by the platform deploy.
  - The app receives it as `AIRFLOW_TOKEN` through the existing "everything under `/home-platform/<app>/`" rule.
  - Airflow receives it as an `AIRFLOW_CONN_<APP>` environment variable written by `deploy-hub-stack.sh`.
- The token matters because todo-app, hue and their previews are on the same `home-platform` network and could otherwise reach mkt-data's job endpoints.

**Registry.**
- A new `airflow: true` field on an app turns all of this on: token generation, the Airflow connection, the hub role's SSM grant, and DAG delivery in `app-deploy.sh`.
- Adding an Airflow app changes Airflow's environment, so the next hub deploy recreates the Airflow containers. Tasks running at that moment are retried.

**Memory.** Job work counts against the app's `mem_limit`, not Airflow's. mkt-data starts at 256m and is raised when backfills need it, sized from the Containers dashboard (ADR-0026).

*Implementation note (2026-10-03):*

- The helper is `compose/aws/airflow/dags/home_platform_jobs.py` (`call_app_job`), installed at the DAG root and listed in `.airflowignore`. It reads `AIRFLOW_CONN_<APP>` from the environment instead of Airflow's connection API, so it depends only on the standard library.
- `AIRFLOW_CONN_<APP>` lines go in `/home/ec2-user/airflow/connections.env`, the scheduler's optional `env_file`. Optional `env_file` needs Compose ≥ 2.24, which the hub deploy now checks.
- A registry change now also redeploys the hub stack, so a new `airflow: true` app gets its connection without a separate run. The scheduler is recreated only when that file changes.
- DAG archives are checked by `scripts/hub/app-dags.py`, which is bundled into each `<app>-deploy` SSM document.

## Consequences

- No Docker socket anywhere in Airflow. App code never runs with Airflow's credentials, and Airflow never holds app database passwords or API keys.
- Apps grow a small `/jobs` API. The Python template gets a pattern for it: token check, idempotent handlers, JSON summary, and a job table for start-then-poll. It's added with mkt-data's first job and then backported to `templates/python`.
- DAG files are still code run by Airflow's DAG processor, which has Airflow's credentials. That's acceptable while every app repo is Bill's and every deploy is approved. A future app from an untrusted source would need a separate Airflow or a DAG review gate.
- Debugging a job means two places: Airflow for the schedule and retries, and the app's logs in Loki for the work. Grafana's Airflow alerts (`airflow-task-failed`) still fire on failed calls.
- Supersedes ADR-0027's "Task isolation" bullet (DockerOperator), and settles its "DAG delivery" and "Secrets" bullets.
