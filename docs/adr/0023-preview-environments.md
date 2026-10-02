# ADR-0023: Per-PR Preview Environments (Milestone 18, Phase 5)

Date: 2026-10-01
Status: Accepted (2026-10-01)

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

**A. Previews on the hub, isolated network** (chosen)
- Reuses everything: ECR, S3 + SSM deploy, Traefik, Authentik, Postgres
- As first proposed, every preview deploy waited for Bill's tap. He chose automatic deploys instead (see Decision), so containment carries the security weight
- Preview containers run on a separate **internal** Docker network (no internet egress) that reaches only Traefik and Postgres (with a preview-only role), not Redis, Authentik, home-mcp or other apps, and they hold no production secrets

**B. Previews on nuc4**
- Keeps unreviewed code off the hub, but nuc4 has no Traefik, TLS, Authentik or Postgres. We'd duplicate the platform or route back through the hub. nuc4 also runs the coding agent and the Hue agent

**C. Previews as plain containers on an ephemeral EC2 or Fargate task per PR**
- Strongest isolation, but new infra (VPC wiring, IAM, cost, start-up minutes), and it still needs DNS, TLS and auth. Too much for a household platform

## Decision

**Option A**, todo-app first. Bill's answers (2026-10-01): copy production data, leave hue out, max 2 previews with a 7-day expiry, and **no approval for previews**. "Non-prod deployments should just be automatic": production deploys keep the `production` gate; previews deploy on every push.

### Shape

- **Host:** `<app>-pr<n>.preview.billandjessie.com`, e.g. `todo-app-pr7.preview.billandjessie.com`. One label under `preview`, because a wildcard certificate covers exactly one level
- **DNS and TLS, set up once:** a single wildcard record `*.preview.billandjessie.com` pointing at the hub EIP, scoped to the `preview` subdomain only (production stays on explicit records), plus **one wildcard certificate**, obtained by the `auth-preview` router and reused by every preview router through `tls.domains`. Previews cost no certificate issuance
- **Auth:** Authentik **domain-level forward-auth** (`blueprints/preview-proxy.yaml`, `mode: forward_domain`, cookie domain `preview.billandjessie.com`, callbacks on `auth.preview.billandjessie.com`) on every preview router, using the existing `authentik-forward-auth` middleware. One provider covers every preview host. Like Kuma and Umami, it has to be assigned to the Embedded Outpost by hand once
- **The app's own login is off in previews.** Previews get no OIDC client secret. todo-app already runs open when `AUTHENTIK_CLIENT_ID`/`SECRET` are unset, so it needs **no code change**; forward-auth is the only gate. Previews can't test the login flow itself
- **Image:** the preview workflow builds the PR head as `<app>:pr-<n>-<sha12>` (never `latest`). An ECR lifecycle rule expires `pr-*` tags after 14 days
- **Data:** Postgres role and database `<app>-pr<n>` (the platform's APP_NAME convention, so the app connects with no changes), **seeded with a copy of production**: `pg_dump --no-owner --no-acl` of the app's database, restored *as the preview role*, so it owns everything in its database and nothing else. Created by `preview-up.sh` through `docker exec postgres psql` on the hub; no new credential. The database persists across pushes to the same PR
- **Compose:** `scripts/hub/preview-compose.py` (on the runner) rewrites the app's own fragment: no `container_name`, no host ports, volumes, devices or extra capabilities, `APP_NAME=<app>-pr<n>`, `PREVIEW=1`, `.env` holding only the preview DB password and a session secret, network `preview` only, `mem_limit 384m`, `cpus 0.5`, `pids_limit 256`, `cap_drop: ALL`, `no-new-privileges`, and preview Traefik labels. Apps need no second fragment

### Lifecycle

- **Trigger:** the app repo's `preview.yml` (workflow name **Preview**) on `pull_request` opened, synchronize, reopened or closed, **same-repo branches only** (fork PRs skipped; they get no OIDC token anyway). `no-preview` label opts out. Per-PR concurrency cancels a superseded run
- **Up (automatic):** `app-preview.yml` builds and pushes the image, stages the rewritten Compose file under `apps/<app>/previews/pr-<n>/`, and runs `scripts/hub/preview-up.sh` via SSM (`scripts/hub/run-on-hub.sh` ships it base64, so the app's existing CI role is enough). The script starts the preview, checks `/health` from inside the preview network, and comments the URL on the PR
- **Down:** on PR closed (merged or not), `preview-down.sh` removes the containers, database, role and files
- **Limits:** at most **2** previews running. A third deploy fails with a PR comment saying so. `preview-sweep.yml` runs nightly (and as the `preview-cleanup` voice job): it removes previews whose PR is closed, over 7 days old, or orphaned
- **Voice:** `github_status` shows each open PR's preview URL ("preview at todo-app-pr7.preview.billandjessie.com"), or that it's deploying or failed

## Consequences

- Bill can try any same-repo PR on his phone, with nothing to tap
- **Unreviewed code, often the voice agent's, now runs on the hub automatically.** Containment is the control: no production secrets; an internal network with no route to the internet, reaching only Traefik and Postgres; a Postgres role that owns only its own database; CPU, memory and process caps; no capabilities, host ports or volumes; forward-auth in front. Residual risk, accepted: from the preview network, code can send requests through Traefik to other hostnames (the same as an anonymous internet client, so forward-auth and IP allowlists still apply), can open connections to other databases it has no grants in, and Docker's embedded DNS may still resolve external names (a narrow exfiltration path, nothing to exfiltrate but the PR's own code and its copy of the app's data)
- A small permanent platform surface: one wildcard DNS name, one wildcard certificate, one network, a nightly sweep
- hue is **excluded**: a hue preview would drive the real lights through the same agents as production
- Copying production data means household data (to-do items) lives briefly in extra databases on the same instance; acceptable for todo-app, revisit per app
- Onboarding another app: an ECR lifecycle rule for its `pr-*` tags, its own `preview.yml`, and confirming it runs open without its auth secrets
