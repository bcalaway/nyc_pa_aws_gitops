# Roadmap

## How work gets done

Claude writes all code and config, opens PRs, and applies changes after Bill approves.
Bill handles physical tasks and PR approvals only.

Tasks are tagged: 🧑 = Bill does this physically / approves | 🤖 = Claude does this

## Priority

Rambles WAN failover (Blue Ridge Cable → Starlink) is the near-term priority. Everything else can be built in milestone order.

Completed milestones (1–5, 8, 9, 11–18) moved to [roadmap-archive.md](roadmap-archive.md) on 2026-09-30 with their full history. This file keeps what's still in play: open loose ends from finished milestones, then the active milestones.

## Loose ends from completed milestones

Unchecked items carried over verbatim from archived milestones; tick them here (and in the archive entry if the detail matters).

- [ ] **M3** ([Observability Stack](roadmap-archive.md#milestone-3--observability-stack)): 🤖 `snmp_exporter` for MikroTik switches and routers (both sites) *(all of NYC done: both RB5009 routers, sw-10g/CRS309, sw-main + sw-desk (Cisco SG300-10); only Rambles' CRS310 switch still pending — see docs/network-inventory.md)*
- [ ] **M9** ([Router GitOps](roadmap-archive.md#milestone-9--router-gitops)): 🧑 First-time RB5009 setup: set IP + enable SSH via Winbox web UI (Claude provides exact values)
- [ ] **M9** ([Router GitOps](roadmap-archive.md#milestone-9--router-gitops)): 🤖 Dual-WAN config defined in Git *(blocked on Milestones 6/7 hardware)*
- [ ] **M13** ([Weather Collection & Dashboard](roadmap-archive.md#milestone-13--weather-collection--dashboard)): 🧑 NYC has no weather station yet — extend the same exporter there if one is ever added
- [ ] **M13** ([Weather Collection & Dashboard](roadmap-archive.md#milestone-13--weather-collection--dashboard)): 🧑 The rendered dashboard panel itself is one more thing only Bill can check firsthand (same Authentik-login browser-pane limitation noted elsewhere in this doc) — worth a look at `https://grafana.billandjessie.com` once Back has a real watering day to show
- [ ] **M14** ([Hue Control, Styling & Animations](roadmap-archive.md#milestone-14--hue-control-styling--animations)): 🧑 The actual rendered UI (collapsed/expanded rooms, on/off toggle, scene click, animate panel, automation definitions) is one more thing only Bill can check firsthand — same browser-pane limitation noted elsewhere in this doc blocks a screenshot-based check
- [ ] **M15** ([Propane Tank Monitoring](roadmap-archive.md#milestone-15--propane-tank-monitoring)): 🧑 Optional / follow-ups: move proxy #1 toward the two grill tanks (Grill 1 ≈ −92, Downstairs Right ≈ −96 are the weakest) to firm those up; refine `empty_mm` for the 30/20 lb pairs after a fill cycle (the low-fill calibration anchors were quantized); confirm one real level against a tank's own gauge
- [ ] **M17** ([Portal Weather & Woods Calendar](roadmap-archive.md#milestone-17--portal-weather--woods-calendar)): 🧑 Rest of the "portal overhaul" — open-ended, revisit once Bill has more specific ideas for what else belongs on the page

## Milestones

### Milestone 6 — Rambles WAN Failover *(priority)*
**Goal:** Automatic failover between Blue Ridge Cable and Starlink at Rambles.

Tasks:
- [ ] 🧑 Connect Starlink ethernet adapter to RB5009 WAN2 port
- [ ] 🧑 Enable Starlink bypass mode in the Starlink app
- [ ] 🤖 RouterOS dual-WAN policy routing configured (Claude pushes via SSH)
- [ ] 🧑 Failover tested: unplug Blue Ridge Cable → confirm Starlink takes over
- [ ] 🤖 Both WAN connections monitored independently in Grafana
- [ ] 🤖 Config committed to `routeros/rambles/`

### Milestone 7 — NYC WAN Failover
**Goal:** Automatic failover between FiOS and building WiFi at NYC.

Tasks:
- [ ] 🧑 Purchase GL.iNet travel router (~$40-60)
- [ ] 🧑 Connect GL.iNet to building WiFi, plug ethernet into RB5009 WAN2
- [ ] 🤖 RouterOS dual-WAN policy routing configured
- [ ] 🧑 Failover tested: unplug FiOS → confirm building WiFi takes over
- [ ] 🤖 Config committed to `routeros/nyc/`

### Milestone 10 — NAS Backup
**Goal:** NUC Docker volumes backed up to NAS on schedule.

**Blocked on hardware** (2026-07-19): Bill is bringing a second NAS to Rambles specifically to serve as the backup target — backing up to a NAS at the *other* site, not just a share on nas2 itself, so a site-level incident at NYC (power, fire, theft) doesn't take out both the primary data and its backup together. This also activates the "Second Synology NAS at Rambles" item from Future/Deferred below — that's now this milestone's hardware dependency, not a separate someday item. Revisit once it's physically in place and reachable on Rambles' LAN.

Tasks:
- [ ] 🧑 Bring second NAS to Rambles, get it on the LAN with a reserved IP (`docs/network-inventory.md`)
- [ ] 🧑 Create NFS share on the Rambles NAS for backups
- [ ] 🤖 restic installed on NUCs via Ansible
- [ ] 🤖 Rambles NAS NFS share mounted on both NUCs (WireGuard tunnel for the NYC NUC, reaching cross-site)
- [ ] 🤖 restic backup job: Docker volumes → Rambles NAS on cron
- [ ] 🤖 Backup metrics exposed to Prometheus
- [ ] 🤖 Grafana alert on backup failure

## Future / Deferred

- NAS-to-NAS replication (NYC → Rambles) via Synology Hyper Backup *(distinct from Milestone 10's restic-based Docker-volume backups — this would be live replication between the two NAS boxes themselves, once both exist)*
- UPS at both sites
- Environmental / temperature sensors
- VRRP dual-router per site
- MikroTik RB5009 cold spare
- Home Assistant integration
- VLAN segmentation
- Dynamic routing (BGP/OSPF between sites)
- Remote power management
- Kubernetes (if workloads grow to justify it)
