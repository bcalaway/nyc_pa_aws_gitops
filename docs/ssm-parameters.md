# SSM parameters

Catalog of every `/home-platform/*` parameter (moved verbatim from CLAUDE.md on 2026-09-30). **Add a row here whenever a new parameter is created.** Values never go in Git.


| Path | What it is |
|------|-----------|
| `/home-platform/github/api-token` | GitHub PAT for gh CLI |
| `/home-platform/router/nyc-admin-password` | NYC RB5009 admin password |
| `/home-platform/router/rambles-admin-password` | Rambles RB5009 admin password (set when hardware arrives) |
| `/home-platform/wireguard/server-private-key` | EC2 WireGuard hub private key |
| `/home-platform/wireguard/laptop-private-key` | Laptop WireGuard client private key |
| `/home-platform/wireguard/laptop-public-key` | Laptop WireGuard client public key |
| `/home-platform/grafana/admin-password` | Grafana admin login |
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
| `/home-platform/postgres/umami-password` | Password for the `umami` Postgres role/database (Milestone 16, usage analytics) |
| `/home-platform/umami/app-secret` | Umami's `APP_SECRET` (session/auth token signing) |
| `/home-platform/umami/two-factor-encryption-key` | Umami's `TWO_FACTOR_ENCRYPTION_KEY` — a required 64-char hex string in v3, even though 2FA itself isn't used here |
| `/home-platform/authentik/home-mcp-client-id` | OAuth client ID for `home-mcp` (voice Claude's custom connector, Milestone 18/ADR-0021) — entered in claude.ai's "Add custom connector" → Advanced settings; also read by the `home-mcp-oauth` Authentik blueprint and by `home-mcp` itself (token audience check) |
| `/home-platform/authentik/home-mcp-client-secret` | Matching client secret — entered in the connector dialog only; `home-mcp` never sees it |
| `/home-platform/umami/admin-password` | Umami dashboard admin password (`analytics.billandjessie.com`), rotated from the image's default `admin`/`umami` seed on first login 2026-09-04 |
