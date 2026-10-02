# ADR-0023: Per-PR Preview Environments (Milestone 18, Phase 5)

Date: 2026-10-01
Status: Proposed

## Context

ADR-0021 phase 5: "per-PR temporary deployments for testing a feature before merge, torn down on merge/close." Today the only way to see a change running is to merge it, and merging deploys to production (ADR-0019 has no staging tier, by Bill's choice). With the voice agent writing PRs from the car, Bill wants to open a link on his phone and try a change before deciding to merge.

What the platform gives us, and the constraints that come with it:

- **Apps deploy as a Compose fragment on the hub** (`deploy/docker-compose.yml`), with fixed `container_name` and fixed Traefik router names and Host rules. A preview can't reuse the file as-is: it would clash with production's container and router.
- **DNS is one explicit Route 53 record per app**, with no wildcard. TLS comes from Traefik's Route 53 DNS challenge. Let's Encrypt allows 50 certificates per registered domain per week, so one certificate per preview host would add up.
- **Auth:** todo-app uses OIDC itself (ADR-0017 Pattern A) with a **strict** redirect URI in Authentik, so a new hostname can't log in without an Authentik change.
- **Data:** each app has its own Postgres database and least-privilege role (ADR-0016).
- **Hub capacity:** `t3.medium` (4 GB) already runs about 20 containers.
- **Who writes PRs:** the voice agent (ADR-0021). Its code has had no human review when a PR opens, and production only ever runs code after Bill merges. **A preview is the first time unreviewed code would run on the hub.** That's the main risk this design has to handle.
- todo-app and hue are **public repos**: PRs from forks must never deploy.
- hue previews would talk to the real Hue agents and bridges, so a preview could switch real lights.

## Options Considered

**A. Previews on the hub, approval-gated, isolated network** (recommended)
- Reuses everything: ECR, S3 + SSM deploy, Traefik, Authentik, Postgres
- A preview deploy waits for Bill's tap, the same gate as production deploys, so no unreviewed code runs without his say-so. One tap per push to the PR
- Preview containers run on a separate **internal** Docker network (no internet egress) that reaches only Traefik and Postgres (with a preview-only role), not Redis, Authentik, home-mcp or other apps, and they hold no production secrets

**B. Previews on nuc4**
- Keeps unreviewed code off the hub, but nuc4 has no Traefik, TLS, Authentik or Postgres. We'd duplicate the platform or route back through the hub. nuc4 also runs the coding agent and the Hue agent

**C. Previews as plain containers on an ephemeral EC2 or Fargate task per PR**
- Strongest isolation, but new infra (VPC wiring, IAM, cost, start-up minutes), and it still needs DNS, TLS and auth. Too much for a household platform

## Decision (proposed)

**Option A**, todo-app first.

### Shape

- **Host:** `pr-<n>.<app>.preview.billandjessie.com`, e.g. `pr-7.todo-app.preview.billandjessie.com`
- **DNS and TLS, set up once:** a single wildcard record `*.preview.billandjessie.com` pointing at the hub EIP, scoped to the `preview` subdomain only (production stays on explicit records), plus **one wildcard certificate** for that name from the existing Route 53 resolver. Previews then cost no certificate issuance at all
- **Auth:** Authentik **forward-auth** (ADR-0017 Pattern B) on every preview router, so nobody but Bill reaches a preview, whatever the app does. The app's **own OIDC login is off in previews**: giving unreviewed code the production OIDC client secret, plus an internet path to use it, is exactly what isolation is for. If an app needs a signed-in user, it reads forward-auth's `X-authentik-username` header in preview mode (`PREVIEW=1`). That's a small, once-per-app change, and it means previews can't test the login flow itself
- **Image:** CI builds the PR's image anyway; the preview workflow pushes it as `<app>:pr-<n>` (never `latest`)
- **Data:** a fresh database `<app>_pr<n>` owned by a `<app>_preview` role, **seeded with a copy of production** (`pg_dump`/restore of the app's own database: household-sized, seconds). Previews never touch the production database. Open question 2 has the alternative
- **Compose:** the workflow (on the runner, where `yq` exists) rewrites the app's own fragment: project name `<app>-pr<n>`, no `container_name`, router and service labels renamed to `<app>-pr<n>`, Host rule set to the preview host, forward-auth middleware added, network swapped to `preview`, `mem_limit: 384m`, and env overrides for the DB name and the external URL. The hub gets a ready file. Apps don't need a second fragment
- **Isolation:** a `preview` Docker network with `internal: true` (no route to the internet), joined by Traefik and Postgres only. Previews get the app's non-secret env, `PREVIEW=1`, and the preview DB credentials. **No production secrets**: no `.env` from SSM

### Lifecycle

- **Trigger:** `pull_request` opened, synchronize or reopened, **same-repo branches only** (`head.repo == base.repo`; fork PRs are skipped). Opt-out per PR with a `no-preview` label
- **Gate:** the deploy job runs in a new `preview` environment with Bill as required reviewer, separate from `production` so approvals read clearly ("preview for todo-app PR #7"). `platform_status` and `github_status` already announce waiting runs
- **Up:** `scripts/hub/preview-up.sh` creates the DB and role on first deploy, pulls `<app>:pr-<n>`, runs `docker compose -p <app>-pr<n> up -d`, waits for `/health`, then comments the URL on the PR
- **Down:** on PR closed (merged or not), `preview-down.sh` removes the containers, drops the DB and deletes the image tag. No approval needed: teardown only removes things
- **Limits:** at most **2 previews** running on the hub (the hub is 4 GB). A third waits with a PR comment saying so. A nightly sweep (a scheduled workflow, also usable as a voice job) removes previews whose PR is closed or older than 7 days
- **Voice:** `github_status` adds the preview URL to each open PR; new voice job `preview-down {app, pr}` for manual cleanup

### Platform pieces

- Terraform: wildcard record; nothing for IAM, since the existing app CI roles already push to ECR and trigger SSM
- `compose/aws`: `preview` network; Traefik wildcard certificate (`tls.domains` for `*.preview.billandjessie.com`); Postgres joins `preview`; one `preview-admin` SSM credential, able only to create and drop `*_pr*` databases (via a `SECURITY DEFINER` function, not superuser)
- Reusable workflows `app-preview.yml` (build, push, gate, up) and `app-preview-down.yml`; app repos add one thin `preview.yml`
- Per app: honour `PREVIEW=1` (skip OIDC, trust forward-auth's username header). For todo-app that's a small PR in its repo

## Consequences

- Bill can try any same-repo PR on his phone before merging, with one extra tap per push
- Unreviewed code runs on the hub for the first time, but only after Bill's tap, behind forward-auth, with no production secrets, on an internal network that can reach only Traefik and Postgres (as a role that owns nothing but its own preview database), with memory capped. Even fully malicious preview code can't phone home
- A small permanent platform surface: one wildcard DNS name, one wildcard certificate, one network, one Postgres helper role, and a nightly sweep
- hue is **excluded at first** (open question 3): a hue preview would drive the real lights through the same agents as production
- Copying production data into previews means household data (to-do items) lives briefly in extra databases on the same instance. That's acceptable for todo-app; revisit per app

## Open questions for Bill

1. **One tap per push** to a PR, or approve once per PR and let later pushes redeploy automatically? Recommendation: every push, because each push is new unreviewed code
2. **Preview data:** a copy of production (realistic, recommended for todo-app), or an empty database each time (no household data copied, but you test against nothing)?
3. **hue:** leave it out (recommended for now), or include it knowing a preview can switch real lights?
4. **Max 2 concurrent previews and a 7-day expiry:** OK?
