# ADR-0001: WireGuard Site-to-Site on Router, Not on NUCs

Date: 2026-06-28
Status: Accepted

## Context

The platform requires a secure tunnel connecting NYC, Rambles, and AWS. The tunnel must allow devices at either site to reach the other site and AWS transparently, without requiring VPN client software on individual devices.

Two placement options were considered: running WireGuard on the Linux NUCs, or running it natively on the MikroTik RB5009 routers.

## Options Considered

**Option A: WireGuard on Linux NUCs**
- WireGuard runs as a Docker container or systemd service on each NUC
- All tunnel traffic routes through the NUC
- Requires NUC to be running for any cross-site or AWS connectivity
- Violates Tier 1 availability requirement — routing must survive a NUC failure

**Option B: WireGuard on MikroTik RB5009 (RouterOS)**
- WireGuard is a first-class RouterOS feature on the RB5009
- Tunnel is established at the router level
- All LAN devices get transparent access to both sites and AWS with no client software
- Survives NUC failure — tunnel stays up independently
- Road warrior access handled by a separate WireGuard client on the laptop only

## Decision

WireGuard runs on the MikroTik RB5009 at each site. AWS EC2 is the hub. Both site routers initiate outbound connections to the hub's Elastic IP, so dynamic residential IPs are not a problem.

A WireGuard client is installed on the laptop only, for road warrior access when away from both sites.

No WireGuard client is required on phones, PCs, Apple TVs, or any other home device.

## Topology

| Peer | Type | WireGuard IP |
|------|------|--------------|
| AWS EC2 | Hub | 10.0.3.1 |
| NYC RB5009 | Site peer | 10.0.3.2 |
| Rambles RB5009 | Site peer | 10.0.3.3 |
| Laptop | Road warrior | 10.0.3.4 |

## Consequences

- Routing and VPN are independent of NUC availability (Tier 1 reliability met)
- RouterOS WireGuard config lives in Git under `routeros/` and is applied via Ansible
- Adding new road warrior clients requires generating a new WireGuard keypair and adding a peer to the hub config
