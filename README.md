# Home Platform Architecture

Version 0.2 (Draft)

Author: Bill Calaway

---

# Vision

Create a highly reliable, reproducible, GitOps-managed home infrastructure spanning two physical locations:

* NYC (`10.0.1.x`)
* Rambles (`10.0.2.x`)

using AWS as a cloud control plane.

The entire platform should be:

* Infrastructure as Code
* Reproducible
* Observable
* Well documented
* Easy to recover from hardware failures
* Expandable over many years

The GitHub repository is the source of truth.

---

# High Level Goals

## Reliability

The network should continue operating when:

* an ISP fails
* a VPN tunnel fails
* AWS becomes unavailable
* a router fails (future)
* a Linux NUC fails
* a switch reboots

The goal is graceful degradation rather than catastrophic failure.

---

## GitOps

Everything practical should be defined in Git.

Examples:

* AWS infrastructure
* DNS
* DHCP
* Router configuration
* Linux configuration
* Monitoring
* Alerting
* Dashboards
* Documentation
* Recovery procedures

Configuration changes should occur through Pull Requests with manual approval before apply.

Claude AI acts as the primary implementer — writing Terraform, Ansible, RouterOS config, and Docker Compose definitions, opening PRs, and applying changes after approval. Bill approves PRs and handles physical tasks only.

---

## Observability

The entire platform should be observable.

Metrics:

* Prometheus (hosted on AWS EC2)

Dashboards:

* Grafana (public HTTPS via `grafana.billandjessie.com`, anonymous access enabled)
* Uptime Kuma (public status page via `status.billandjessie.com`)
* Portal landing page via `billandjessie.com` (S3 + CloudFront)

Logs:

* Loki

Long-term storage:

* S3

Alerts:

* Grafana Alerting → email (Gmail SMTP)

---

# IP Addressing

| Site    | Subnet      |
|---------|-------------|
| NYC     | 10.0.1.0/24 |
| Rambles | 10.0.2.0/24 |
| WireGuard overlay | 10.0.3.0/24 |

WireGuard peer assignments:

* `10.0.3.1` — AWS hub
* `10.0.3.2` — NYC
* `10.0.3.3` — Rambles

Reserved host assignments within each site subnet carry over from existing configuration.

---

# DNS

Domain: `billandjessie.com`

Registrar: GoDaddy (migrate to Route53)

Hosted zone: AWS Route53

Naming convention:

```
<device>.<site>.billandjessie.com
```

Examples:

```
router.nyc.billandjessie.com
nas1.nyc.billandjessie.com
router.rambles.billandjessie.com
grafana.billandjessie.com
```

DNS records are generated from Git via Terraform.

Split-horizon: internal records resolve to private IPs. Public records limited to specific services (Grafana, etc.).

TLS certificates: Let's Encrypt via DNS-01 challenge against Route53. No public-facing ports required.

---

# Sites

## NYC

Internet

* Verizon FiOS (primary WAN)

Backup Internet

* Building WiFi → GL.iNet travel router (bridge to ethernet) → RB5009 WAN2

Router

* MikroTik RB5009 (replacing Nighthawk)

Switch

* MikroTik CRS309-1G-8S+IN (10Gb)

WiFi

* Netgear Nighthawk RS700 (AP mode)

Server

* Intel NUC 11 Enthusiast (NUC11PHKi7C)
  * Intel Core i7-1165G7
  * NVIDIA RTX 2060
  * 64GB RAM
  * 2TB SSD
  * OS: Rocky Linux 10

Storage

* Synology DiskStation DS1621xs+ (6-bay NAS)
  * Runs: Plex and other existing services
  * Monitored via node_exporter (Docker)

---

## Rambles

Internet

* Blue Ridge, 2Gb Cable (primary WAN)

Backup Internet

* Starlink (secondary WAN, bypass mode enabled)

Router

* MikroTik RB5009 (replacing ASUS as router)

Switch

* MikroTik CRS310-8G+2S+IN

WiFi

* ASUS ZenWiFi AX6600 3-node mesh (AP mode)

Server

* MINISFORUM MS-01
  * Intel Core i9-13900H
  * 32GB RAM
  * 1TB SSD
  * OS: Rocky Linux 10

---

## AWS

Purpose: cloud control plane

Region: us-east-1

Infrastructure:

* EC2 instance (single, non-HA to start)
  * WireGuard hub
  * Grafana
  * Prometheus
  * Loki
  * Docker Compose managed
* Elastic IP (static anchor for WireGuard peers)
* S3 (log archive, backups)
* Route53 (billandjessie.com hosted zone)
* SSM Parameter Store (secrets)

AWS is NOT intended to become the default Internet gateway.

Only infrastructure traffic traverses AWS.

---

# Networking Philosophy

Internet traffic remains local.

NYC → Internet uses FiOS, not NYC → AWS → Internet.

Rambles → Internet uses Blue Ridge Cable or Starlink.

AWS carries:

* Site-to-site traffic (via WireGuard)
* Monitoring and metrics
* Logging
* Administration

---

# WAN Failover

## Rambles

Primary: Blue Ridge, 2Gb Cable

Secondary: Starlink (ethernet adapter, bypass mode)

The RB5009 monitors both WANs and fails over automatically via RouterOS dual-WAN policy routing. Failover is transparent to clients.

Starlink bypass mode disables Starlink's built-in NAT so the RB5009 receives a routable IP and fully controls routing.

## NYC

Primary: Verizon FiOS

Secondary: Building WiFi via GL.iNet travel router (client bridge → ethernet WAN2)

Same RB5009 dual-WAN failover as Rambles.

---

# WireGuard Topology

Hub-and-spoke. AWS EC2 (Elastic IP) is the hub.

| Peer | Type | WireGuard IP | Notes |
|------|------|--------------|-------|
| AWS EC2 | Hub | 10.0.3.1 | Elastic IP, static anchor |
| NYC RB5009 | Site peer | 10.0.3.2 | Covers all NYC devices |
| Rambles RB5009 | Site peer | 10.0.3.3 | Covers all Rambles devices |
| Laptop | Road warrior | 10.0.3.4 | WireGuard client, remote access only |

Site-to-site: WireGuard runs on the RB5009 at each site. All devices on the local network get full access to both sites and AWS transparently — no client software required on phones, PCs, or any home device.

Road warrior: WireGuard client on laptop only, for access when away from both sites. Connects to AWS hub and gets full access to both site subnets.

Both site peers initiate outbound to the hub — dynamic residential IPs are not a problem.

---

# Router Philosophy

MikroTik RB5009 handles routing at both sites.

Existing consumer hardware (Nighthawk, ASUS) demoted to AP mode.

Switches remain switches.

Linux NUCs run application workloads.

Routing does not depend on a Linux server.

DHCP and DNS served by the router (Tier 1 — survives NUC failure).

---

# NUC Philosophy

NUCs are application nodes, not infrastructure.

Provisioned with Ansible from a fresh Rocky Linux 10 install.

Workloads run as Docker Compose stacks defined in Git.

Goal: a new or reformatted NUC reaches full operation in a small number of commands.

NUC storage:

* OS and Docker volumes on local SSD
* Ephemeral data (Prometheus TSDB, Loki cache) stays local
* Persistent data backs up to NYC NAS via restic

NUCs are treated as stateless where possible. Losing a NUC should require only reprovisioning, not data recovery.

---

# Availability Tiers

Tier 1 — Must survive NUC or AWS failure:

* Internet
* WiFi
* DHCP
* DNS
* Routing
* WAN failover

Tier 2 — Temporary outage acceptable:

* WireGuard tunnel
* Monitoring
* SSH

Tier 3 — Developer / optional services:

* CI/CD
* Experiments
* Containers

---

# Observability

## Metrics

Prometheus on AWS EC2 scrapes exporters at both sites through the WireGuard tunnel.

Exporters:

* `node_exporter` — NUCs and NAS (Docker)
* `snmp_exporter` — MikroTik switches and routers
* `blackbox_exporter` — WAN health probes (latency, packet loss) per interface
* `speedtest_exporter` — periodic throughput tests per WAN interface
* WireGuard metrics

### WAN Monitoring

All 4 internet connections are monitored continuously and independently, regardless of which is active as the primary at each site:

| Site    | Connection      | Interface |
|---------|-----------------|-----------|
| NYC     | Verizon FiOS    | WAN1      |
| NYC     | Building WiFi   | WAN2      |
| Rambles | Blue Ridge Cable | WAN1     |
| Rambles | Starlink        | WAN2      |

`blackbox_exporter` uses policy routing to force probes out each WAN interface independently. This gives continuous uptime, latency, and packet loss metrics for every connection regardless of failover state.

`speedtest_exporter` runs periodic throughput tests per interface on a schedule.

Metrics exposed per WAN connection:

* Uptime / availability
* Latency (ms)
* Packet loss (%)
* Throughput (Mbps up/down)

A small metrics gap is expected on a NUC during WireGuard tunnel failover (typically seconds). This is acceptable for a home setup.

## Web Properties

### `billandjessie.com` — Portal

Static landing page hosted on S3 + CloudFront.

Links to:
* Grafana
* Uptime Kuma status page
* Other services as they are added

Stays up independently of EC2.

### `grafana.billandjessie.com` — Main Dashboard

Grafana on EC2. Anonymous access enabled (no login required).

Single pane of glass covering:

NYC:
* FiOS / Building WiFi WAN status
* Router (RB5009)
* Switch (CRS309)
* NUC
* Synology NAS
* Plex

Rambles:
* Blue Ridge Cable / Starlink WAN status
* Router (RB5009)
* Switch (CRS310)
* ASUS WiFi
* NUC

AWS:
* EC2
* WireGuard
* Grafana / Prometheus / Loki
* S3

Deployments:
* Recent GitHub Actions runs
* Recent deployments
* Recent alerts

Future (when sensors are added):
* Temperature — indoor/outdoor per site
* Environmental sensors
* Weather overlays (NYC and Rambles)
* External event feeds

### `status.billandjessie.com` — Uptime Kuma

Purpose-built status page showing up/down for all services and WAN connections.

Runs on EC2 via Docker Compose.

Serves as a canary — visible even when Grafana or other services are degraded.

## Logs

Loki on AWS EC2.

Sources:
* Router logs (MikroTik syslog)
* Linux logs (NUCs)
* Docker logs
* WireGuard logs

Archive: S3

## Alerts

Grafana Alerting → Gmail SMTP

---

# Secret Management

AWS SSM Parameter Store.

Secrets referenced in Terraform and Ansible via SSM lookups.

No secrets in Git.

---

# Division of Labor

## Bill's responsibilities (physical and approvals only)

- Physical: rack hardware, connect cables, power on devices
- First boot: set root password, connect device to network
- Bootstrap: run a single curl-to-shell script Claude provides
- RB5009 first-time: minimal web UI config (IP + enable SSH), then hand off
- PR approvals: click approve in GitHub for any change Claude opens
- Always approve explicitly: firewall rule changes, DNS changes, anything that costs money in AWS

## Claude's responsibilities (everything else)

- Write and apply all Terraform, Ansible, RouterOS config, Docker Compose
- Open PRs for every change
- Apply changes after PR approval
- Monitor health after changes
- Stop and notify Bill if something fails — never attempt blind recovery
- Notify Bill via email and Grafana annotation after autonomous changes

---

# Deployment Workflow

```
Claude writes code / config
↓
Claude opens Pull Request
↓
GitHub Actions: Terraform Plan (auto)
↓
Plan posted as PR comment
↓
Bill approves PR
↓
GitHub Actions: Terraform Apply / Ansible / RouterOS push
↓
Health Checks
↓
Grafana Annotation + Email notification
↓
Claude reports result
```

GitHub Actions authenticates to AWS via OIDC (no long-lived access keys).

Claude uses AWS credentials directly in sessions for interactive work and bootstrapping.

Changes to firewall rules, DNS records, and AWS-cost-incurring resources always require explicit PR approval — never applied automatically.

---

# Repository Structure

```
home-platform/
├── README.md
├── docs/
│   ├── architecture/
│   ├── runbooks/
│   ├── recovery/
│   ├── hardware-inventory.md
│   ├── ip-plan.md
│   └── adr/
├── terraform/
│   ├── aws/
│   └── dns/
├── ansible/
│   ├── playbooks/
│   └── roles/
├── routeros/
│   ├── nyc/
│   └── rambles/
├── compose/
│   ├── aws/
│   ├── nyc/
│   └── rambles/
├── monitoring/
│   ├── prometheus/
│   └── grafana/
├── dns/
├── scripts/
└── .github/
    └── workflows/
```

---

# Long-Term Vision

The repository should be capable of rebuilding the entire platform from scratch.

Replacing a failed router:

```
Install replacement RB5009
↓
Bootstrap (minimal manual config)
↓
Ansible pulls configuration from Git
↓
WireGuard tunnel joins
↓
Monitoring resumes
↓
Operational
```

Same philosophy applies to Linux NUCs and AWS EC2.

---

# Planned Milestones

1. **AWS foundation** — Terraform: VPC, EC2, Elastic IP, Route53, SSM, S3, IAM/OIDC for GitHub Actions
2. **WireGuard hub** — EC2 WireGuard server, both sites connected
3. **Observability stack** — Prometheus, Grafana, Loki, Uptime Kuma on EC2 via Docker Compose; exporters on NUCs and NAS
4. **DNS migration** — billandjessie.com moved to Route53, records in Terraform
5. **TLS** — Let's Encrypt certs for Grafana, Uptime Kuma, and other public services
6. **Portal** — `billandjessie.com` landing page on S3 + CloudFront
7. **Rambles WAN failover** — RB5009 dual-WAN with Blue Ridge Cable primary, Starlink secondary *(priority)*
8. **NYC WAN failover** — RB5009 dual-WAN with FiOS primary, GL.iNet/building WiFi secondary
9. **NUC provisioning** — Rocky Linux 10, Ansible playbooks, Docker Compose stacks
10. **Router GitOps** — RouterOS config in Git, applied via Ansible
11. **NAS backup** — restic from NUCs to NAS on schedule
12. **Sensors** — temperature and environmental monitoring (future, hardware TBD)

---

# Open Questions

* VLAN design (deferred — flat network to start)
* Dynamic routing between sites (deferred)
* Remote power management
* Certificate management for internal services
* NAS backup retention policy
* Starlink bypass mode compatibility verification
* GL.iNet model selection for NYC backup WAN

---

# Success Criteria

The platform is considered complete when:

* Entire infrastructure is defined in Git
* Changes occur via Pull Requests with audit trail
* Every device is monitored in Grafana
* WAN failover is automatic at both sites
* Recovery from hardware failure requires only reprovisioning from Git
* AWS provides observability but is not an Internet bottleneck
* DNS replaces all hosts files
* Rebuilding a router or NUC requires minimal manual work
