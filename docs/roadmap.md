# Roadmap

## How work gets done

Claude writes all code and config, opens PRs, and applies changes after Bill approves.
Bill handles physical tasks and PR approvals only.

Tasks are tagged: 🧑 = Bill does this physically / approves | 🤖 = Claude does this

## Priority

Rambles WAN failover (Blue Ridge Cable → Starlink) is the near-term priority. Everything else can be built in milestone order.

## Milestones

### Milestone 1 — AWS Foundation
**Goal:** AWS account configured, all base infrastructure in Terraform, GitHub Actions pipeline working.

Tasks:
- [x] 🧑 Create IAM admin user, generate access keys, share with Claude in session
- [x] 🤖 AWS CLI configured and verified
- [x] 🤖 Terraform bootstrap script: create S3 state bucket + DynamoDB lock table
- [x] 🧑 Run bootstrap script (one command)
- [x] 🤖 Terraform: VPC, subnets, security groups
- [x] 🤖 Terraform: EC2 instance, Elastic IP
- [x] 🤖 Terraform: S3 buckets (log archive, portal)
- [x] 🤖 Terraform: Route53 hosted zone for `billandjessie.com`
- [x] 🤖 Terraform: SSM Parameter Store baseline
- [x] 🤖 GitHub Actions: `terraform plan` on PR, `terraform apply` on merge with manual approval
- [x] 🤖 GitHub Actions: `terraform plan` output posted as PR comment
- [x] 🧑 Update NS records at GoDaddy to point to Route53 (Claude provides the values)

### Milestone 2 — WireGuard Hub
**Goal:** Both sites connected to AWS hub via WireGuard. Site-to-site traffic working.

Tasks:
- [x] 🤖 WireGuard installed on EC2
- [x] 🤖 WireGuard server config (hub, 3 peers: NYC, Rambles, laptop)
- [x] Keys generated, stored in SSM Parameter Store
- [x] NYC RB5009 deployed, WireGuard client configured
- [x] Rambles RB5009 deployed, WireGuard client configured
- [x] Laptop WireGuard client configured *(peer removed 2026-07-04 after Rambles RB5009 deployment made it redundant; key was exposed in Git and revoked rather than rotated)*
- [x] Verify: NYC → Rambles connectivity
- [x] Verify: Both sites → EC2 connectivity
- [x] 🧑 Re-provision a laptop WireGuard peer with a fresh keypair when back in NYC with the actual laptop (only needed for remote access when not on either site's LAN)
- [x] RouterOS configs committed to `routeros/`

### Milestone 3 — Observability Stack
**Goal:** Prometheus, Grafana, Loki, Uptime Kuma running on EC2. All devices monitored.

Tasks:
- [x] 🤖 Docker Compose stack for EC2: Prometheus, Grafana, Loki, Uptime Kuma
- [x] 🤖 `node_exporter` on NAS *(nas2, 10.0.1.7)*
- [x] 🤖 `node_exporter` on Rambles NUC *(nuc5, 10.0.2.10 — see Milestone 8)*
- [ ] 🤖 `node_exporter` on NYC NUC *(pending NUC provisioning — Milestone 8)*
- [ ] 🤖 `snmp_exporter` for MikroTik switches and routers (both sites) *(all of NYC done: both RB5009 routers, sw-10g/CRS309, sw-main + sw-desk (Cisco SG300-10); only Rambles' CRS310 switch still pending — see docs/network-inventory.md)*
- [x] 🤖 `blackbox_exporter` on Rambles NUC *(icmp probes to 1.1.1.1/8.8.8.8 — single WAN only until Milestone 6 dual-WAN lands, then splits per-interface. NYC NUC pending Milestone 8)*
- [x] 🤖 `speedtest_exporter` on Rambles NUC *(NYC NUC pending Milestone 8)*
- [x] 🤖 Prometheus scrape configs for all exporters *(node/blackbox/speedtest for nuc5 added; nuc4/NYC jobs to follow once that NUC is installed)*
- [ ] 🤖 Grafana dashboards: NYC, Rambles, AWS, WAN status *(Router Traffic dashboard done — WAN throughput + interface status for both sites; AWS Hub dashboard done; Rambles NUC dashboard done — host metrics + WAN reachability/latency (blackbox) + speedtest throughput; NYC NUC dashboard pending Milestone 8)*
- [x] 🤖 Log collection: rsyslog + Promtail on the AWS hub, receiving from network devices *(not originally scoped, added once Loki had nothing feeding it — sw-desk, sw-main, sw-10g, nas2 all working; both RB5009 routers blocked on a RouterOS 7.19.6 bug where self-generated syslog never leaves the router, see docs/network-inventory.md)*
- [x] 🤖 Uptime Kuma monitors: all services *(15 monitors: internal + public service health, both WireGuard tunnels, all NYC/Rambles network devices — WAN connections still pending Milestones 6/7)*
- [x] 🤖 Grafana anonymous access enabled
- [x] 🤖 Alert: email via Gmail SMTP (credentials stored in SSM) *(wired up; needs a real Gmail App Password — SSM value is still a placeholder)*
- [ ] 🧑 Enable Cost Explorer in the Billing console (one-time toggle; can take up to 24h to populate history) — required before `cost-exporter` below will return data
- [x] 🤖 `cost-exporter`: polls Cost Explorer daily, feeds Prometheus/Grafana for AWS cost tracking (running + historical)

### Milestone 4 — DNS and TLS
**Goal:** All services accessible by name with valid HTTPS certs.

Tasks:
- [x] 🧑 Bill provides current hosts file IP reservations so Claude can preserve them *(docs/network-inventory.md)*
- [x] 🤖 Internal DNS records for all known hosts *(RouterOS static DNS entries per ADR-0009, not Route53 — see ADR-0006 vs ADR-0009 note below. 12 hosts across both sites, mirrored on both routers' `/ip dns static` tables so a name resolves regardless of which site you're on. Source: `docs/network-inventory.md`, committed in `routeros/nyc/initial-config.rsc` and `routeros/rambles/initial-config.rsc`)*
- [x] 🤖 Route53 records for public services (Grafana, Uptime Kuma, portal)
- [x] 🤖 Let's Encrypt cert for `grafana.billandjessie.com` (DNS-01 via Route53)
- [x] 🤖 Let's Encrypt cert for `status.billandjessie.com`
- [x] 🤖 Certbot renewal via systemd timer
- [x] 🤖 Hosts files retired at both sites *(never existed as actual OS hosts files — this was always about giving devices resolvable names, which the RouterOS static DNS entries above now do)*

### Milestone 5 — Portal
**Goal:** `billandjessie.com` live as a status/links portal.

Tasks:
- [x] 🤖 Terraform: S3 static website + CloudFront distribution
- [x] 🤖 Terraform: ACM certificate for `billandjessie.com`
- [x] 🤖 Portal HTML created under `portal/`
- [x] 🤖 GitHub Actions: deploy portal on changes to `portal/`
- [x] 🤖 Links to Grafana and Uptime Kuma working
- [x] 🤖 Network diagram page (`portal/network.html`, linked from the landing page) — NYC/Rambles/AWS hub topology, hand-maintained SVG, update when topology changes

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

### Milestone 8 — NUC Provisioning
**Goal:** Fresh Rocky Linux 10 install to fully operational NUC in one Ansible playbook run.

Tasks:
- [ ] 🧑 Install Rocky Linux 10 on NYC NUC (ISO on USB)
- [x] 🧑 Install Rocky Linux 10 on Rambles NUC *(done 2026-07-10 — nuc5, 10.0.2.10, see docs/network-inventory.md)*
- [x] 🤖 Ansible-managed SSH key access to nuc5 *(dedicated keypair, private key in SSM at `/home-platform/ansible/nuc-private-key`, passwordless sudo for `bcalaway` — see CLAUDE.md)*
- [x] 🤖 Ansible role: base system (packages, neovim via EPEL, firewalld, SELinux) *(`ansible/roles/base/`)*
- [x] 🤖 Ansible role: Docker + Docker Compose *(`ansible/roles/docker/` — Docker's `rhel/10` repo already exists)*
- [x] 🤖 Ansible role: deploy Docker Compose stacks from Git *(`ansible/roles/exporters/` deploys `compose/nuc/`)*
- [x] 🤖 Ansible role: exporters (node, blackbox, speedtest) *(same role as above — `compose/nuc/docker-compose.yml`)*
- [x] 🤖 Playbook tested: fresh install → operational in one run *(nuc5 only — confirmed idempotent on repeat runs. Control node is the EC2 hub, not a local workstation: Ansible doesn't support Windows control nodes and this box has neither WSL nor Docker, so `scripts/deploy-nucs.ps1` pushes `ansible/` + `compose/nuc/` to EC2 and triggers the run there over SSH, reusing EC2's existing WireGuard routes to both site LANs)*
- [ ] 🤖 Re-run against nuc4 (NYC) once that NUC is installed — just add it to `ansible/inventory/hosts.yml`

### Milestone 9 — Router GitOps
**Goal:** Full RouterOS configuration in Git, applied via Ansible.

Tasks:
- [ ] 🧑 First-time RB5009 setup: set IP + enable SSH via Winbox web UI (Claude provides exact values)
- [x] 🤖 Rename routers to match switch naming convention: `rt-nyc` / `rt-rambles` (was `nyc-rb5009` / `rambles-rb5009`) — done 2026-07-11: RouterOS `/system identity` (live + `.rsc`), SNMP device labels in `prometheus.yml`/`promtail-config.yaml`, Grafana `router-traffic.json`, Uptime Kuma monitors (renamed live + `setup-uptime-kuma.py`), `docs/network-inventory.md`. Note: this changes the Prometheus `device=` label, so historical router metrics before this date live under the old label name — dashboards/queries only see continuous data going forward
- [ ] 🤖 RouterOS export scripts for both sites committed to Git
- [ ] 🤖 Ansible playbook for applying RouterOS config via SSH
- [x] 🤖 DHCP reservations defined in Git *(`/ip dhcp-server lease add` entries in both `.rsc` files, kept in sync with `docs/network-inventory.md` as devices are found)*
- [x] 🤖 Internal DNS records defined in Git *(RouterOS `/ip dns static` entries, see Milestone 4)*
- [x] 🤖 WireGuard config defined in Git *(`/interface wireguard add` + peers in both `.rsc` files, see Milestone 2)*
- [ ] 🤖 Dual-WAN config defined in Git *(blocked on Milestones 6/7 hardware)*
- [ ] 🤖 GitHub Actions: RouterOS changes applied on merge (manual trigger)

### Milestone 10 — NAS Backup
**Goal:** NUC Docker volumes backed up to NAS on schedule.

Tasks:
- [ ] 🧑 Create NFS share on Synology NAS for backups
- [ ] 🤖 restic installed on NUCs via Ansible
- [ ] 🤖 NAS NFS share mounted on both NUCs (WireGuard tunnel for Rambles)
- [ ] 🤖 restic backup job: Docker volumes → NAS on cron
- [ ] 🤖 Backup metrics exposed to Prometheus
- [ ] 🤖 Grafana alert on backup failure

## Future / Deferred

- NAS-to-NAS replication (NYC → Rambles) via Synology Hyper Backup
- Second Synology NAS at Rambles
- UPS at both sites
- Environmental / temperature sensors
- Weather and external data feeds in Grafana
- VRRP dual-router per site
- MikroTik RB5009 cold spare
- Home Assistant integration
- VLAN segmentation
- Dynamic routing (BGP/OSPF between sites)
- Remote power management
- Kubernetes (if workloads grow to justify it)
