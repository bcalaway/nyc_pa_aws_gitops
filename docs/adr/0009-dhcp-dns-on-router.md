# ADR-0009: DHCP and DNS Served by Router

Date: 2026-06-28
Status: Accepted

## Context

DHCP and DNS are Tier 1 services — they must continue operating when the Linux NUC is down. A placement decision is required: run these on the NUC or on the router.

## Options Considered

**Option A: DHCP and DNS on Linux NUC**
- More flexibility (CoreDNS, Pi-hole, Unbound, etc.)
- Clients lose DHCP and DNS if NUC is down or being rebuilt
- Violates Tier 1 availability requirement

**Option B: DHCP and DNS on MikroTik RB5009 (RouterOS)**
- RouterOS has built-in DHCP server and DNS resolver
- Runs independently of NUC
- Survives NUC failure, reboot, or reprovisioning
- Consistent with router-as-infrastructure-layer philosophy
- DHCP and DNS config defined in Git under `routeros/` and applied via Ansible

## Decision

DHCP and DNS run on the MikroTik RB5009 at each site.

RouterOS DNS resolver handles internal name resolution. Upstream DNS forwarded to a reliable public resolver (e.g., 1.1.1.1).

Internal records for `*.nyc.billandjessie.com` and `*.rambles.billandjessie.com` configured as static entries on the respective router, generated from Git.

## Consequences

- DHCP and DNS survive NUC failure (Tier 1 met)
- RouterOS DHCP and DNS config lives in Git under `routeros/nyc/` and `routeros/rambles/`
- Changes to DHCP reservations and internal DNS records go through Git → PR → Ansible apply
- No separate DNS server (Pi-hole, CoreDNS) required initially
