# ADR-0010: Uptime Kuma for Public Status Page

Date: 2026-06-28
Status: Accepted

## Context

The platform needs a public-facing status page showing whether services and WAN connections are up or down. Grafana is the main observability tool but is not well-suited as a simple status page. A dedicated solution is needed at `status.billandjessie.com`.

## Options Considered

**Option A: Grafana public dashboard**
- Reuses existing infrastructure
- Grafana dashboards are powerful but complex — not ideal for a simple up/down view
- Anonymous access to Grafana is already planned, but the UX for status pages is poor

**Option B: Custom status page app**
- Full control over appearance
- Requires building and maintaining a web application
- Unnecessary effort for a solved problem

**Option C: Uptime Kuma**
- Open source, purpose-built for up/down status monitoring
- Docker Compose deployable — fits the existing pattern
- Clean, polished UI out of the box
- Monitors HTTP, TCP, DNS, ping targets
- Supports status page with public link
- Active project with good community support

## Decision

Uptime Kuma at `status.billandjessie.com`, running on EC2 via Docker Compose.

Uptime Kuma serves as a canary — it is the first thing to check when something seems wrong, and it remains visible even when Grafana or other services are degraded.

Grafana remains the deep observability tool. Uptime Kuma is the simple at-a-glance status layer.

## Monitors to Configure

- WAN connections (all 4, via blackbox probes)
- WireGuard tunnel (NYC and Rambles)
- Grafana
- Prometheus
- Loki
- NUCs (ping / SSH)
- NAS (ping)
- Plex

## Consequences

- Uptime Kuma added to `compose/aws/docker-compose.yml`
- Config backed up to Git or S3 (Uptime Kuma stores state in SQLite)
- `status.billandjessie.com` added to Route53 and Let's Encrypt coverage
