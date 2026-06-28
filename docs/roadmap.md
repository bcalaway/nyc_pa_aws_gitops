# Roadmap

## Priority

Rambles WAN failover (Cable → Starlink) is the near-term priority. Everything else can be built in milestone order.

## Milestones

### Milestone 1 — AWS Foundation
**Goal:** AWS account configured, all base infrastructure in Terraform, GitHub Actions pipeline working.

Tasks:
- [ ] AWS CLI installed and configured (local and on NUCs)
- [ ] IAM: admin user for bootstrapping, OIDC trust for GitHub Actions
- [ ] Terraform bootstrap: S3 state bucket + DynamoDB lock table (manual, one-time)
- [ ] Terraform: VPC, subnets, security groups
- [ ] Terraform: EC2 instance (Amazon Linux 2023 or Ubuntu), Elastic IP
- [ ] Terraform: S3 buckets (log archive, portal)
- [ ] Terraform: Route53 hosted zone for `billandjessie.com`
- [ ] Terraform: SSM Parameter Store baseline
- [ ] GitHub Actions: `terraform plan` on PR, `terraform apply` on merge with manual approval
- [ ] GitHub Actions: `terraform plan` output posted as PR comment
- [ ] DNS: update NS records at Network Solutions to point to Route53

### Milestone 2 — WireGuard Hub
**Goal:** Both sites connected to AWS hub via WireGuard. Site-to-site traffic working.

Tasks:
- [ ] WireGuard installed on EC2
- [ ] WireGuard server config (hub, 3 peers: NYC, Rambles, laptop)
- [ ] Keys generated, stored in SSM Parameter Store
- [ ] NYC RB5009 deployed, WireGuard client configured
- [ ] Rambles RB5009 deployed, WireGuard client configured
- [ ] Laptop WireGuard client configured
- [ ] Verify: NYC → Rambles connectivity
- [ ] Verify: Both sites → EC2 connectivity
- [ ] RouterOS configs committed to `routeros/`

### Milestone 3 — Observability Stack
**Goal:** Prometheus, Grafana, Loki, Uptime Kuma running on EC2. All devices monitored.

Tasks:
- [ ] Docker Compose stack for EC2: Prometheus, Grafana, Loki, Uptime Kuma
- [ ] `node_exporter` on NYC NUC and NAS
- [ ] `node_exporter` on Rambles NUC
- [ ] `snmp_exporter` for MikroTik switches and routers (both sites)
- [ ] `blackbox_exporter` on both NUCs — all 4 WAN connections probed independently
- [ ] `speedtest_exporter` on both NUCs — periodic throughput tests per WAN interface
- [ ] Prometheus scrape configs for all exporters
- [ ] Grafana dashboards: NYC, Rambles, AWS, WAN status
- [ ] Uptime Kuma monitors: all services and WAN connections
- [ ] Grafana anonymous access enabled
- [ ] Alert: email via Gmail SMTP

### Milestone 4 — DNS and TLS
**Goal:** All services accessible by name with valid HTTPS certs.

Tasks:
- [ ] Route53 records for all internal hosts (from existing hosts files)
- [ ] Route53 records for public services (Grafana, Uptime Kuma, portal)
- [ ] Let's Encrypt cert for `grafana.billandjessie.com` (DNS-01 via Route53)
- [ ] Let's Encrypt cert for `status.billandjessie.com`
- [ ] Certbot renewal via systemd timer
- [ ] Hosts files retired at both sites

### Milestone 5 — Portal
**Goal:** `billandjessie.com` live as a status/links portal.

Tasks:
- [ ] Terraform: S3 static website + CloudFront distribution
- [ ] Terraform: ACM certificate for `billandjessie.com`
- [ ] Portal HTML created under `portal/`
- [ ] GitHub Actions: deploy portal on changes to `portal/`
- [ ] Links to Grafana and Uptime Kuma working

### Milestone 6 — Rambles WAN Failover *(priority)*
**Goal:** Automatic failover between Cable and Starlink at Rambles.

Tasks:
- [ ] Starlink connected to RB5009 WAN2 (ethernet adapter)
- [ ] Starlink bypass mode enabled
- [ ] RouterOS dual-WAN policy routing configured
- [ ] Failover tested: unplug Cable → Starlink takes over automatically
- [ ] Both WAN connections monitored independently in Grafana
- [ ] Config committed to `routeros/rambles/`

### Milestone 7 — NYC WAN Failover
**Goal:** Automatic failover between FiOS and building WiFi at NYC.

Tasks:
- [ ] GL.iNet travel router purchased and configured (building WiFi → ethernet)
- [ ] GL.iNet connected to RB5009 WAN2
- [ ] RouterOS dual-WAN policy routing configured
- [ ] Failover tested
- [ ] Config committed to `routeros/nyc/`

### Milestone 8 — NUC Provisioning
**Goal:** Fresh Rocky Linux 9 install to fully operational NUC in one Ansible playbook run.

Tasks:
- [ ] Rocky Linux 9 installed on NYC NUC
- [ ] Rocky Linux 9 installed on Rambles NUC (when it arrives)
- [ ] Ansible role: base system (packages, neovim, firewalld, SELinux)
- [ ] Ansible role: Docker + Docker Compose
- [ ] Ansible role: deploy Docker Compose stacks from Git
- [ ] Ansible role: node_exporter, blackbox_exporter, speedtest_exporter
- [ ] Playbook tested: fresh install → operational in one run

### Milestone 9 — Router GitOps
**Goal:** Full RouterOS configuration in Git, applied via Ansible.

Tasks:
- [ ] RouterOS export scripts for both sites committed to Git
- [ ] Ansible playbook for applying RouterOS config via SSH
- [ ] DHCP reservations defined in Git
- [ ] Internal DNS records defined in Git
- [ ] WireGuard config defined in Git
- [ ] Dual-WAN config defined in Git
- [ ] GitHub Actions: RouterOS changes applied on merge (manual trigger)

### Milestone 10 — NAS Backup
**Goal:** NUC Docker volumes backed up to NAS on schedule.

Tasks:
- [ ] restic installed on NUCs
- [ ] NAS share mounted on both NUCs via NFS (through WireGuard tunnel for Rambles)
- [ ] restic backup job: Docker volumes → NAS
- [ ] Backup runs on cron, metrics exposed to Prometheus
- [ ] Grafana alert on backup failure

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
