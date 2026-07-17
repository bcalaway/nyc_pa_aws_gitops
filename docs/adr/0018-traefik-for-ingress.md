# ADR-0018: Traefik for Ingress, Replacing Hand-Edited nginx

Date: 2026-07-17
Status: Accepted

## Context

The hub currently reverse-proxies `grafana.billandjessie.com` and `status.billandjessie.com` via nginx, configured by hand directly on the instance and deliberately not tracked in Git (documented as a "redo manually if the instance is ever rebuilt" risk — see CLAUDE.md's TLS/reverse-proxy section). That was an acceptable trade-off for two static routes. It stops being acceptable once apps are shipping regularly: every new app would mean a manual, undocumented edit on the hub — exactly the kind of manual, easy-to-drift step that caused a real incident earlier in this platform's life (see CLAUDE.md's Gotchas entry on the RouterOS WireGuard reapply incident, 2026-07-17).

## Options Considered

**Option A: Keep nginx, template its config from Git**
- Smaller change than switching tools
- Still requires a manual route addition (even if git-tracked and reviewed) for every new app — doesn't remove the per-app manual step, just makes it safer
- Doesn't reduce the operational burden as app count grows

**Option B: Traefik**
- Auto-discovers routes from Docker labels — an app's own `docker-compose.yml` declares its own subdomain/route, no manual edit on the hub at all for a new app
- Native Let's Encrypt integration (replaces the current certbot-dns-route53 systemd-timer setup, though that migration can happen incrementally)
- First-class Kubernetes Ingress support if/when ADR-0003's Compose-over-k8s decision is revisited — Traefik ships built into k3s by default, so this choice pays forward into that future migration instead of being thrown away
- Real migration effort now: two working routes (Grafana, status) need to move over without breaking anything

## Decision

Migrate ingress from hand-edited nginx to Traefik. New apps declare their own routing via Docker labels in their own compose definitions — no manual hub-side config edit per app. Existing routes (Grafana, status page) migrate to Traefik as part of the platform buildout, not left on legacy nginx indefinitely.

TLS certificate management moves to Traefik's native Let's Encrypt integration where practical, retiring the standalone certbot-dns-route53 timer once Traefik's equivalent is confirmed working.

## Consequences

- `compose/aws/docker-compose.yml` gains a Traefik service; app repos' own compose files carry Traefik labels for their routes
- The nginx config becomes obsolete — remove it once Traefik is confirmed handling both existing routes, rather than leaving two reverse proxies running
- Reduces the "host-level, not tracked in Git" surface area on the hub — ingress config now lives in Git across this repo and each app repo, not hand-edited on the instance
- New apps get routing "for free" as part of following the platform contract (ADR-0014) — no separate ingress PR against this repo needed per app
