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
- [x] 🤖 `node_exporter` on NYC NUC *(nuc4, 10.0.1.34 — done 2026-07-13, see Milestone 8)*
- [ ] 🤖 `snmp_exporter` for MikroTik switches and routers (both sites) *(all of NYC done: both RB5009 routers, sw-10g/CRS309, sw-main + sw-desk (Cisco SG300-10); only Rambles' CRS310 switch still pending — see docs/network-inventory.md)*
- [x] 🤖 `blackbox_exporter` on Rambles NUC *(icmp probes to 1.1.1.1/8.8.8.8 — single WAN only until Milestone 6 dual-WAN lands, then splits per-interface. NYC NUC done 2026-07-13)*
- [x] 🤖 `speedtest_exporter` on Rambles NUC *(NYC NUC done 2026-07-13)*
- [x] 🤖 Prometheus scrape configs for all exporters *(node/blackbox/speedtest for nuc5 and nuc4 both added)*
- [x] 🤖 Grafana dashboards: NYC, Rambles, AWS, WAN status *(Router Traffic dashboard done — WAN throughput + interface status for both sites, plus WAN reachability/latency and speedtest throughput for both NYC and Rambles (NYC panels added 2026-07-13 once nuc4 existed to source them); AWS Hub dashboard done; System Overview dashboard done — merged nas2 + nuc5 + nuc4 host metrics into one dashboard with a dynamic instance dropdown)*
- [x] 🤖 Log collection: rsyslog + Promtail on the AWS hub, receiving from network devices *(not originally scoped, added once Loki had nothing feeding it — sw-desk, sw-main, sw-10g, nas2 all working; both RB5009 routers blocked on a RouterOS 7.19.6 bug where self-generated syslog never leaves the router, see docs/network-inventory.md)*
- [x] 🤖 Uptime Kuma monitors: all services *(15 monitors: internal + public service health, both WireGuard tunnels, all NYC/Rambles network devices — WAN connections still pending Milestones 6/7)*
- [x] 🤖 Grafana anonymous access enabled
- [x] 🤖 Alert: email via Gmail SMTP (credentials stored in SSM) *(fully working as of 2026-07-18 — real Gmail App Password in `/home-platform/grafana/smtp-password`, verified via a direct SMTP auth test, not just assumed. Turned out the SMTP transport being wired up wasn't the whole gap: no contact point, notification policy, or alert rule existed at all, so nothing would have fired even with a real password. Added `compose/aws/grafana/provisioning/alerting/` — a `disk-space-low` rule (>85% used on any real filesystem for 15+ min, across aws-hub/nas2/nuc4/nuc5) routed to `email-bill`, confirmed live in Grafana's Alerting UI as Provisioned)*
- [x] 🧑 Enable Cost Explorer in the Billing console *(confirmed working 2026-07-12 — cost-exporter has been polling successfully every 6h since 2026-07-11 17:29 UTC, real per-service breakdown across 11 services, month-to-date/yesterday populated. Forecast metric still unavailable — DataUnavailableException, "insufficient historical data" — expected for a freshly-enabled account, should resolve on its own as more days accumulate, not a config issue)*
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
- [x] 🧑 Install Rocky Linux 10 on NYC NUC (ISO on USB) *(done 2026-07-13 — nuc4, 10.0.1.34, see docs/network-inventory.md)*
- [x] 🧑 Install Rocky Linux 10 on Rambles NUC *(done 2026-07-10 — nuc5, 10.0.2.10, see docs/network-inventory.md)*
- [x] 🤖 Ansible-managed SSH key access to nuc5 *(dedicated keypair, private key in SSM at `/home-platform/ansible/nuc-private-key`, passwordless sudo for `bcalaway` — see CLAUDE.md)*
- [x] 🤖 Ansible role: base system (packages, neovim via EPEL, firewalld, SELinux) *(`ansible/roles/base/`)*
- [x] 🤖 Ansible role: Docker + Docker Compose *(`ansible/roles/docker/` — Docker's `rhel/10` repo already exists)*
- [x] 🤖 Ansible role: deploy Docker Compose stacks from Git *(`ansible/roles/exporters/` deploys `compose/nuc/`)*
- [x] 🤖 Ansible role: exporters (node, blackbox, speedtest) *(same role as above — `compose/nuc/docker-compose.yml`)*
- [x] 🤖 Playbook tested: fresh install → operational in one run *(nuc5 only — confirmed idempotent on repeat runs. Control node is the EC2 hub, not a local workstation: Ansible doesn't support Windows control nodes and this box has neither WSL nor Docker, so `scripts/deploy-nucs.ps1` pushes `ansible/` + `compose/nuc/` to EC2 and triggers the run there over SSH, reusing EC2's existing WireGuard routes to both site LANs)*
- [x] 🤖 Re-run against nuc4 (NYC) once that NUC is installed *(done 2026-07-13 — added to `ansible/inventory/hosts.yml`, full playbook run succeeded: 42 tasks ok, 31 changed, 0 failed. Also required fixing an unrelated EC2-side WireGuard MTU bug along the way — see Gotchas in CLAUDE.md)*

### Milestone 9 — Router GitOps
**Goal:** Full RouterOS configuration in Git, applied via Ansible.

Tasks:
- [ ] 🧑 First-time RB5009 setup: set IP + enable SSH via Winbox web UI (Claude provides exact values)
- [x] 🤖 Rename routers to match switch naming convention: `rt-nyc` / `rt-rambles` (was `nyc-rb5009` / `rambles-rb5009`) — done 2026-07-11: RouterOS `/system identity` (live + `.rsc`), SNMP device labels in `prometheus.yml`/`promtail-config.yaml`, Grafana `router-traffic.json`, Uptime Kuma monitors (renamed live + `setup-uptime-kuma.py`), `docs/network-inventory.md`. Note: this changes the Prometheus `device=` label, so historical router metrics before this date live under the old label name — dashboards/queries only see continuous data going forward
- [x] 🤖 RouterOS export scripts for both sites committed to Git *(confirmed 2026-07-18 — already satisfied, no separate export step needed. `routeros/{nyc,rambles}/initial-config.rsc` + `routeros/{nyc,rambles}/managed-config.rsc` (split 2026-07-17) ARE the desired-state export: full firewall, DHCP, DNS, WireGuard, NTP, SNMP, and syslog config for both sites, git-committed and applied via `routeros/apply-config.py` → `ansible/roles/routeros` → `ansible/routeros.yml`, triggered manually or via `.github/workflows/routeros.yml`. `routeros/nyc/sw-10g-services.rsc` (the CRS309 switch's own services hardening) is git-tracked too. "Export" here means desired-state config committed to Git, not a live pull from the routers — a MikroTik `/export` dumps live config as a script, and that's structurally what these `.rsc` files already are, just authored forward instead of pulled backward. Periodic live-config drift detection, if ever wanted, would be new undesigned scope, not this task)*
- [x] 🤖 Ansible playbook for applying RouterOS config via SSH *(done 2026-07-17 — `ansible/roles/routeros` + `ansible/routeros.yml`, wraps `routeros/apply-config.py` rather than adopting a new SSH automation path, since RouterOS's API is disabled fleet-wide. Prerequisite fix same day: the WireGuard section was non-idempotent — a full-file reapply for an unrelated one-line DNS change tore down Rambles' live tunnel. Fixed via a RouterOS `:if` guard, and split each site's config into `initial-config.rsc` (one-time bring-up only) + `managed-config.rsc` (the safely-reappliable ongoing subset). Verified via repeated live reapplies against both routers with zero tunnel drops)*
- [x] 🤖 DHCP reservations defined in Git *(`/ip dhcp-server lease add` entries in both `.rsc` files, kept in sync with `docs/network-inventory.md` as devices are found)*
- [x] 🤖 Internal DNS records defined in Git *(RouterOS `/ip dns static` entries, see Milestone 4)*
- [x] 🤖 WireGuard config defined in Git *(`/interface wireguard add` + peers in both `.rsc` files, see Milestone 2)*
- [ ] 🤖 Dual-WAN config defined in Git *(blocked on Milestones 6/7 hardware)*
- [x] 🤖 GitHub Actions: RouterOS changes applied on merge (manual trigger) *(done 2026-07-17 — `.github/workflows/routeros.yml`, `workflow_dispatch` only. Hosted runners can't reach the hub directly (security group restricted to WireGuard subnets), so it uses AWS SSM `send-command` to tell the hub to run the playbook locally, not a self-hosted runner or a widened security group. New `ansible-deploy` S3 bucket stages `ansible/`+`routeros/` for the hub to sync down. Hit and fixed two real Terraform bugs getting this applied: a circular IAM/S3 dependency (the `github_actions` role's own bucket permissions referenced the bucket's `.arn`, so Terraform needed the bucket to exist to compute the policy that would let it be created), then an IAM-propagation race once the cycle was broken (fixed with an explicit `time_sleep`). Verified end-to-end against both sites via real `workflow_dispatch` runs, tunnels never dropped)*

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

### Milestone 11 — App Platform Foundation
**Goal:** Shared services (database, auth, ingress) running on the hub and a proven CI/CD framework, ready for the first application. See `docs/adr/0014` through `docs/adr/0019` for the architecture decisions behind this milestone.

Tasks:
- [x] 🧑 Approve EC2 hub resize to `t3.medium` (small ongoing cost increase — needed for Postgres + Redis + Traefik + Authentik + app containers on top of the existing observability stack)
- [x] 🤖 Terraform: resize hub EC2 instance to `t3.medium` — done 2026-07-18 via [PR #4](https://github.com/bcalaway/nyc_pa_aws_gitops/pull/4), verified in-place update (`0 to destroy`), WireGuard tunnels and Docker stack self-recovered on boot
- [x] 🤖 Docker Compose: shared Postgres service on the hub *(ADR-0016 — one instance, per-app logical databases + least-privilege credentials)* — deployed 2026-07-18, `postgres:16`, admin credential at `/home-platform/postgres/admin-password`, no published port (compose-network-only), verified accepting connections
- [x] 🤖 Postgres backups: EBS snapshot schedule + `pg_dump`-to-S3 job — needed before any app holds non-reproducible data — deployed 2026-07-18: AWS DLM policy (daily, 7-day retention, whole root volume) + `postgres-backup` container (`pg_dumpall | gzip` daily via cron, uploaded to `s3://home-platform-logs-.../postgres-backups/`, 14-day S3 lifecycle expiration). Both verified live (`aws dlm get-lifecycle-policies` shows `ENABLED`; manually triggered `backup.sh` and confirmed the object landed in S3). Took several follow-up PRs (#7-#10) to fully sort out the `github_actions` role's IAM permissions for the new DLM resources — see CLAUDE.md gotchas. **Also added**: a `postgres-backup-stale` Grafana alert (fires if no successful backup in 3+ days, or the metric is missing entirely) via a `postgres_backup_last_success_timestamp_seconds` gauge fed through node-exporter's textfile collector. End-to-end tested for real by temporarily lowering the threshold — confirmed both the firing and resolved emails actually arrived (Bill's inbox, not just Grafana's internal state).
- [x] 🤖 `postgres_exporter` wired into the existing Prometheus/Grafana stack — deployed 2026-07-18, `postgres-exporter:9187` scraped by Prometheus, dedicated "Postgres" dashboard (up, connections, cache hit ratio, DB size, txn rate, deadlocks), verified live via grafana.billandjessie.com
- [x] 🤖 Docker Compose: Redis service *(Authentik's dependency)* — deployed 2026-07-18, `redis:7-alpine`, password from SSM (`/home-platform/authentik/redis-password`), no published port (internal-only), verified `PONG` with auth
- [x] 🤖 Docker Compose: Authentik service, own Postgres DB *(ADR-0017 — no Redis; upstream removed that dependency in 2025.10, see the ADR's "Revisited" note)* — deployed 2026-07-18, `ghcr.io/goauthentik/server:2026.2.6` (server + worker), bootstrap admin verified, public at `auth.billandjessie.com` (nginx + expanded Let's Encrypt cert, same pattern as `grafana.`/`status.`)
- [x] 🤖 Migrate Grafana from anonymous access (Milestone 3) to Authentik OIDC login — deployed 2026-07-18: OAuth2 provider + application declared as an Authentik blueprint (`compose/aws/authentik/blueprints/grafana-oidc.yaml`, GitOps-managed instead of clicked through the admin UI), Grafana's `generic_oauth` config points at it, anonymous access removed (was previously world-readable). Verified the full authorize redirect (client_id/redirect_uri/scopes all correct) reaches Authentik's real login form; native login form kept as a break-glass fallback via the existing local admin account.
- [x] 🤖 Docker Compose: Traefik service; migrate Grafana + status page routes off hand-edited nginx *(ADR-0018)* — deployed 2026-07-18, Docker-label routing, Let's Encrypt via Route53 DNS-01 (IMDS instance-role creds). Also migrated `auth.billandjessie.com` (added after the ADR was written, but nginx couldn't be fully retired without it). Verified on alternate ports first, then cut over to 80/443 with zero-surprise downtime.
- [x] 🤖 Retire nginx once Traefik is confirmed handling both existing routes — nginx and `certbot-renew.timer` disabled 2026-07-18 (kept, not deleted, as a rollback reference)
- [x] 🤖 Gate Uptime Kuma behind Authentik — not originally scoped, added after Traefik landed since Kuma has no native OIDC support (only option is Authentik's Proxy Provider forward-auth). Blueprint (`kuma-proxy.yaml`) + Traefik `forwardAuth` middleware + a dedicated router for Authentik's own `/outpost.goauthentik.io/` callback paths. Provider assigned to the Embedded Outpost and Kuma's own login disabled (both manual, no safe blueprint/API path found for either). Verified: an unauthenticated visit to `status.billandjessie.com` redirects straight to Authentik's login.
- [x] 🤖 `docs/app-platform.md`: the platform contract doc — DB provisioning, auth integration, ingress/DNS wiring, secrets convention, deploy mechanism *(ADR-0014)* — written 2026-07-24. Also surfaced one real design gap not covered by ADR-0014/0018/0019: apps need a shared Docker network (Traefik's Docker provider and Postgres/Redis hostname resolution both require it) that doesn't exist yet — `compose/aws/docker-compose.yml` currently relies on Compose's implicit per-project network. Documented as a required one-time migration to land alongside the first app's deploy (all existing containers recreate), not done speculatively in this pass. Also confirmed DNS is *not* wildcard-covered — `grafana.`/`status.`/`auth.` are each an explicit `aws_route53_record` in `terraform/aws/tls.tf`, so every new app needs one more small Terraform change here, not a free `*.billandjessie.com` match
- [x] 🤖 Terraform: per-app IAM role + OIDC trust + ECR repository, starting with the TODO app *(ADR-0019 — scoped narrowly per app, not a widened platform role)* — deployed 2026-07-24 via `terraform/aws/apps.tf`: ECR repo `todo-app`, IAM role `todo-app-github-actions` with OIDC trust scoped to `repo:bcalaway/todo-app:*`, ECR push/pull scoped to just that repo, SSM read scoped to `/home-platform/todo-app/*` plus the specific Postgres/Authentik credential paths this app will own (none provisioned yet — literal ARNs, real values land when the app itself is onboarded). Hit the same two bootstrap gaps CLAUDE.md's Gotchas already documents for this exact pattern: `github_actions` itself needed `iam:CreateRole`/`ecr:CreateRepository` added first (fixed in `iam.tf`, literal ARNs to avoid the circular-dependency trap), then a real IAM-propagation race on the very next apply (policy update and resource creation landed in the same run) — fixed by simply re-running, per the documented playbook. Both confirmed live via `aws ecr describe-repositories` / `aws iam get-role`
- [x] 🤖 Reusable CI/CD GitHub Actions workflow(s): required checks (build/test/lint) + CD (ECR push, auto-deploy or manual-promote modes) — deployed 2026-07-25: `app-ci.yml`, `app-build-push.yml`, `app-deploy.yml`, all `workflow_call`. Deploy mechanism finalized and made concrete in `docs/app-platform.md`: hosted runners stage the app's Compose fragment to the shared ansible-deploy S3 bucket (reused under `apps/<app>/`) and trigger the hub via `ssm:SendCommand`, same pattern as `routeros.yml`; the hub's own instance role reads the app's SSM secrets at deploy time and writes its `.env`, so secrets never transit the workflow, S3, or logs. Terraform grew accordingly: `todo-app-github-actions` got S3/EC2/SSM permissions for the deploy trigger, and the hub's role got a new `hub_app_deploy` policy (ECR pull + per-app SSM read, one block per app going forward). Applied cleanly (no propagation-race rerun needed this time). Note: the deploy path is unexercised until an app actually exists and the shared Docker network migration (flagged in app-platform.md's Networking section) lands — this task built the pipeline, not a live deploy
- [x] 🤖 Starter app template: Python — built 2026-07-25 at `templates/python/` in this repo (not a separate template repo — same "platform scaffolding, not app business logic" rationale as the reusable workflows). FastAPI/SQLAlchemy/Authlib/pytest/ruff, wired to `app-ci.yml`/`app-build-push.yml`/`app-deploy.yml`. Verified for real: full local venv install, `pytest` (4/4 pass), `ruff check` (clean), and a live `uvicorn` boot with all endpoints (`/health`, `/`, `/db-check`, `/login`) confirmed behaving correctly including graceful no-Postgres/no-Authentik degradation. Docker itself wasn't available locally, so the multi-stage Dockerfile build is unverified until the first real CI run
- [x] 🤖 Starter app template: C++ — built 2026-08-20 at `templates/cpp/`, alongside a new platform decision (ADR-0020) making gRPC the standard for service-to-service calls (Bill's explicit direction — this template is both a starter template and the first real implementation of that standard). Clang/CMake/vcpkg/clang-tidy/gtest, C++23, `cpp-httplib`/`libpqxx`/runtime-discovered Authentik OIDC for the browser-facing HTTP surface, `grpc`/`protobuf` for an internal-only service-to-service gRPC server on port 9090 (never routed through Traefik, same trust boundary as Postgres — see docs/app-platform.md's new "Service-to-service communication" section). Verified for real, not structurally: full `docker build --target lint`/`--target test`/final all built clean (6/6 tests, clang-tidy clean), the final image ran as a real container, and both the HTTP routes and the gRPC `Ping`/`grpc.health.v1.Health` RPCs were confirmed working via `grpcurl` against it (installed for this pass, alongside the vcpkg `libpq` build needing `bison`/`flex` added to the Dockerfile and a real CMake/clang-tidy incompatibility around C++20 module dependency scanning that had to be disabled -- both found only by actually running the build, not by reading the Dockerfile).
- [x] 🤖 Starter app template: React — built 2026-08-20 at `templates/react/`. React + Vite frontend, Express backend (serves the built frontend and the API from one process/container, matching the platform's one-container-per-app model), `pg`, `express-openid-connect` (Authentik OIDC), Vitest/Supertest/Testing Library, ESLint. Auth gating ported from the pattern just fixed live on `todo-app`/the Python template: everything except `/health`, `/login`, `/auth/callback` requires a session once real Authentik credentials are present, open otherwise. Verified for real, not just structurally — this pass required actually installing Node, Docker Desktop, and WSL2 on this machine (none were present) specifically so the multi-stage Dockerfile could be verified for real instead of carrying the Python template's "unverified until CI" caveat: `docker build --target lint`/`--target test`/final (no target) all built clean, and the final image was run as a real container and hit over HTTP (`/health`, `/db-check`, `/login` all correct; browser-rendered the working example page live-fetching from the backend). Caught and fixed two real bugs during this verification, not found by just reading the code: (1) known-vulnerable transitive esbuild/vite pulled in by the initial vitest 2.x pin, fixed by bumping to vite 8/vitest 4 (0 vulnerabilities after); (2) the standard `import.meta.url === file://${process.argv[1]}` "run as main module" idiom silently never matches on Windows (backslash paths, no leading slash), so `app.listen()` never ran and the process exited clean with no error/output -- harmless in the Linux container in production, but a real trap for any future local Windows dev session. Fixed with `pathToFileURL(process.argv[1]).href`.
- [x] 🤖 TODO app repo: scaffolded from the Python template, deployed end-to-end through the full platform (DB, auth, ingress, CI/CD) — validates the framework itself, not just the app. Completed 2026-08-14 after the `home-platform` network blocker cleared — see "TODO app: current state" below for the full verification trail.

#### TODO app: current state (as of 2026-08-14, completed)

The first real app onboarding, validating the whole Milestone 11 framework. Repo: [github.com/bcalaway/todo-app](https://github.com/bcalaway/todo-app) (public — created by Bill via the web UI, see the gotcha below on why). Local working copy at `C:\workspace\todo-app` on this machine, but nothing depends on that path — it's fully pushed, a fresh `git clone` anywhere picks up exactly where this left off.

**Done and verified:**
- App itself: scaffolded from `templates/python/`, a real CRUD todo list (SQLAlchemy model, FastAPI routes, a tiny static HTML+JS page at `/`), Authentik OIDC login wired (Pattern A). 11 tests passing locally (real CRUD logic exercised against an in-memory SQLite DB via dependency override, plus the platform-integration/degraded-mode tests from the template). `ruff` clean. Full details and rationale in the repo's own README and commit history.
- Platform-side onboarding, all three steps from `docs/app-platform.md`'s checklist:
  - Postgres: `todo-app` database + role created directly on the hub (`docker exec postgres psql`), **ownership explicitly set to the `todo-app` role** (Postgres 15+ changed default public-schema privileges — granting DB privileges alone isn't enough for the role to `CREATE TABLE` in its own database, learned this the hard way here, see the CLAUDE.md gotcha). Password in SSM (`/home-platform/postgres/todo-app-password`). Verified live: connected as the role, created and dropped a probe table.
  - Authentik: `compose/aws/authentik/blueprints/todo-app-oidc.yaml` added, client id/secret generated and stored in SSM (`/home-platform/authentik/todo-app-client-{id,secret}`), wired into `authentik-server`/`authentik-worker`'s environment and `deploy-aws-stack.ps1`. Deployed via the normal `scripts/deploy-aws-stack.ps1` path — only `authentik-server`/`authentik-worker`/`redis` recreated, everything else (Grafana, Traefik, Postgres, the observability stack) kept running uninterrupted. Verified live: blueprint shows `successful` in `authentik_blueprints_blueprintinstance`, and `https://auth.billandjessie.com/application/o/todo-app/.well-known/openid-configuration` (checked via `curl` on the hub) returns a real, correct OIDC discovery document.
  - Route53: `todo-app.billandjessie.com` A record added to `terraform/aws/tls.tf`, applied clean.
- CI/CD pipeline: pushed to `main`, `app-build-push.yml` now succeeds end-to-end (image is really in ECR) after two real bugs found and fixed on the platform side (both already committed):
  1. `todo-app-github-actions`'s OIDC trust condition didn't match — GitHub defaults newly-created repos to a different subject-claim format (`repo:OWNER@OWNER_ID/REPO@REPO_ID:...`) than this platform's existing convention (`repo:OWNER/REPO:...`), confirmed via CloudTrail. Fixed in `terraform/aws/apps.tf` by trusting both formats.
  2. `app-deploy.yml`'s hub-side script never actually created the `.env` file when an app has zero SSM secrets configured yet (a normal, valid state before/during onboarding) — `docker compose` errors if a referenced `env_file` doesn't exist at all. Fixed (`: >` instead of `rm -f`).

**Resolved 2026-08-14 — the platform-side blocker is cleared and the app is live:**

1. The shared `home-platform` Docker network (flagged back in `docs/app-platform.md`'s Networking section when it was written) now exists. Went with the scoped-down approach the paused session had queued up: `home-platform` created on the hub (`docker network create home-platform`), added as an *additional* network attachment on just `traefik`, `postgres`, and `redis` in `compose/aws/docker-compose.yml` (they keep their existing `default` network too), deployed via `scripts/deploy-aws-stack.ps1`. Only those 3 containers recreated (plus `cost-exporter`/`postgres-backup`, which `depends_on: postgres`) — the rest of the stack was untouched. Verified live: all 3 joined `home-platform`, Grafana/status/auth still resolve through Traefik, and `authentik-server` still resolves `postgres`/`redis` by hostname on the default network — the additive attachment didn't break existing connectivity.
2. `templates/python/deploy/docker-compose.yml` and `todo-app`'s own `deploy/docker-compose.yml` already both declared `home-platform: external: true` from how the template was originally written — nothing to change there.
3. Retriggered `todo-app`'s CD via a real push (empty commit, since the stored PAT can't call `workflow_dispatch` — see the gotcha below): [run 31842838775](https://github.com/bcalaway/todo-app/actions/runs/31842838775), `build-push` + `deploy` both green.
4. Verified end-to-end: container `todo-app` running on the hub, joined to `home-platform`; `https://todo-app.billandjessie.com/` returns 200; `/db-check` returns `{"connected":true}` against the real `todo-app` Postgres database; `/login` redirects to Authentik's real `/application/o/authorize/` endpoint with the correct `client_id` and callback URL. (The actual login click-through wasn't done as part of this automated pass — worth a manual once-over.)
5. This task is checked off above. The milestone as a whole stays open — C++ and React starter templates are still unbuilt.

### Milestone 12 — Hue Lighting Controller

**Goal:** A hub-based UI + per-site NUC agents giving cross-site visibility into both Hue systems (NYC and Rambles) and direct control, without replacing Hue's own automation engine — see ADR-0014/0015 for the original compute-placement reasoning, and ADR-0020 for the gRPC standard this app is the first real implementation of. MVP is read-only: see what's on, what scene is active, what automations are running. Kicking off scenes/automations, and eventually a small set of "advanced" automations Hue's own engine can't do, are later phases, not scoped as tasks yet.

Tasks:
- [x] 🧑 Architecture agreed: single `hue` repo (`hub/` Python, `agent/` C++ — precedent-setting language choice for future larger projects), gRPC between hub and agent per ADR-0020, no database for MVP (pure live pass-through, nothing stored until an advanced-automations phase actually needs it)
- [x] 🧑 NYC Hue bridge (`hue-nyc`, 10.0.1.71) local API key minted and verified live — `/home-platform/hue/nyc-api-key`
- [x] 🧑 Rambles Hue bridge (`hue-rambles`, 10.0.2.244) local API key minted and verified live — `/home-platform/hue/rambles-api-key`
- [x] 🧑 Create the `hue` GitHub repo via the web UI (the stored gh PAT can't create repos — see CLAUDE.md's Gotchas)
- [x] 🤖 Terraform: ECR repo + IAM role + OIDC trust for `hue` (`terraform/aws/apps.tf`, same pattern as `todo-app`) — applied 2026-08-20, all 4 resources confirmed live
- [x] 🤖 Terraform: `hue.billandjessie.com` Route53 record — live, confirmed resolving to the hub's Elastic IP
- [x] 🤖 Terraform: hub's `hub_app_deploy` policy grant for `hue` (ECR pull + SSM read scoped to `/home-platform/hue/*`)
- [x] 🤖 Authentik OIDC blueprint for `hue` (Pattern A, matches `todo-app`/Grafana) — deployed, `https://auth.billandjessie.com/application/o/hue/.well-known/openid-configuration` confirmed returning a real discovery document
- [x] 🤖 Scaffold `hub/` from `templates/python/` and `agent/` from `templates/cpp/`, both in the one `hue` repo — pushed to [github.com/bcalaway/hue](https://github.com/bcalaway/hue)
- [x] 🤖 Define the hub↔agent gRPC contract (`proto/`) for querying current state (lights, active scenes, active automations) — first real use of the ADR-0020 pattern beyond the C++ template's own example service. Field shapes (brightness as CLIP v2's 0-100 percentage not CLIP v1's 0-254, `scene.status.active`, `behavior_instance.enabled`/`.status`) confirmed against the real NYC bridge before finalizing, not assumed from Hue's docs
- [x] 🤖 Agent: Hue Bridge local CLIP v2 API client reading lights/scenes/automations state
- [x] 🤖 Agent: gRPC service exposing that state to the hub, internal-only on `home-platform` per ADR-0020 (never through Traefik), plus the standard `grpc.health.v1.Health` service
- [x] 🤖 Hub: UI showing current state, pulled live from the site agent via gRPC on each page load (no caching/sync needed yet — that's an "advanced automations" concern, not MVP)
- [x] 🤖 `hue`'s own thin CI/CD workflows for the hub component, calling `app-ci.yml`/`app-build-push.yml`/`app-deploy.yml` — one real bug caught by an actual failed run: `app-deploy.yml`'s `compose_file` input defaults to `deploy/docker-compose.yml`, which is wrong for a two-component repo like this one (it's at `hub/deploy/docker-compose.yml` here) and has to be passed explicitly
- [x] 🤖 Deploy path for the agent: **new platform capability, not just an app-repo concern** — built as a new `ansible/roles/hue-agent/` role, gated per-host by `hue_agent_enabled` (`inventory/hosts.yml`). The agent's image lives in its own ECR repo (`hue-agent`, one more small Terraform apply — reuses the existing `hue-github-actions` IAM role rather than a second role, since only the *deploy* path differs) and is pulled on the hub (which has AWS credentials) then relayed to the NUC as a plain `docker save`/copy/`docker load` tarball, since the NUC itself has none. Triggered manually via `scripts/deploy-nucs.ps1`, not auto-deploy-on-push, as planned
- [x] 🧑 Verify end-to-end: deployed for real to `nuc4` and confirmed working through the full production chain — `https://hue.billandjessie.com` live and gated behind Authentik (`/api/state` correctly 401s unauthenticated), the production hub container confirmed able to reach `nuc4:9090` over the network, and the real agent on `nuc4` returning real live NYC bridge data via `grpcurl`. The actual authenticated browser view is the one piece only Bill can confirm (same login-credential restriction as `todo-app`'s verification) — worth a manual look
- [x] 🤖 Extend to Rambles once its bridge key exists — same agent binary/config, deployed to `nuc5` 2026-08-21 (real bug found and fixed along the way — see CLAUDE.md's Gotchas: the hue-agent role's tarball transfer was gated only on the hub's own `docker pull` finding a newer image, so onboarding a *second* NUC with an image the hub already had cached skipped the transfer entirely and nuc5 tried and failed a direct ECR pull it has no credentials for). Verified: container running on `nuc5`, logs show `hue-agent (rambles) listening on :9090, bridge 10.0.2.244`, and the hub's real production `hue` container confirmed able to open a live TCP connection to `nuc5:9090` over the actual production path (hub → WireGuard → Rambles LAN) — same check used for `nuc4`
- [x] 🤖 Multi-site hub UI — the `hue` repo's `hub/` component was still hardcoded to a single `AGENT_HOST` (the MVP was explicitly scoped NYC-only, see the `hue` README's original Status section), so Bill only saw NYC on the live page even with `nuc5`'s agent up and reachable. Fixed 2026-08-21 in [bcalaway/hue#2c9fb5b](https://github.com/bcalaway/hue/commit/2c9fb5b): replaced the single agent config with a fixed per-site map (`AGENT_HOST_NYC`/`AGENT_HOST_RAMBLES`), `/api/state` now returns `{"sites": {site: {...}}}`, and the static UI renders one section per site. Verified against both real agents through the actual app code (not mocked) both locally and on the live deployed container (`docker exec hue python3 -c "from app.grpc_client import get_all_states; ..."`, bypassing Authentik to check server-side): `nyc` returns 16 lights/59 scenes/1 automation, `rambles` returns 43 lights/42 scenes/9 automations. `/api/state` still correctly 401s unauthenticated over the real public URL — auth gating unaffected by the change

**Milestone complete as of 2026-08-21** — both sites' Hue bridges are keyed, both agents are deployed and reachable from the hub, and the hub UI itself shows live data for both. Along the way, this pass (and the earlier `nuc4` one) fixed real bugs unrelated to `hue`'s core logic but found while extending it to a second site: `deploy-nucs.ps1` was silently continuing past failed `scp` uploads and had been running a stale copy of `ansible/` on the hub as a result; `nuc4`'s pre-existing exporter stack had a corrupted Docker network reference; the hue-agent role's image-transfer logic didn't account for onboarding a second NUC; and the hub itself was never actually built for more than one site despite the milestone's goal describing "cross-site visibility into both Hue systems" from the start. See CLAUDE.md's Gotchas for the first three.

## Future / Deferred

- NAS-to-NAS replication (NYC → Rambles) via Synology Hyper Backup *(distinct from Milestone 10's restic-based Docker-volume backups — this would be live replication between the two NAS boxes themselves, once both exist)*
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
