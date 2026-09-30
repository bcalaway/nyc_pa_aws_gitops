# Roadmap

## How work gets done

Claude writes all code and config, opens PRs, and applies changes after Bill approves.
Bill handles physical tasks and PR approvals only.

Tasks are tagged: 🧑 = Bill does this physically / approves | 🤖 = Claude does this

## Priority

Rambles WAN failover (Blue Ridge Cable → Starlink) is the near-term priority. Everything else can be built in milestone order.

Completed milestones (1–5, 8, 9, 11–17) moved to [roadmap-archive.md](roadmap-archive.md) on 2026-09-30 with their full history. This file keeps what's still in play: open loose ends from finished milestones, then the active milestones.

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

### Milestone 18 — Voice Access & Remote Builds

**Goal:** Build things by voice from the road, securely — voice Claude (Pro, custom connector) reaches a hub-hosted MCP server that reports platform status, reads project context, and dispatches coding tasks to nuc4 that end in a PR. See ADR-0021 for the design and security model. nuc4, not nuc5, is the worker: Rambles is closed Nov–Apr.

Tasks:
- [x] 🧑 Direction agreed 2026-09-30: MCP server on the hub, worker on nuc4, PR-only from voice (no voice merges yet), Pro subscription for the coding agent to start, MFA required for this app
- [x] 🤖 **Phase 1 — spike**: `home-mcp` in `compose/aws/`, `mcp.billandjessie.com` (Route53 + Traefik with Anthropic-egress `ipAllowList`), Authentik OAuth2 provider (Bill-only, MFA), bearer-token validation in the server, one read-only `platform_status` tool, tool-call audit log to Loki — deployed 2026-09-30. Verified: 15/15 local auth/protocol checks (forged/expired/wrong-user/wrong-audience tokens rejected, 401 + RFC 9728 metadata, DNS-rebinding 421); live — non-Anthropic source gets 403 at Traefik, Let's Encrypt cert issued, `home-mcp-oauth` blueprint applied (MFA stage → consent flow, `bcalaway`-only binding), Authentik discovery advertises S256 + `offline_access`, and `platform_status` returns a real summary from Prometheus/app health/cost data. MFA works by giving home-mcp its own authorization flow (Authentik runs it on every authorization), not by checking `amr` — Authentik derives `amr` from the original login, so a password-only SSO session never carries it
- [x] 🧑 Add the custom connector in claude.ai (Customize → Connectors, client ID/secret under Advanced settings) — done 2026-09-30: passkey (WebAuthn) enrolled inline via the home-mcp MFA stage, consent approved, and `platform_status` called from a claude.ai text chat. Audit entry confirmed in both the container log and Loki (`{container="home-mcp"} |= "tool_call"`: user `bcalaway`, ok, 198 ms)
- [ ] 🧑 Same test from **voice mode** while parked
- [x] 🤖 **Phase 2 — context**: slim CLAUDE.md to rules + pointers, move gotchas to `docs/gotchas.md` by area, split roadmap into active + archive; `get_context`/`search_context` tools — done 2026-09-30. All moves verbatim, script-checked (no lines lost; only cross-references rewritten): CLAUDE.md 84 KB → 8 KB (+ a "where context lives" map), 48 gotchas → `docs/gotchas.md` in 10 areas, SSM catalog → `docs/ssm-parameters.md`, topology + hub host config → `docs/platform-reference.md`, roadmap 78 KB → 8 KB active (8 loose ends carried over) + `docs/roadmap-archive.md`. `home-mcp` reads `CLAUDE.md` + `docs/**/*.md` from `main` on GitHub (public repo, no token, 10-min cache — merged doc changes appear without a redeploy); `search_context` is BM25 over heading/bullet chunks, `get_context` returns a doc or section sized for voice
- [x] 🧑 Connect the GitHub directory connector (CI/PR status by voice) — done 2026-09-30, installation scoped to "Only select repositories": `nyc_pa_aws_gitops`, `hue`, `todo-app` (add fixed-income repos as they're created). Note: this connector talks to GitHub directly, outside `home-mcp`'s controls — its write tools (merge, push, file edits) should be set to Blocked/Needs approval in claude.ai's connector settings, and phase 3's branch protection is the backstop
- [x] 🤖 **Phase 3 — coding tasks**: `start_task`/`task_status` → disposable headless-Claude-Code container on nuc4, fine-grained GitHub token scoped to app repos, branch protection on app repos' `main`, email on task start, kill switch — done 2026-09-30. `todo-app` only for now (sandbox). **First real task**: `20260930-124715-a171` → [todo-app PR #1](https://github.com/bcalaway/todo-app/pull/1) (README-only, +12 lines, 21 s, $0.05 on the Pro token); CI independently confirmed the agent's claim (22 passed, ruff clean); squid log showed egress to Anthropic + PyPI only. Verified refusals: shell-escape attempts through the forced command, non-allowlisted repo, path-traversal task id. `todo-app` `main` ruleset: no deletion/force-push, PR required (0 approvals — agent PRs are authored as Bill), `ci / Build, test, lint` required. Design details in ADR-0021's implementation notes
- [x] 🧑 Review and merge (or close) [todo-app PR #1](https://github.com/bcalaway/todo-app/pull/1) — merged by Bill 2026-09-30 16:50 UTC; CD deployed it (todo-app restarted 16:51, `/health` 200). First full loop: request → agent on nuc4 → PR → CI → human merge → auto-deploy
- [ ] 🤖 **Allow `hue` for voice tasks** — PR opened 2026-09-30: `hue` added to `VOICE_ALLOWED_REPOS` (home-mcp) and `voice_worker_allowed_repos` (nuc4). Bill already added `hue` to the agent's fine-grained GitHub token and gave its `main` the same ruleset as todo-app. `nyc_pa_aws_gitops` deliberately stays off the allowlist (ADR-0021: the agent never touches the platform repo). Limitation: the agent image is Python-only with PyPI-only egress, so it can build/test hue's hub backend but not its React frontend (npm) or C++ agent (vcpkg) — CI is their only check. After merge: 🧑 run `scripts/deploy-aws-stack.sh` (home-mcp) and `scripts/deploy-nucs.sh` (nuc4 worker config), then test with a small hue task
- [ ] 🧑 Set the GitHub connector's write tools (merge, push, file edits) to Blocked/Needs approval in claude.ai, if not done
- [ ] 🧑 First voice-driven task from the car (parked first)
- [x] 🤖 Token renewals: GitHub agent token expires **2026-12-29**, Claude token ~**2027-09-30** — surface both in `platform_status` before they lapse — done 2026-09-30: runner checks every 6 h (GitHub: real expiry from the `github-authentication-token-expiration` header, plus rejection detection; Claude: SSM LastModifiedDate + 1 year) → `dispatch.py health` → `platform_status` flags within 21 days, expired, rejected, or worker unreachable. Verified live: reports 2026-12-29 17:13 UTC / 2027-09-30 16:36 UTC, no warnings yet
- [ ] 🤖 **Phase 4 — jobs**: allowlisted named jobs (registry in Git), spoken-friendly results
- [ ] 🤖 **Phase 5 — preview environments**: per-PR temporary deployments for testing a feature before merge, torn down on merge/close

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
