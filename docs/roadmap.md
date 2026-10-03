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

### Milestone 19 — Security & Update Visibility
**Goal:** The weekly security review (Friday nights, emailed) and voice can see what's out of date and what happened, not just the code. See [ADR-0024](adr/0024-security-and-update-visibility.md).

Tasks:
- [x] 🤖 `update_status`: pending OS updates / reboots / AL2023 release on hub + NUCs (host timer → node-exporter textfile), OS end of life, RouterOS/RouterBOOT, DSM, SG300 firmware (snmp_exporter `versions.yml`), compose image tags vs registries
- [x] 🤖 `security_events`: 7–30 day Loki rollups (SSH, fail2ban, device logins/config changes, home-mcp audit, Traefik 4xx/5xx); Traefik access log on (4xx/5xx only)
- [x] 🤖 `github_security`: Dependabot / secret-scanning / code-scanning alerts + `main` rules
- [x] 🤖 `aws_posture`: GuardDuty + Access Analyzer (Terraform), open security groups, root/no-MFA sign-ins, old keys; hub role `hub_security_read`
- [x] 🤖 `authentik_audit`: view-only `home-mcp-audit` service account (blueprint), token generated on deploy
- [x] 🤖 `exposure_check`: weekly hub-side nmap of hub + site WAN IPs, TLS expiry; `exposure-check-now` voice job
- [x] 🤖 `security_summary` + Dependabot version updates (`.github/dependabot.yml`)
- [x] 🧑 Create the alerts-read-only GitHub token → SSM `/home-platform/github/security-read-token` (ADR-0024, "Bill's steps")
- [ ] 🧑 Turn on Dependabot alerts and CodeQL default setup on all three repos (alerts still off on todo-app as of 2026-10-02)
- [ ] 🧑 Turn on **Dependabot security updates** on all three repos — opens fix PRs for hue's and the templates' vulnerable dependencies
- [ ] 🧑 Add a passkey to `akadmin` (the only Authentik admin, no MFA); optionally `jmojo`
- [ ] 🧑 Rotate the `home-platform-admin` IAM access key (95+ days old)
- [ ] 🧑 Optional: sw-10g RouterOS 6.49.20 → 6.49.22 + RouterBOOT (NYC LAN down ~8 min); hub Amazon Linux release update (`dnf upgrade --releasever`)
- [x] 🧑 Approve Terraform, then Platform deploy (hub + NUCs)
- [x] 🤖 Verify each tool live by voice/chat; update the weekly review's prompt to use them — done 2026-10-02 (#28 deployed; all seven answer live; the scheduled Sunday review uses them)
- [x] 🤖 Follow-ups from the first live results, 2026-10-02: Authentik 2026.2.6 → 2026.2.7 → 2026.5.7 → 2026.8.3 one line at a time (#38, #39, #42); image bumps (#38); false "other user" count fixed (#41); Promtail 3.6.8 shipped without journal support and stopped all container logs ~30 min (#43 rollback), then replaced by Grafana Alloy v1.20.1 (#44); template version updates (#45); both NUCs rebooted for security updates; both RB5009s upgraded to RouterOS 7.24.5 + RouterBOOT
- [x] 🤖 IMDS finding (app containers could reach the hub role's credentials): fixed 2026-10-02 with a host-level allow-list, `compose/aws/host/imds-guard.sh` — only the hub stack's own Docker network may reach the metadata service; verified on every deploy with automatic rollback; `aws_posture` reports it

### Milestone 20 — Split GitHub Actions AWS roles (plan vs deploy) — done 2026-10-02 except one cleanup
**Goal:** A pull request can only ever *read* AWS; only an approved `production` deploy can change it.

Found 2026-10-02 by `aws_posture` (IAM Access Analyzer). The three GitHub OIDC roles (`home-platform-github-actions`, `todo-app-github-actions`, `hue-github-actions`) are pinned to their own repo, but each trusts `repo:<owner>/<repo>:*` — any branch or PR, including Dependabot's, gets the full deploy role (the platform one can change EC2, IAM roles, S3, SSM). Today only Bill, Dependabot and Claude's session can push branches, so this is hardening, not an open hole.

Design: ADR-0025 (Bill chose the full fix 2026-10-02: also move the SSM secrets out of Terraform state and replace the app roles' `AWS-RunShellScript` with fixed SSM documents).

Tasks:
- [x] 🤖 #61: read-only `home-platform-github-plan` role; `todo-app-github-preview` role + `todo-app-preview` ECR repo; fixed `<app>-deploy` / `todo-app-preview-up` / `-down` SSM documents; 21 SSM parameters removed from Terraform state (not destroyed); hub-side `--strict` preview check
- [x] 🤖 #62: workflows use the plan role (`-lock=false`), the preview role and the documents
- [x] 🤖 #63 (lockdown): app roles lose `AWS-RunShellScript` and direct SSM reads, trust narrowed to `main` + `production`; platform role drops `pull_request`; Access Analyzer archive rule for the GitHub-OIDC findings
- [x] 🧑 Merge and approve in order (#61 → #62 → #63) — all applied 2026-10-02 (#61's first apply hit IAM propagation on the new ECR repo; a re-run passed). Bill applied the archive rule to the existing findings by hand (`aws accessanalyzer apply-archive-rule`); `aws_posture` no longer lists the GitHub roles
- [x] 🧑 Tested 2026-10-02: todo-app deploy (before and after #63), hue deploy, todo-app PR #7 preview up and removed on close, Terraform PR plan under the read-only role
- [ ] 🧑 Expire the Terraform state bucket's noncurrent versions from before #61 (they still contain the secret values), or rotate those secrets over time

### Milestone 21 — Platform prep for the market data platform (its "phase 0")
**Goal:** The hub can host Airflow and several new apps safely, and onboarding an app is a registry entry instead of copied blocks and manual SQL.

Design: ADR-0026 (hub resize + memory limits), ADR-0027 (Airflow as a shared service), ADR-0028 (apps registry), ADR-0029 (split Compose file and Terraform state). The market data platform's own design lives in Bill's "Market Data Platform — Data Layer Architecture" doc; its repos (mkt-data, secmaster-svc, quote-svc, mkt-api, mkt-ui) are app repos per ADR-0014.

Tasks:
- [x] 🧑 Review and accept ADR-0026 to ADR-0029 *(accepted 2026-10-03)*
- [ ] 🤖 cAdvisor + Prometheus scrape job; a week of per-container memory data *(cAdvisor, `cadvisor` scrape job and the **Containers** Grafana dashboard added 2026-10-03; the week starts when the hub deploy lands — the dashboard's sizing table gives peak and suggested `mem_limit` per container)*
- [ ] 🤖 Resize hub to `t3.large`; set `mem_limit` on every hub service; OOM-kill and memory-pressure Grafana alerts (ADR-0026)
- [x] 🤖 Hub deploy check rejects app Compose fragments without `mem_limit`; add the step to the `docs/app-platform.md` onboarding checklist *(2026-10-03: `scripts/hub/compose-mem-check.py`, run in `app-deploy.yml` and by `app-deploy.sh` on the hub; templates start at `256m`; todo-app and hue got interim limits in their own repos first)*
- [ ] 🤖 Split `compose/aws/docker-compose.yml` into included files (ADR-0029); confirm Compose ≥ 2.20 on the hub first
- [ ] 🤖 `apps/registry.yml` + Terraform `for_each`; migrate todo-app and hue with `moved {}` (plan must show moves only) (ADR-0028)
- [ ] 🤖 Idempotent hub script for app database onboarding, run by `platform-deploy.yml` (ADR-0028)
- [ ] 🤖 Airflow service: LocalExecutor, own database, Traefik + Authentik forward-auth, metrics and logs, per-app DAG folders (ADR-0027)
- [ ] 🤖 Python template: Alembic migrations and a gRPC server with `grpc.health.v1` (ADR-0020's "add when a real caller needs it")
- [ ] 🤖 Data-quality metrics pattern documented in `docs/app-platform.md` (gauges → Prometheus → Grafana alert rules, like `postgres-backup-stale`)
- [ ] 🤖 Lambda + S3 backup-capture resources and IAM, for sources that need a capture path independent of the hub and NUCs
- [ ] 🤖 Split Terraform state into `network`, `hub`, `ci`, `edge`, one module per PR, each a no-change plan (ADR-0029) — last, after the above lands
- [ ] 🤖 home-mcp: market data status, open gaps and backfill as named tools/jobs, once mkt-data exists

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
