# ADR-0016: Self-Hosted Postgres for App Data, Not RDS or Aurora

Date: 2026-07-17
Status: Accepted

## Context

The app platform (TODO app, Hue controller, dashboards, Authentik itself) needs a shared relational database. AWS offers managed options (RDS, Aurora) alongside the option of running Postgres in a container on the hub, consistent with how every other stateful service on the hub already runs (Prometheus, Loki, Grafana, Uptime Kuma).

## Options Considered

**Option A: Amazon Aurora (Postgres-compatible)**
- Built for a scale problem this platform doesn't have: fast failover, storage auto-scaling to 128TB, read replica fan-out, multi-region
- Even Aurora Serverless v2 has a minimum capacity floor that costs more per month than a household TODO app and Hue controller need
- Rejected outright — not a close call at this scale

**Option B: Amazon RDS (Postgres)**
- Managed backups (point-in-time recovery), automated minor-version patching, decouples DB lifecycle from the hub instance
- Real recurring cost even at the smallest size (`db.t4g.micro`, ~$12-15/mo compute alone, plus storage) — pure overhead on top of the EC2 instance already being paid for
- Its main value (managed backup/failover) is achievable much more cheaply for this workload's actual durability needs

**Option C: Self-hosted Postgres in Docker on the hub**
- No new recurring AWS bill — runs in the same `compose/aws/` stack as everything else
- Matches this platform's established pattern exactly (ADR-0003: Compose over Kubernetes; ADR-0005: SSM for secrets) — one more container, not one more AWS service to learn and pay for
- Durability addressed cheaply: EBS snapshots (a few cents/GB-month, via AWS Backup or a scheduled job) plus `pg_dump` to S3 for logical backups independent of the EBS layer
- Monitoring is free: `postgres_exporter` feeds the Prometheus/Grafana stack that already exists
- Single point of failure on one EC2 instance — but so is everything else on this hub today; this doesn't change the platform's overall failure-domain shape

## Decision

Self-hosted Postgres, one shared instance, running as a container on the AWS hub. Each app (and Authentik itself) gets its own logical database and least-privilege credentials within that instance, following the same per-service SSM namespacing convention as ADR-0005.

Backups: EBS snapshots for the volume, plus `pg_dump` to the existing `portal`/`logs` S3 bucket family on a schedule, for logical, engine-independent recovery. Monitored via `postgres_exporter` into the existing Grafana stack.

This decision is explicitly revisitable: if a commercial app later needs a real uptime SLA, or the self-hosted instance becomes an operational burden, RDS is the natural upgrade path — the data model doesn't change, only who manages the engine.

## Consequences

- One more service in `compose/aws/docker-compose.yml`, alongside Prometheus/Loki/Grafana/Uptime Kuma
- New SSM parameters for the Postgres admin credential and each app's per-database credential, under `/home-platform/postgres/*`
- Backup/restore procedure needs to be written and tested before any app holds data that isn't reproducible from Git — this should happen before or alongside the TODO app pilot, not after
- No managed failover — a hub outage takes the database down with everything else already running there
