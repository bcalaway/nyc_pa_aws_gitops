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
- [ ] **M14** ([Hue Control, Styling & Animations](roadmap-archive.md#milestone-14--hue-control-styling--animations)): 🤖 Find out why hue's CD build is slow and fix it *(raised 2026-10-03; it held up the M21 merge order)*. First measure which steps take the time in a recent `hub-build-push` run. Leads: every build in `app-ci.yml` and `app-build-push.yml` uses the default `type=gha` cache scope, so the lint, test and final builds (and other apps' builds) may be evicting each other's layers; a per-app, per-target `scope=` would fix that. Also check the uncached `npm ci`, the grpcio/protoc stages, and whether the frontend rebuilds when only Python changed. Any fix to the reusable workflows helps every app.
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
- [x] 🤖 home-mcp visibility for Claude *(added and done 2026-10-03, ahead of the apps registry)*: `containers` (cAdvisor: start times, memory vs limit, OOM kills), `scrape_targets` (Prometheus target health with last errors), `last_deploys` (each deploy's `result` line — hub stack's Compose version, what restarted, anything not running; NUCs; Terraform apply summary; app CDs), and `recent_logs` now covers any container Loki has seen in 24 hours. Platform deploy, `deploy-nucs-on-hub.sh` and `terraform.yml` emit the `result` annotations it reads. After merge: 🧑 approve Platform deploy, then reconnect the claude.ai connector so the new tools appear
- [x] 🤖 Resize hub to `t3.large` (ADR-0026) *(done 2026-10-03, PR #79, ahead of the limits: 8 GiB, memory 78% of 3.7 GB → ~36% of 7.6 GB. PR #78 first made every hub deploy enable host services at boot. #79 took a full root-volume snapshot before the stop/start and added `prevent_destroy` on the hub. Prometheus didn't come back after the reboot — no data lost, ~49 min metrics gap (18:32–19:21 UTC): deploys reloaded it with `docker kill -s HUP`, which Docker records as a manual stop, so `unless-stopped` skipped it at boot. Fixed in PR #80 (reload via `docker exec … kill -HUP 1`, only if it was already running); see docs/gotchas.md)*
- [ ] 🤖 After 2026-10-10, if the resized hub has been fine: remove `aws_ebs_snapshot.hub_pre_resize` and its `data.aws_ebs_volume.hub_root` lookup from `terraform/aws/ec2.tf` (deletes the one-off snapshot; DLM daily snapshots carry on). Keep `prevent_destroy` and the `depends_on` removal in the same PR
- [ ] 🤖 Set `mem_limit` on every hub service from the Containers dashboard's sizing table (once a week of cAdvisor data exists, ~2026-10-10); OOM-kill and memory-pressure Grafana alerts (ADR-0026)
- [x] 🤖 Hub deploy check rejects app Compose fragments without `mem_limit`; add the step to the `docs/app-platform.md` onboarding checklist *(2026-10-03: `scripts/hub/compose-mem-check.py`, run in `app-deploy.yml` and by `app-deploy.sh` on the hub; templates start at `256m`; todo-app and hue got interim limits in their own repos first)*
- [x] 🤖 Split `compose/aws/docker-compose.yml` into included files (ADR-0029); confirm Compose ≥ 2.20 on the hub first *(2026-10-03: `core.yml`, `observability.yml`, `web.yml`; `data.yml` arrives with Airflow. The resolved config is identical before and after, so no container recreates. `deploy-hub-stack.sh` refuses Compose < 2.20 before touching the stack and prints the hub's version on every deploy. home-mcp's `update_status` follows the includes)*
- [x] 🤖 `apps/registry.yml` + Terraform `for_each`; migrate todo-app and hue with `moved {}` (plan must show moves only) (ADR-0028) *(done 2026-10-03, PR #74; apply: 0 added, 0 changed, 0 destroyed, 14 state moves — registry drives ECR repos, app and preview roles, deploy/preview documents, the hub role's per-app grants, the CI role's ARNs and the Access Analyzer archive rule; `moved {}` blocks can be deleted in any later PR. Still hand-maintained: the per-app `AUTHENTIK_<APP>_CLIENT_*` lines in `scripts/hub/deploy-hub-stack.sh` / `scripts/deploy-aws-stack.sh` — see the Authentik item below)*
- [x] 🤖 Idempotent hub script for app database onboarding, run by `platform-deploy.yml` (ADR-0028) *(done 2026-10-03, PR #76; first run: `2 checked; unchanged: todo-app, hue; changed: none` — `scripts/hub/onboard-app-dbs.sh`, run on registry changes after the hub stack; creates missing passwords/roles/databases and public-schema ownership, verifies as the app, never drops or overwrites. Tested against a local Postgres 16 replica of todo-app/hue: no changes on the live layout.)*
- [ ] 🤖 Authentik clients from the registry: `authentik: true` apps' `AUTHENTIK_<APP>_CLIENT_*` are still listed by hand in `compose/aws/core.yml` (server + worker env), `scripts/hub/deploy-hub-stack.sh`, `scripts/deploy-aws-stack.sh`, plus a blueprint per app — generate the env (and the client ID/secret in SSM if absent) from the registry; restarts Authentik, so its own PR
- [x] 🤖 Airflow service: LocalExecutor, own database, Traefik + Authentik forward-auth, metrics and logs, per-app DAG folders (ADR-0027) *(done 2026-10-03: PR #82 (registry `platform_databases`, hub-role grants, DNS) then PR #83 (Airflow 3.3.2 in `compose/aws/data.yml`). First deploy: onboarding created the `airflow` database; 5 containers up, ~1 GB together, hub at 51%; `airflow` scrape target up; `platform_heartbeat` ran successfully at 20:18 UTC. Embedded Outpost assignment done by Bill; UI at airflow.billandjessie.com shows all four health checks green. Still to decide when mkt-data onboards: how apps deliver DAGs into `dags/<app>/`, how project secrets reach Airflow, and DockerOperator/socket isolation)*
- [x] 🤖 Python template: Alembic migrations and a gRPC server with `grpc.health.v1` (ADR-0020's "add when a real caller needs it") *(done 2026-10-03, PR #85, template CI green against Postgres 16 — Alembic with migrate-on-start and a models-vs-migrations CI check, gRPC on 9090 with the health service, and a `template-python.yml` workflow that builds the template and smoke-tests it against Postgres 16)*
- [ ] 🤖 Data-quality metrics pattern documented in `docs/app-platform.md` (gauges → Prometheus → Grafana alert rules, like `postgres-backup-stale`)
- [ ] 🤖 Lambda + S3 backup-capture resources and IAM, for sources that need a capture path independent of the hub and NUCs
- [ ] 🤖 Split Terraform state into `network`, `hub`, `ci`, `edge`, one module per PR, each a no-change plan (ADR-0029) — last, after the above lands
- [x] 🤖 GitHub repos from the registry: `terraform/github/` stack + `terraform-github.yml`, importing todo-app and hue (ADR-0030) *(done 2026-10-03, PR #86: 13 imported, 3 changed (two no-op repo re-saves, plus todo-app's `production` now gated, Bill's call). Tokens created and stored in SSM + Actions secrets. `imports.tf` removed afterwards)*
- [x] 🤖 Airflow visibility *(2026-10-03, Bill asked)*: Grafana **Airflow** dashboard (scheduler heartbeat, import errors, slots, task outcomes, run time and schedule delay per DAG, container memory) and home-mcp `airflow_status` (scheduler health, 24h results, each DAG's last success and 7-day failures; from Prometheus, no Airflow credentials), plus read-only `prometheus_query` (instant or range PromQL, max 40 series, ranges summarised) and `prometheus_metrics` (metric names by substring). After merge: 🧑 reconnect the claude.ai connector so the new tool appears
- [ ] 🤖 home-mcp: market data status, open gaps and backfill as named tools/jobs, once mkt-data exists

### Milestone 22 — Market data platform, phase 1: holiday calendars end to end
**Goal:** One vertical slice through the whole data layer before adding more sources: holiday calendars sourced, stored raw, processed, scheduled by Airflow, monitored, and on a Grafana dashboard. Scheduling and monitoring for later datasets honor these calendars.

Scope (Bill, 2026-10-03): SIFMA US bond market, Federal Reserve (FedWire/FRB holidays), NYSE. CME later.

Tasks:
- [x] 🤖 Registry entry (PR #93): repo, ECR repo, roles and database created *(2026-10-03. The first AWS apply raced the CI role's own new grant: fixed by a re-run and, for future apps, by PR #94)*
- [x] 🤖 mkt-data's first PR: `templates/python` plus the phase-1 plan *(mkt-data #1, 2026-10-03)*
- [x] 🤖 mkt-data's `github_repo_id` in the registry *(PR #95: GitHub sends the immutable-ID OIDC subject despite ADR-0030's customization, so every app now records its repo ID in a follow-up PR; docs/gotchas.md)*
- [x] 🤖 App pipelines on Airflow (ADR-0031, PR #96, accepted 2026-10-03): DAGs call the app's token-protected `/jobs` HTTP API, with no Docker socket. DAGs ship with the app's deploy into `dags/<app>/`, and a registry `airflow: true` field turns it on. PR #97 fixed the DAG file permissions (umask 077 made them unreadable to Airflow; docs/gotchas.md)
- [x] 🤖 Calendar schema and the Fed calendar end to end *(mkt-data #2 and #3, 2026-10-03/04)*:
  - Migration 0002: raw `source`/`capture` (append-only trigger)/`source_check`, plus processed `calendar`/`calendar_year`/`calendar_day` with `valid_from`/`valid_to` history.
  - FED from the Board's K.8 page.
  - DAG `mkt_data__fed_calendar`, weekly. Its first run on 2026-10-04 loaded 5 years and 50 closed weekdays.
- [x] 🤖 Airflow visibility *(PR #98, 2026-10-04)*: the Grafana **Airflow** dashboard, plus home-mcp `airflow_status`, `prometheus_query` and `prometheus_metrics` (read-only)
- [x] 🤖 Airflow metric names checked against live Prometheus *(2026-10-04)*: all names the dashboard, alerts and `airflow_status` use exist. Fixed: task slots now come from `airflow_executor_*` (the real limit of 4; `default_pool` reports 128, and `sum()` double-counted because Airflow 3 also sends each metric unlabelled); the parse-time panel now shows seconds since each file's last parse (new mapping) and total parse time, since Airflow 3's per-file timers come in inconsistent units; `airflow_status` no longer lists a blank DAG
- [x] 🤖 SIFMA-US and NYSE calendars *(mkt-data #4 and #5, 2026-10-04)*: same pattern as FED. SIFMA-US (DAG `mkt_data__sifma_calendar`) stores full closes and recommended early closes with their Eastern close time; its first run loaded 19 days (2026 covered; 2027 not published yet). NYSE (DAG `mkt_data__nyse_calendar`) stores holidays and early closes at the equities 1:00 p.m. close; its first run loaded 34 days over 2026–2028. Both parsed the real pages first time. Follow-up: swap the stand-in test fixtures for the first real captures
- [ ] 🤖 Backfill per calendar (agreed 2026-10-04: SIFMA-US to 1996, FED to 1986, NYSE to 1990; sources and plan in mkt-data `docs/backfill.md`, status in `docs/phase-1.md` step 5). Calendars can have several sources now (mkt-data #10). SIFMA-US archive 2015–2025 deployed but its first real capture fails to parse (Good Friday 2015 listed as both a full close and a noon early close); fix next, then the SIFMA 1996–2019 PDF, `FED-RULES`, `NYSE-RULES`
- [x] 🤖 home-mcp `mkt_data_captures` and `mkt_data_capture_text` *(platform #102 + mkt-data #9, 2026-10-04)*: read-only views of mkt-data's raw captures (list with an `applied` flag; one HTML capture's visible text, filtered by a phrase) through a read-only token (`/home-platform/mkt-data/read-token`, GET endpoints only). home-mcp joined `home-platform` to reach `mkt-data:8000`
- [ ] 🤖 Data-quality metrics (mkt-data exposes gauges: last capture, years covered, parse failures) and Grafana alerts; a market-data dashboard with per-calendar coverage and storage/cost; home-mcp market-data tools
- [ ] 🤖 Small follow-ups: the Python template's Authlib/httpx deprecation warning (httpx2)

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
