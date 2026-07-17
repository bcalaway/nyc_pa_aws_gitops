# ADR-0015: App Compute Defaults to the Hub, NUCs Only for Hard Local Requirements

Date: 2026-07-17
Status: Accepted

## Context

Bill's planned apps have different compute needs. A TODO app and a dashboards app are ordinary request/response web services with no particular latency constraint. A Hue lighting controller is different: the long-term goal includes automations that run fast color transitions, which need to talk to each site's local Hue bridge with real-time latency — routing that through AWS on every step would be noticeably laggy, not just architecturally inelegant. The NUCs (nuc4 in NYC, nuc5 in Rambles) were labeled "Application server" in `docs/hardware-inventory.md` from the start, and are largely idle today, running only the exporter stack from Milestone 8.

## Options Considered

**Option A: Everything on the hub**
- Simplest ops story — one place to deploy to, one set of shared services (Postgres, Traefik, Authentik)
- Doesn't solve the Hue automation latency requirement — that one is not a preference, it's physics (round-tripping a home internet connection for something that should feel instant)

**Option B: NUCs primary, hub minimal**
- Uses the hardware that's already paid for and mostly idle
- Ties more of the platform's uptime to residential WAN reliability, before Milestones 6/7 (WAN failover) are even done
- No general-purpose app actually needs this today — over-engineering ahead of a real requirement

**Option C: Hub by default, NUCs only where there's a hard local requirement**
- Matches the actual constraint set: general apps have no reason to leave the always-on hub; Hue's automation path has a real, non-negotiable reason to
- The WireGuard mesh built for site connectivity (ADR-0001) already gives the hub secure, low-latency reach to both NUCs — no new networking needed for a hub-orchestrated, NUC-executed Hue agent
- Keeps the "NUCs are idle spare capacity" story honest instead of speculative: they get used when there's an actual reason, not preemptively

## Decision

Application compute defaults to the AWS hub. A NUC only hosts app compute when there's a hard local requirement — currently, that means the Hue lighting controller's per-site automation agent (nuc4 for NYC's bridge, nuc5 for Rambles' bridge), which needs to run local color-transition logic without a round trip to AWS.

The hub's central Hue UI/API talks to each site's local agent over the existing WireGuard tunnel (`10.0.3.0/24`), the same pattern already used for monitoring.

If a future app has a similarly hard local requirement (not just "would benefit from more RAM"), it earns NUC placement the same way — this is a per-app decision, not a default.

## Consequences

- The TODO app, dashboards app, and Hue's own web UI/API/database all run on the hub
- Only the Hue automation agent runs on-site, one instance per NUC
- The hub needs enough headroom for shared Postgres + Redis + Traefik + Authentik + whatever app containers land there — see ADR-0016 through ADR-0018, and the hub is being resized to `t3.medium` to make room
- A future app that legitimately needs NUC-local compute (not just "it would be nice") should get its own ADR entry or an update to this one's Decision, not a silent exception
