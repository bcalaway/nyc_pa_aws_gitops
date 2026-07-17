# ADR-0014: One Repo Per App, Tied Together by a Platform Contract Doc

Date: 2026-07-17
Status: Accepted

## Context

Bill wants to start deploying real applications on top of this platform — a TODO app, a Hue lighting controller (NYC + Rambles), a personal dashboards app, and potentially more, some possibly commercial later. A repo organization decision is needed before any app code gets written.

## Options Considered

**Option A: Everything in this repo**
- Simplest to start — no new repos, no cross-repo tooling
- Blast radius problem: a bug in one app's CI/build could touch infra code in the same repo/PR review surface
- This repo's whole identity (GitOps for physical infrastructure) gets diluted by unrelated application code
- Doesn't scale to "and more, sometime maybe even commercial endeavors" — a future commercial product living in the same repo as home router configs is an obviously wrong shape

**Option B: One monorepo for all apps, separate from the platform repo**
- Better than Option A, but still couples unrelated apps' CI/release cadence together
- A commercial app's repo visibility/access needs would force awkward compromises on the other apps sharing the monorepo

**Option C: One repo per app, platform repo stays infra-only, tied together by a documented contract**
- Each app's CI, release cadence, and (later) access control are independent
- This repo (`nyc_pa_aws_gitops`) keeps a single clear identity: the foundational platform, not any app's business logic
- A new app repo can be handed to someone else (a collaborator, a commercial co-founder) without exposing home network infrastructure
- Requires a documented contract so each app repo doesn't need to re-derive platform mechanics from scratch

## Decision

One GitHub repo per application. This repo (`nyc_pa_aws_gitops`) remains the foundational platform — network, Terraform, observability, DNS/TLS — plus the shared services apps depend on (Postgres, Authentik, Traefik). It does not contain application business logic.

A platform contract doc, `docs/app-platform.md` in this repo, documents how an app repo integrates: database provisioning, auth integration, ingress/DNS wiring, secrets, and the deploy mechanism. Every app repo's README points at it instead of re-explaining platform mechanics.

App repos live under the same personal GitHub account as this repo for now (see the "commercial" question — deliberately deferred until a specific commercial idea actually exists, at which point that one repo can move to its own org without disrupting anything else).

## Consequences

- New app = new repo, following a starter template (see ADR-0019) — not a new directory in this repo
- This repo's own scope stays bounded: infra + shared platform services only
- `docs/app-platform.md` is now a real dependency for every app repo — keeping it accurate matters as much as keeping the Terraform accurate
- Cross-repo changes (e.g. adding a new shared service) need coordination: land the platform side here first, then app repos adopt it
