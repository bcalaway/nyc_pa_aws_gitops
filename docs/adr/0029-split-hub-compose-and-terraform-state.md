# ADR-0029: Split the Hub Compose File and the Terraform State

Date: 2026-10-03
Status: Proposed

## Context

The platform is staying a single repo (ADR-0014): it works well with Claude implementing through PRs and ADRs living beside the code. Two parts of it are growing in ways that will hurt:

- **`compose/aws/docker-compose.yml`** is one ~650-line file holding about 20 services: observability, ingress, auth, data stores, exporters, home-mcp. Airflow (ADR-0027) and cAdvisor (ADR-0026) add more. Reviews and diffs get harder, and every change redeploys from the same file.
- **Terraform** uses one state (`aws/terraform.tfstate`) for the VPC, EC2, IAM, Route 53, S3, CloudFront, backups and every app's CI resources. An app onboarding PR plans against the whole account, plans get slower, and a mistake in an app block shares an apply with the network.

## Options Considered

**Option A: Leave both as they are**
- Nothing to migrate; pain grows with each app

**Option B: Split the repo**
- Overkill for one owner; loses the single place where platform context lives

**Option C: Split within the repo (chosen)**
- Compose: per-group files joined with Compose `include`
- Terraform: separate root modules with separate state keys, linked by remote-state outputs

## Decision

**Compose:** `compose/aws/docker-compose.yml` becomes a short file that `include`s:

- `core.yml` — Traefik, Authentik, Postgres, Redis, home-mcp
- `observability.yml` — Prometheus, Loki, Alloy, Grafana, Uptime Kuma, exporters, cAdvisor
- `data.yml` — Airflow (ADR-0027)
- `web.yml` — Umami and other small shared web services

The networks and volumes stay defined once, in the top-level file. `platform-deploy.yml` and the deploy scripts keep deploying the whole stack; a per-group deploy can come later.

**Terraform:** split `terraform/aws/` into root modules, each with its own state key in the existing bucket and lock table (ADR-0011):

- `network` — VPC, security groups, Route 53, TLS
- `hub` — EC2, its role, backups, S3 buckets
- `ci` — GitHub OIDC provider and roles, and per-app resources from the apps registry (ADR-0028)
- `edge` — CloudFront and the portal

Resources move with `terraform state mv` / `moved {}` and `removed {}` + `import` where needed, one module per PR, each verified with a plan that shows no changes.

## Consequences

- App onboarding PRs touch only the `ci` state, so their plans are small and can't affect the network.
- `terraform.yml` must plan and apply each root module that changed, in dependency order (network → hub → ci → edge).
- The state migration is the riskiest part. It is done after ADR-0026 and ADR-0028 land, one module at a time, never in the same PR as a functional change.
- Compose `include` needs Docker Compose v2.20 or later on the hub; confirm the installed version first.
