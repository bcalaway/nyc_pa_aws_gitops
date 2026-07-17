# ADR-0017: Authentik for Shared Application Authentication

Date: 2026-07-17
Status: Accepted

## Context

Every planned app needs authentication, and Bill wants Grafana (currently anonymous-access, per Milestone 3) folded into the same login rather than each app or service inventing its own. A shared identity/auth layer is needed that apps trust instead of implementing their own login.

## Options Considered

**Option A: Per-app authentication**
- Each app implements its own login/session handling
- No shared login across apps or Grafana — exactly what Bill wants to avoid
- Rejected

**Option B: Authelia (lightweight forward-auth gate)**
- Fast to stand up, minimal footprint, does one job well: gate access behind nginx/Traefik
- Not a full identity provider — weaker foundation if a commercial app later needs real user signup, OAuth client registration, or multi-tenant accounts
- No dependency on its own database beyond a lightweight config store

**Option C: Authentik (full OIDC provider)**
- Real OIDC/OAuth2 provider, not just a gate — apps (and Grafana) integrate via standard OIDC, generic across languages (matters given the C++/Python/React mix)
- Directly usable if a commercial app later needs actual user signup/OAuth flows, not just "let Bill and Jessie in" — avoids a migration later
- Heavier: it's a full Django application, requiring its own Postgres database and Redis — real setup, not a checkbox
- More UI/admin surface to learn than Authelia, but that surface is exactly what's needed once there's more than one kind of "user" (household vs. commercial customer)

## Decision

Authentik, as the shared authentication layer for all apps and for Grafana. It sits behind Traefik (ADR-0018) as the OIDC provider; apps redirect to it for login and trust the resulting token/session instead of implementing their own auth.

Authentik's own backing store (Postgres database + Redis) is provisioned as part of the shared platform services on the hub — its Postgres database lives in the same shared instance from ADR-0016, and Redis is a new, small addition to `compose/aws/docker-compose.yml`.

Grafana is reconfigured to authenticate via Authentik (OIDC) instead of anonymous access, once Authentik is live.

## Consequences

- New shared services on the hub: Authentik, Redis (Authentik's dependency)
- Every app needs OIDC client registration in Authentik as part of its onboarding — this belongs in the platform contract doc (ADR-0014)
- Grafana's anonymous-access setting (Milestone 3) gets revisited and replaced with OIDC login
- Authentik admin credentials and OIDC client secrets go in SSM under `/home-platform/authentik/*`, per ADR-0005's convention
- `auth.billandjessie.com` is the new subdomain for Authentik itself, following the existing `grafana.`/`status.` pattern
