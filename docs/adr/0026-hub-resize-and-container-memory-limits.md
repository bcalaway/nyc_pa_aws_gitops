# ADR-0026: Resize the Hub to t3.large and Give Every Container a Memory Limit

Date: 2026-10-03
Status: Proposed

## Context

The hub is a `t3.medium` (4 GB, resized in Milestone 11). It runs the observability stack (Prometheus, Loki, Alloy, Grafana, Uptime Kuma), Traefik, Authentik (server + worker), Postgres, Redis, home-mcp, exporters, Umami, and every app (todo-app, hue, previews).

The market data platform (design doc: "Market Data Platform — Data Layer Architecture") adds Airflow (ADR-0027) plus several small services (security master, quotes, a gateway, a UI). That doesn't fit in 4 GB.

Today nothing stops one container from using all the memory. An Airflow task that loads a large file, or a leaking service, can push the host into the kernel OOM killer, which may pick Postgres, Traefik or Authentik. Those carry every app and the WireGuard-reachable platform. Previews already run with `mem_limit: 384m` (ADR-0023), so the pattern exists but only for previews.

## Options Considered

**Option A: Resize only (t3.large, 8 GB)**
- One Terraform variable, in-place update, same as the Milestone 11 resize
- Doesn't fix the blast-radius problem; it only moves the point where it happens

**Option B: A second "workload" EC2 for Airflow and the mkt services**
- Real isolation: a runaway workload can't touch the core services
- Breaks today's single-host contract: apps reach Postgres, Redis and each other by Docker hostname on the `home-platform` network (ADR-0016, ADR-0020). Cross-host needs private-IP or internal DNS addressing, Traefik routing to another node, and deploys that target a host
- Worth doing once the real footprint is known, not before

**Option C: ECS, EKS or Fargate**
- EKS adds ~$73/month for the control plane alone; ECS means rewriting every Compose stack as task definitions; Fargate prices always-on workloads above EC2
- Reverses ADR-0003 for no current need

**Option D: Resize to t3.large and set a memory limit on every container (chosen)**
- Cheap (~+$30/month on-demand, to confirm) and inside the current contract
- Limits turn "the host runs out of memory" into "one container is OOM-killed and restarted", which Docker and Grafana already surface

## Decision

1. **Resize** `var.ec2_instance_type` to `t3.large`. Revisit `t3.xlarge` only if measured usage says so.
2. **Every service in `compose/aws/` gets `mem_limit`**, and every app's `deploy/docker-compose.yml` must set one. The hub-side deploy check rejects an app fragment without it, the same way `preview-compose.py` enforces previews.
3. **Limits come from measurement, not guesses.** Add cAdvisor to the hub stack and a Prometheus scrape job, run for a week, then set each limit to observed peak plus headroom. Until then, use generous limits that still sum to less than physical memory minus a reserve for the host.
4. **Core services get the most headroom**: Postgres, Traefik, Authentik and WireGuard-adjacent pieces should be the last things to hit a limit.
5. **Alert** on any container OOM kill and on host memory pressure, through the existing Grafana alerting.

## Consequences

- Monthly cost rises by roughly the price difference between t3.medium and t3.large.
- A misbehaving workload restarts itself instead of degrading the platform.
- App authors (Claude) must pick a limit per app; the onboarding checklist in `docs/app-platform.md` gains that step.
- A second node (Option B) stays on the table. When it's needed, it gets its own ADR covering cross-host addressing, Traefik and deploy targeting.
- ARM (t4g) would be ~20% cheaper but needs multi-arch images, since the NUCs are x86. Not worth it yet.
