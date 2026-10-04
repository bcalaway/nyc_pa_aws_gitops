# SSM parameters

Catalog of every `/home-platform/*` parameter (moved verbatim from CLAUDE.md on 2026-09-30). **Add a row here whenever a new parameter is created.** Values never go in Git.

None of these are managed by Terraform. Until Milestone 20 (ADR-0025), 21 of them were declared in `terraform/aws/ssm.tf` as placeholders, which put their real values in the state file. They're now removed from state (not deleted), so create and update every parameter by hand with `aws ssm put-parameter`.


| Path | What it is |
|------|-----------|
| `/home-platform/github/api-token` | GitHub PAT for gh CLI |
| `/home-platform/router/nyc-admin-password` | NYC RB5009 admin password |
| `/home-platform/router/rambles-admin-password` | Rambles RB5009 admin password (set when hardware arrives) |
| `/home-platform/wireguard/server-private-key` | EC2 WireGuard hub private key |
| `/home-platform/wireguard/laptop-private-key` | Laptop WireGuard client private key |
| `/home-platform/wireguard/laptop-public-key` | Laptop WireGuard client public key |
| `/home-platform/grafana/admin-password` | Grafana admin login. Also read by the hub deploy, once, to create the `home-mcp` service account token below |
| `/home-platform/grafana/home-mcp-token` | Token of Grafana's `home-mcp` service account (**Viewer**), for home-mcp's `grafana_alerts`. Created by `scripts/hub/deploy-hub-stack.sh` on the first deploy that can reach Grafana, then only read. Reissue: delete the parameter, and the next deploy makes a new token (revoke the old one under Administration → Service accounts) |
| `/home-platform/grafana/smtp-password` | Grafana Gmail SMTP App Password (real value set, verified working 2026-07-18) |
| `/home-platform/uptime-kuma/admin-password` | Uptime Kuma admin login |
| `/home-platform/postgres/admin-password` | Shared Postgres instance (hub) superuser password — apps get their own per-database least-privilege credentials under this same `/home-platform/postgres/*` namespace as they're onboarded |
| `/home-platform/authentik/redis-password` | Redis (hub) password — Authentik's dependency (ADR-0017), namespaced under Authentik's own SSM path since Redis has no other consumer |
| `/home-platform/switch/nyc-sw-desk-username` | sw-desk (Cisco SG300-10, 10.0.1.11) admin username — not "admin", a personal account |
| `/home-platform/switch/nyc-sw-desk-password` | sw-desk admin password |
| `/home-platform/switch/nyc-sw-main-username` | sw-main (Cisco SG300-10, 10.0.1.10) admin username |
| `/home-platform/switch/nyc-sw-main-password` | sw-main admin password |
| `/home-platform/switch/nyc-sw10g-username` | sw-10g (MikroTik, 10.0.1.12) admin username |
| `/home-platform/switch/nyc-sw10g-password` | sw-10g admin password |
| `/home-platform/nas/nyc-nas2-username` | nas2 (Synology, 10.0.1.7) admin username |
| `/home-platform/nas/nyc-nas2-password` | nas2 admin password |
| `/home-platform/kvm/admin-password` | JetKVM web UI password — shared by both kvm-nuc4 (10.0.1.66, NYC) and kvm-nuc5 (10.0.2.226, Rambles); no separate username field, JetKVM auth is password-only |
| `/home-platform/hue/nyc-api-key` | Local CLIP API key ("username") for the NYC Hue bridge (`hue-nyc`, 10.0.1.71) — minted 2026-08-20 via `POST /api` with `devicetype=hue-controller#nyc-agent` within the ~30s window after the bridge's physical link button was pressed. Verified live against `GET /api/<key>/lights`. Same key works for both the legacy CLIP v1 endpoints (plain HTTP) and CLIP v2 (`https://<bridge-ip>/clip/v2/...`, self-signed cert, key passed as the `hue-application-key` header) — see the Hue lighting controller plan (Milestone 12, not yet written up as of this entry) |
| `/home-platform/hue/rambles-api-key` | Local CLIP API key ("username") for the Rambles Hue bridge (`hue-rambles`, 10.0.2.244) — minted 2026-08-21 via `POST /api` with `devicetype=hue-controller#rambles-agent` within the ~30s window after the bridge's physical link button was pressed. Verified live against `GET /api/<key>/lights` |
| `/home-platform/nuc/rambles-nuc5-username` | nuc5 (Rambles NUC, 10.0.2.10) SSH username (`bcalaway`) — password auth, still valid as a fallback |
| `/home-platform/nuc/rambles-nuc5-password` | nuc5 SSH/sudo password |
| `/home-platform/ansible/nuc-private-key` | SSH private key Ansible uses to manage NUCs (key-based, passwordless sudo configured for `bcalaway`) |
| `/home-platform/ansible/nuc-public-key` | Matching public key — already installed in nuc5's `authorized_keys`; add to any new NUC the same way |
| `/home-platform/github/nuc-ssh-private-key` | Shared ed25519 key for `bcalaway`'s own `git@github.com:` SSH access from the NUCs (as `~/.ssh/id_ed25519`) — registered on GitHub as "nuc key". One keypair shared across nuc4/nuc5, same pattern as the Ansible key above. Not needed on nuc4 unless its clone is switched from HTTPS to SSH — see the "New machine checklist" note |
| `/home-platform/github/nuc-ssh-public-key` | Matching public key |
| `/home-platform/rachio/api-key` | Personal API key for Bill's Rachio account (get from the Rachio app/web account settings page) — used by `rachio-exporter` (`compose/aws/rachio-exporter/`) to poll per-valve watering history for the weather dashboard |
| `/home-platform/mopeka-proxy/api-encryption-key` | ESPHome native-API noise-encryption key (44-char base64 PSK) for `mopeka-proxy-rambles` (M5Stack Atom Lite BLE→WiFi proxy, 10.0.2.127) — set by ESPHome's prebuilt "Bluetooth Proxy" firmware at flash time (2026-08-28). `mopeka-exporter` on nuc5 uses it as `noise_psk` to subscribe to forwarded BLE advertisements (Milestone 15). Fetched on the hub by `ansible/roles/mopeka-exporter` (SSM read granted to the hub role in `terraform/aws/tls.tf`) |
| `/home-platform/mopeka-proxy/api-encryption-key-2` | Same, for the second BLE proxy `mopeka-proxy-2-rambles` (10.0.2.123, added 2026-08-29 for wider tank coverage). Each web.esphome.io flash generates its own key. `ansible/roles/mopeka-exporter` reads every proxy's key listed in `inventory/hosts.yml`'s `mopeka_proxies`; grant each one to the hub role in `tls.tf` |
| `/home-platform/postgres/<app>-password` | Password for each registry app's own Postgres role/database (`database: true` in `apps/registry.yml`). Created by `scripts/hub/onboard-app-dbs.sh` on first onboarding if absent, never overwritten (ADR-0028); todo-app's and hue's were created by hand earlier |
| `/home-platform/github/terraform-admin-token` | Fine-grained PAT (all repos; Administration, Environments, Actions read/write) for `terraform/github` applies (ADR-0030). **Source of truth**; copied to the `TF_GITHUB_ADMIN_TOKEN` secret of nyc_pa_aws_gitops's `production` environment, which is what the workflow reads. No AWS role can read it |
| `/home-platform/github/terraform-read-token` | Read-only twin of the above for `terraform/github` PR plans; copied to the `TF_GITHUB_READ_TOKEN` repository secret |
| `/home-platform/postgres/airflow-password` | Airflow's metadata-database role (ADR-0027). A registry `platform_databases` entry, created by `scripts/hub/onboard-app-dbs.sh`, read into the hub stack's `.env` |
| `/home-platform/airflow/fernet-key` | Airflow's Fernet key (encrypts connections and variables in its database). Generated by `scripts/hub/deploy-hub-stack.sh` on the first deploy that needs it; **never rotate without re-encrypting** (`airflow rotate-fernet-key`) |
| `/home-platform/airflow/api-secret-key` | Airflow API server's secret key. Generated by `deploy-hub-stack.sh` |
| `/home-platform/airflow/jwt-secret` | Airflow's JWT signing secret (API server and Execution API). Generated by `deploy-hub-stack.sh` |
| `/home-platform/<app>/airflow-token` | Per-app job token for registry apps with `airflow: true` (ADR-0031): the app gets it as `AIRFLOW_TOKEN` (its deploy's path read) and requires it on `/jobs/*`; Airflow's scheduler gets it in `AIRFLOW_CONN_<APP>`. Generated by `deploy-hub-stack.sh`. Currently: `mkt-data` |
| `/home-platform/mkt-data/read-token` | Read-only token for mkt-data's GET job endpoints (captures, capture text, business-day): home-mcp gets it as `MKT_DATA_READ_TOKEN` for `mkt_data_captures` / `mkt_data_capture_text`, and mkt-data as `READ_TOKEN` (its deploy's path read). Can't start captures or reparses. Generated by `deploy-hub-stack.sh` |
| `/home-platform/postgres/umami-password` | Password for the `umami` Postgres role/database (Milestone 16, usage analytics) |
| `/home-platform/umami/app-secret` | Umami's `APP_SECRET` (session/auth token signing) |
| `/home-platform/umami/two-factor-encryption-key` | Umami's `TWO_FACTOR_ENCRYPTION_KEY` — a required 64-char hex string in v3, even though 2FA itself isn't used here |
| `/home-platform/authentik/home-mcp-client-id` | OAuth client ID for `home-mcp` (voice Claude's custom connector, Milestone 18/ADR-0021) — entered in claude.ai's "Add custom connector" → Advanced settings; also read by the `home-mcp-oauth` Authentik blueprint and by `home-mcp` itself (token audience check) |
| `/home-platform/authentik/home-mcp-client-secret` | Matching client secret — entered in the connector dialog only; `home-mcp` never sees it |
| `/home-platform/umami/admin-password` | Umami dashboard admin password (`analytics.billandjessie.com`), rotated from the image's default `admin`/`umami` seed on first login 2026-09-04 |
| `/home-platform/github/coding-agent-token` | Fine-grained PAT (`home-mcp-coding-agent`) for the voice coding worker on nuc4 (Milestone 18, ADR-0021): **`todo-app` and `hue`** (hue added 2026-09-30), Contents + Pull requests read/write, no admin/workflows. **Expires 2026-12-29** — regenerate with the same settings and `--overwrite`. Used only by the worker's runner (never inside the agent container); installed to `/etc/voice-worker/github-token` by `ansible/roles/voice-worker` |
| `/home-platform/github/voice-jobs-token` | Fine-grained PAT (`home-mcp-voice-jobs`) for home-mcp's `run_job` (Milestone 18 phase 4, ADR-0022): **`nyc_pa_aws_gitops` only, Actions: Read and write** (+ Metadata: Read), nothing else, so it can start `voice-job.yml` but can't change code, merge or approve deployments. One-year expiry; `platform_status` warns 21 days ahead. Optional: deploys write `none` until it exists, and voice jobs report "not set up". Read by `scripts/hub/deploy-hub-stack.sh` (hub role, `hub_platform_deploy`) and `scripts/deploy-aws-stack.*` into home-mcp's `.env` |
| `/home-platform/claude/code-oauth-token` | Claude Code OAuth token from `claude setup-token` (Bill's Pro subscription, starts `sk-ant-oat01-`) for the headless agent. **Valid 1 year from 2026-09-30.** Passed to the agent container per task via `--env-file`; only egress it can use is the squid allowlist |
| `/home-platform/voice-worker/ssh-private-key` | home-mcp's SSH key for `voiceworker@nuc4` — works only for the forced command (`dispatch.py`) and only from `10.0.3.1`. Read by `scripts/deploy-aws-stack.*` into home-mcp's env (base64). **No passphrase** — generate from Git Bash, not PowerShell (see docs/gotchas.md) |
| `/home-platform/voice-worker/ssh-public-key` | Matching public key; `ansible/roles/voice-worker` writes it into `voiceworker`'s `authorized_keys` with the `restrict,from=,command=` options |
| `/home-platform/github/security-read-token` | Fine-grained PAT (`home-mcp-security-read`) for home-mcp's `github_security` (Milestone 19, ADR-0024): **`nyc_pa_aws_gitops`, `todo-app`, `hue`**, read-only **Dependabot alerts, Secret scanning alerts, Code scanning alerts** (+ Metadata: Read), nothing else. One-year expiry. Optional: deploys write `none` until it exists, and `github_security` says alerts aren't set up (branch rules still work, they're public). Read by `scripts/hub/deploy-hub-stack.sh` (hub role, `hub_platform_deploy`) and `scripts/deploy-aws-stack.*` into home-mcp's `.env` |
| `/home-platform/authentik/home-mcp-audit-token` | API token key for Authentik's read-only `home-mcp-audit` service account (Milestone 19, ADR-0024, `blueprints/home-mcp-audit.yaml`), used by home-mcp's `authentik_audit`. **Generated automatically** (64 hex chars) by the first hub deploy that needs it — `deploy-hub-stack.sh`'s `audit_token`; the hub role can `PutParameter` on this one path only. Rotate: delete the parameter and redeploy the hub |
