# ADR-0012: MikroTik RB5009 as Router at Both Sites

Date: 2026-06-28
Status: Accepted

## Context

Both sites currently use consumer routers (Netgear Nighthawk RS700 at NYC, ASUS ZenWiFi AX6600 at Rambles). These are adequate initially but are not scriptable, not GitOps-manageable, and conflate routing with WiFi. A long-term router solution is needed.

## Options Considered

**Option A: Keep consumer routers**
- No upfront cost
- Cannot be configured via Ansible or Git
- Routing and WiFi tightly coupled — replacing one means replacing both
- Limited dual-WAN capabilities
- No native WireGuard support at the quality needed

**Option B: pfSense / OPNsense on a NUC or mini-PC**
- Powerful, open source
- Routing depends on a general-purpose computer — violates router/server separation philosophy
- More failure modes

**Option C: MikroTik RB5009**
- Purpose-built router hardware
- RouterOS: scriptable, SSH-accessible, Ansible-manageable
- Native WireGuard support
- Native dual-WAN failover with policy routing
- 2.5Gb ports, 10Gb SFP+ — handles current and future bandwidth
- Config exportable to text — lives in Git
- Two purchased (one per site)
- Cold spare planned for the future; dual-router VRRP eventually

## Decision

MikroTik RB5009 is the router at both sites. Two units purchased.

Consumer routers demoted to AP mode:
- NYC: Netgear Nighthawk RS700 → AP mode
- Rambles: ASUS ZenWiFi AX6600 mesh → AP mode (mesh retained for WiFi coverage)

## RouterOS GitOps

RouterOS configuration exported as scripts and stored in Git under `routeros/nyc/` and `routeros/rambles/`. Applied via Ansible. Changes go through PR → approval → apply.

## Future

- Cold spare (third RB5009)
- Two routers per site with VRRP for router-level redundancy

## Consequences

- Routing, DHCP, DNS, and WireGuard all run on the RB5009
- NUC failure does not affect network routing (Tier 1 met)
- RouterOS scripting knowledge required — documented in runbooks
- Dual-WAN failover configured natively in RouterOS
