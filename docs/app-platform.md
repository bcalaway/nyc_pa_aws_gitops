# App Platform Contract

This is the interface between an app repo and this platform repo (`nyc_pa_aws_gitops`). Every app repo's README should link here instead of re-explaining platform mechanics (ADR-0014). If something here turns out wrong or incomplete once a real app is onboarded, fix it here — an app repo should never need to reverse-engineer platform behavior by reading this repo's Terraform or Compose files directly.

## What lives where

- **This repo**: network, Terraform, shared services (Postgres, Redis, Authentik, Traefik, the observability stack), and this doc.
- **App repo**: application code, its own Dockerfile, its own CI/CD workflow (calling the reusable workflow described below), its own deploy-time Compose fragment, and app-specific tests.

An app repo never edits this repo's Terraform or `compose/aws/docker-compose.yml` directly. A platform-side change (new shared service, new IAM role, a network change) lands here first; app repos then adopt it.

## Compute placement (ADR-0015)

Default: the AWS hub (`10.0.3.1`). Every app in scope today (TODO app, dashboards, Hue's central UI/API) runs there.

A NUC (`nuc4` in NYC, `nuc5` in Rambles) is only used when an app has a hard local-latency requirement — currently just the Hue automation agent's per-site color-transition logic. This is a per-app exception earned by a real constraint, not a default; if your app thinks it needs NUC placement, that's a decision for this doc/an ADR update, not something to decide silently inside the app repo.

## Database (ADR-0016)

One shared Postgres instance on the hub. Each app gets its own logical database and a least-privilege role — never the shared admin credential (`/home-platform/postgres/admin-password`).

**Onboarding a new app's database** (a platform-side action, done once against the live instance — not something the app's own CI/CD does):

1. `CREATE DATABASE <app>;`
2. `CREATE ROLE <app> WITH LOGIN PASSWORD '...';`
3. `GRANT ALL PRIVILEGES ON DATABASE <app> TO <app>;` (plus schema-level grants once the app has run its own migrations)
4. Store the password in SSM at `/home-platform/postgres/<app>-password`
5. The app connects to `postgres:5432` by Docker network hostname (see "Networking" below), `sslmode=disable` — matches the existing internal-only pattern (`postgres-exporter`, Authentik); the instance is never exposed beyond WireGuard peers

## Auth (ADR-0017)

Authentik at `auth.billandjessie.com` is the shared OIDC provider. Two integration patterns — pick based on what the app supports:

**Pattern A — native OIDC (preferred).** The app implements a standard OIDC relying-party flow (authorization code, not implicit) and Authentik issues tokens directly.

1. A new blueprint, `compose/aws/authentik/blueprints/<app>-oidc.yaml`, declares an OAuth2 Provider + Application — same shape as `grafana-oidc.yaml`, GitOps-managed rather than clicked through the admin UI.
2. Client ID/secret generated, stored in SSM at `/home-platform/authentik/<app>-client-id` / `<app>-client-secret`.
3. Redirect URI: `https://<app>.billandjessie.com/<the app's own OIDC callback path>`, `matching_mode: strict`.
4. The app reads `AUTHENTIK_<APP>_CLIENT_ID` / `_CLIENT_SECRET` from its environment, populated at deploy time from SSM (same mechanism `deploy-aws-stack.ps1` already uses for Grafana's OIDC client).

**Pattern B — forward-auth gate.** For an app with no OIDC support at all — same shape as Uptime Kuma's `kuma-proxy.yaml` blueprint + the `authentik-forward-auth` Traefik middleware already defined on the `traefik` service. Coarser than Pattern A (all-or-nothing access; the app only sees identity if it reads the forwarded `X-authentik-*` headers) — only use it when Pattern A genuinely isn't possible.

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

Every credential an app needs lives in SSM under `/home-platform/<app-or-service>/*`, following the convention already documented in this repo's `CLAUDE.md`. An app never hardcodes a secret in its own repo, in a committed `.env`, or as a GitHub Actions secret — SSM is the one source of truth, fetched at deploy time the same way `scripts/deploy-aws-stack.ps1` fetches the platform stack's own secrets today.

## Networking

Traefik's Docker provider only discovers containers reachable on the same Docker network, and an app needs to reach `postgres`/`redis` by hostname the same way. **This requires one platform-side change before the first app can deploy**: `compose/aws/docker-compose.yml` needs an explicit external network (e.g. `home-platform`) that all of its services join, replacing the implicit default network Compose creates today. That's a one-time migration — every existing container recreates when it lands — so it's deliberately not done speculatively in this pass; it happens once, alongside the first real app deploy, not ahead of time.

Until that network exists, an app's own Compose fragment should declare it as `external: true` and expect that one-time platform migration as a prerequisite to its first deploy.

## CI/CD and deploy (ADR-0019)

**Registry**: AWS ECR, one repository per app. Each app gets its own IAM role in this repo's Terraform (`terraform/aws/iam.tf`, or a new `apps.tf`) — OIDC trust scoped to `repo:bcalaway/<app-repo>:*` and that app's own ECR repo ARN, following the exact least-privilege pattern the `github_actions` role already uses. An app's role never gets access to this platform's own resources: not other apps' ECR repos, not Terraform state, not SSM paths outside its own `/home-platform/<app>/*` (plus whatever specific platform paths it's explicitly granted, like its Postgres/Authentik credentials).

**CI (every PR, required check)**: build, test, lint.

**CD (on merge to main)**: build the image, tag `<git-sha>` and `latest`, push to the app's ECR repo. Then, per the app's own declared mode:
- **Auto-deploy**: the same workflow run also triggers the deploy step immediately
- **Manual promote**: the workflow stops after the push; a separate `workflow_dispatch` job deploys on demand

**Deploy step** (either mode): reach the hub the same way the RouterOS workflow already does for a hosted GitHub runner that can't reach `10.0.3.1` directly — AWS `ssm:SendCommand` (`AWS-RunShellScript`), telling the hub to pull the new image from ECR and `docker compose up -d` the app's own Compose fragment.

**Reusable workflow**: lives in this repo (`workflow_call`), invoked from each app repo's own `.github/workflows/*.yml`. A pipeline fix lands once here and every app picks it up on its next run, instead of needing to be copied into each app repo individually.

**Environment**: production only — no staging/preview tier, per Bill's explicit call in ADR-0019.

## Starter templates

Not yet built (next task after this doc). Planned: Python, C++, React — each pre-wired with the reusable CI/CD workflow calls, a Dockerfile, and the Postgres/Auth/Traefik integration points above already filled in with placeholder values. Location TBD; update this section once decided.

## Onboarding checklist for a new app

1. [ ] Create the app's GitHub repo from a starter template (once templates exist)
2. [ ] Platform side: create the app's Postgres database + role, store the credential in SSM
3. [ ] Platform side: add the app's Authentik OIDC blueprint (or forward-auth middleware), store client credentials in SSM
4. [ ] Platform side: add the app's `aws_route53_record` in `terraform/aws/tls.tf`
5. [ ] Platform side: add the app's IAM role + ECR repo in `terraform/aws/iam.tf` (or `apps.tf`)
6. [ ] Platform side (first app only): migrate `compose/aws/docker-compose.yml` onto the shared external Docker network
7. [ ] App repo: add Traefik labels to its own Compose fragment
8. [ ] App repo: wire the reusable CI/CD workflow, choosing auto-deploy or manual-promote
9. [ ] Verify end-to-end: PR merges → image lands in ECR → app deploys → reachable at `https://<app>.billandjessie.com` → auth flow (Pattern A or B) actually gates access
