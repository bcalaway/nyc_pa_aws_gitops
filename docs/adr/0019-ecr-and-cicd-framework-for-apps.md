# ADR-0019: AWS ECR + Trunk-Based CI/CD Framework for App Repos

Date: 2026-07-17
Status: Accepted

## Context

Bill wants continuous delivery to be "phase 0" for every app, not something bolted on later: trunk-based development, feature branches merged via PR, and CI/CD treated as a starting requirement rather than a later milestone. With apps split across C++, Python, and React (per Bill's language preferences), a shared framework is needed so every new app repo doesn't re-derive its own pipeline from scratch.

This repo's existing GitHub Actions setup (`terraform/aws/iam.tf`) already establishes the pattern to build on: OIDC federation (no long-lived AWS credentials in Actions) via `aws_iam_openid_connect_provider`, with an IAM role scoped narrowly by repo (`repo:${var.github_org}/${var.github_repo}:*`) and by resource (e.g. SSM access scoped to `/home-platform/*` only). That role is currently trusted by exactly one repo — this repo.

## Options Considered

**Container registry — Docker Hub vs. GitHub Container Registry (ghcr.io) vs. AWS ECR**
- Docker Hub: most common industry default, but the free tier's pull-rate limits are a real risk for a pipeline that pulls on every merge
- ghcr.io: free, and this project's tooling is already GitHub-centric (Actions, the `gh` CLI PAT in SSM) — but it's a second identity/registry system alongside AWS
- **AWS ECR (chosen)**: keeps registry access inside the same IAM/OIDC trust model as everything else in this platform, so pushing an image and deploying it use the same credential story instead of two. Costs apply (storage + minor transfer), but at this scale that's small next to the coherence gained by staying in one cloud/IAM boundary

**Deploy model — uniform vs. per-app**
- A single uniform policy (e.g. always auto-deploy on merge) is simpler to build once, but doesn't fit every app: household apps (TODO list) can auto-deploy safely, but Bill wants the option of a manual promote gate for apps holding more sensitive or harder-to-recover data
- **Per-app (chosen)**: the shared framework supports both modes, selected by the app repo, rather than picking one mode for everyone

**Quality gates — required now vs. added later**
- Deferring test/lint requirements until after the first app ships would mean retrofitting branch protection onto repos that already have merge history without it
- **Required from day one (chosen)**: consistent bar across every app repo from the start, easier to keep than to add later

**Starter templates — build now vs. document only vs. one language first**
- Documentation-only risks each new app quietly reinventing (or skipping) part of the pipeline
- Building only a Python template first would unblock the TODO app pilot fastest, but Bill wants all three languages available now, matching his stated preference to start every project CD-ready rather than backfilling it
- **All three now (chosen)**: Python, C++, and React starter templates, each pre-wired with CI/CD, a Dockerfile, and the platform contract integration points

## Decision

**Registry**: AWS ECR, one repository per app. Requires extending the existing GitHub Actions OIDC trust: each app repo gets its own IAM role (scoped to that repo's own `repo:${var.github_org}/<app-repo>:*` condition and its own ECR repository ARN) rather than widening the platform's existing role — matching the least-privilege pattern already established in `iam.tf`, and keeping an app repo's blast radius from ever reaching platform infrastructure permissions.

**CI (required on every PR)**: build, test, lint — a required GitHub branch-protection check across all app repos, no exceptions at launch.

**CD (on merge to main)**: build the image, tag with the Git SHA and `latest`, push to that app's ECR repository. What happens next is per-app:
- **Auto-deploy**: the workflow also triggers the deploy step immediately (pull the new image on the hub, recreate the container via Compose)
- **Manual promote**: the workflow stops after push; a `workflow_dispatch` job (or equivalent) triggers the actual deploy on demand

Each app declares its mode in its own repo (a workflow input or a simple config file read by the shared reusable workflow).

**Starter templates**: one each for Python, C++, and React, living in this repo or a dedicated template-holding location referenced by the platform contract doc (ADR-0014). Each includes: the CI required-checks workflow, the CD workflow (parameterized for auto/manual mode), a Dockerfile, and the integration points for Postgres (ADR-0016), Authentik (ADR-0017), and Traefik labels (ADR-0018) already wired to placeholder values.

**Environment scope**: production only (no staging/preview tier) — per Bill's explicit call, matching the household scale of what's shipping first. Revisit if a commercial app needs stakeholder review before merge.

## Consequences

- `terraform/aws/iam.tf` (or a new file) grows one IAM role + OIDC trust condition + ECR repository per app, added as each app repo is created — this is now a recurring, expected pattern, not a one-off
- The reusable CI/CD workflow(s) need a home — likely a `workflow_call`-based reusable workflow in this repo that app repos invoke, so a pipeline fix lands once and every app picks it up on its next run
- Branch protection (required checks) must be configured per app repo at creation time, not added after the fact
- No preview/staging environments exist — a broken merge is caught by required CI checks pre-merge and by Uptime Kuma/Grafana post-deploy, not by a staging soak period
- The TODO app is the first repo built against this framework — treat its setup as validation of the framework itself, and fix the shared pieces (not just that app) if something doesn't fit
