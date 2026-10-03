# Platform reference

Network topology and the EC2 hub's ingress/host-level configuration (moved verbatim from CLAUDE.md on 2026-09-30). Much of the hub's host config is **not tracked in Git** -- redo it by hand if the instance is ever rebuilt.

Seasonality: the Rambles site is closed **November through April**. Year-round workloads go on nuc4 (NYC), not nuc5.

## Network topology

- NYC RB5009 (`/system identity` = `rt-nyc`, renamed 2026-07-11): LAN 10.0.1.1/24, WireGuard 10.0.3.2
- Rambles RB5009 (`/system identity` = `rt-rambles`, renamed 2026-07-11): LAN 10.0.2.1/24, WireGuard 10.0.3.3
- EC2 WireGuard hub: 10.0.3.1 (interface ens5, not eth0)
- Laptop: WireGuard 10.0.3.4 (re-provisioned 2026-07-07 — see CLAUDE.md's "EC2 access")
- Nighthawk RS700: genuinely AP mode (confirmed live 2026-09-29 — see docs/gotchas.md) at 10.0.1.2, router-side DHCP reservation (not self-assigned static). Uplink cabled into a LAN port, not WAN
- ZenWiFi AX6600 (Rambles): converted to AP mode 2026-07-04, hangs off the RB5009 same as the RS700 pattern
- Both routers' `forward` chains trust each other's LAN subnet (not just the WireGuard subnet) — real cross-site LAN traffic works, not just router-to-router. See docs/gotchas.md for why this wasn't originally obvious.
- **Site WAN egress (public) IPs**, measured 2026-08-27, both cross-checked against the hub's own WireGuard peer endpoints (`wg show` on the hub) — residential/dynamic, expect drift: NYC (Verizon FiOS) `173.68.62.107`, Rambles (Blue Ridge Cable) `204.186.165.69`. The `hue` app consumes these as `SITE_WAN_IP_NYC`/`SITE_WAN_IP_RAMBLES` in the `hue` repo's `hub/deploy/docker-compose.yml` to auto-select its site dropdown (see the Traefik section's "Telling which site a browser is on" note). Rambles' value will change once Starlink failover (Milestone 6) lands — likely CGNAT with no stable IP.
- Each router's own admin services (`www`/`www-ssl`/`winbox`) trust the *other* site's LAN too, as of 2026-07-11 — e.g. rt-nyc's web UI/Winbox is reachable from `10.0.1.0/24` (its own LAN), `10.0.2.0/24` (Rambles LAN), and `10.0.3.0/24` (WireGuard), and rt-rambles mirrors that. `ssh` was deliberately left scoped to own-LAN + WireGuard only (not widened) — this was specifically about the web/Winbox admin UI, per Bill's request. **Two separate ACLs had to be widened, not just one** — the `/ip service set ... address=` restriction on the service itself is necessary but not sufficient; each router's own `/ip firewall filter chain=input` also has its own LAN/WireGuard-only accept rules ending in a catch-all drop, and that chain governs traffic destined *to the router itself* (distinct from the `forward` chain, which only governs traffic passing *through* it to other LAN hosts). Widening only the service ACL and not the input-chain rule silently does nothing — the packets get dropped by the firewall before reaching the service layer. Added a `cross-site-lan` accept rule (source = the other site's LAN) to both routers' input chains, placed before `drop-input`.

## Ingress / TLS on EC2 hub (Traefik, since 2026-07-18)

Traefik replaced hand-edited nginx as ingress (Milestone 11, ADR-0018) — this is now tracked in Git (the `traefik` service in `compose/aws/core.yml`) instead of host-level config, closing the "redo manually if the instance is ever rebuilt" gap the old nginx setup had.

- Routes are declared as Docker labels on each service (`grafana`, `uptime-kuma`, `authentik-server` in the hub Compose files under `compose/aws/`) — a new app gets routing for free by adding its own `traefik.*` labels, no manual hub-side edit or PR against this repo needed per app (the actual point of ADR-0018)
- `providers.docker.exposedByDefault=false` — a service is only routed if it explicitly opts in with `traefik.enable=true`; being on the same compose network isn't enough
- **Gotcha, confirmed live 2026-07-18**: `exposedByDefault=false` means Traefik ignores *all* labels on a non-enabled container, not just router creation — a shared middleware defined only on the `traefik` container's own labels (`hsts`) silently failed to register (`middleware "hsts@docker" does not exist"`) until `traefik.enable=true` was added to that container too, even though it has no router of its own
- TLS via Let's Encrypt DNS-01 through the `route53` certificate resolver — no static AWS keys, falls back to the hub's own IMDS instance-role credentials (same `home-platform-hub` role, same Route53-write-on-our-zone scope, that certbot used to use)
- Cutover sequence used (and the template for any future ingress change): stood Traefik up on alternate ports (8080/8443) first, confirmed real Let's Encrypt certs issued and routing correct via `curl --resolve` against those alternate ports with nginx still holding 80/443, *then* stopped nginx and switched Traefik to 80/443 — never ran both bound to the same ports
- nginx and `certbot-renew.timer` are now `disabled` (not removed — kept as a rollback reference for a bit). If reviving nginx is ever needed, its old config is still findable in CLAUDE.md's git history (see the pre-2026-07-18 version) and at `/etc/nginx/conf.d/home-platform.conf` on the hub itself
- HSTS (`max-age=31536000; includeSubDomains`) applied via a shared `hsts` middleware, referenced by each router as `hsts@docker`
- **Telling which site a browser is on, from a hub-served app:** every app is reached through the one public endpoint, so the hub never sees a client's LAN address. To vary behavior per site (first done for `hue`'s site dropdown, 2026-08-27), an app reads the client's public IP from `X-Forwarded-For` (Traefik sets it) and matches it against the known per-site WAN egress IPs (see "Network topology" above). Best-effort only — those IPs are dynamic, and a CGNAT'd WAN (Rambles once Starlink failover lands) has no stable value — so an unrecognised IP must degrade gracefully, never hard-fail. **Split-horizon DNS was considered and rejected** for this: pointing `<app>.billandjessie.com` at `10.0.3.1` on the site routers makes the hostname resolve to an address that only works on specific LANs, which breaks a phone that roams onto cellular between sites (iOS caches the private A record past its TTL and then can't load the app off-LAN at all).

## Syslog receiver on EC2 hub

Also host-level, not tracked in Git (same caveat as nginx/certbot above).

- `rsyslog` (native package, not containerized) listens on UDP 514, config at `/etc/rsyslog.d/network-devices.conf`
- Writes one file per source IP to `/var/log/network-devices/<ip>.log` — the log shipper (Grafana Alloy since 2026-10-02, Promtail before that; `compose/aws/alloy/config.alloy`) bind-mounts that directory read-only and tails it, with one explicit `static_configs` entry per known device mapping IP → friendly device name (see `compose/aws/promtail/promtail-config.yaml`)
- rsyslog owns port 514 natively; Promtail's container does **not** publish that port (it did originally, using Promtail's own built-in syslog receiver, but that only supports RFC5424 and choked on RouterOS/Cisco's legacy BSD syslog — see docs/gotchas.md)
- Devices are pointed at `10.0.3.1:514` (the hub's WireGuard IP) via each device's own remote-syslog config — RouterOS `/system logging`, Cisco `logging host`, Synology DSM's Log Center

## Host-level security on EC2 hub

Also host-level, not tracked in Git (same caveat as nginx/certbot and rsyslog above). Reviewed and hardened 2026-07-11 as a follow-up to the AWS-level security group/IAM review (see recent git log) — that review covered the network perimeter only, not the instance itself.

- **SSH (`/etc/ssh/sshd_config`)**: `PasswordAuthentication no`, `PermitRootLogin without-password` (key-only, no root password path), `PubkeyAuthentication yes`, `KbdInteractiveAuthentication no` — this is AL2023's out-of-the-box cloud-init default from the AMI, not something added manually. Confirmed via `sshd -T`, not just by reading the file.
- **fail2ban**: installed 2026-07-11 (`dnf install fail2ban`, package is in the base `amazonlinux` repo, no EPEL needed). Config at `/etc/fail2ban/jail.local` (local override, `jail.conf` untouched) — `sshd` jail only, `maxretry=5`, `findtime=10m`, `bantime=1h`, `backend=systemd`. Deliberately does **not** whitelist the site LAN/WireGuard subnets in `ignoreip` (only `127.0.0.1`/`::1`) — SSH is already restricted to those subnets at the security-group level, so whitelisting them there too would make the jail a no-op; the point is defense-in-depth against a compromised/misbehaving internal host or leaked key. Ban action is the default `iptables-multiport`, which inserts its own dedicated chain and does not conflict with Docker's iptables-managed chains (`DOCKER`, `DOCKER-USER`, `DOCKER-ISOLATION-STAGE-*`) — verified both chain sets coexist after enabling. `systemctl enable --now fail2ban`.
- **firewalld**: pulled in as a dependency of the fail2ban package (AL2023's fail2ban RPM depends on `firewalld`/`nftables`, even though the jail itself is configured to use `iptables-multiport`, not firewalld, as the ban action). It was NOT started, and was explicitly `systemctl disable`d so it can't accidentally activate on a future reboot and reconflict with Docker's iptables rules. There is otherwise **no host-level firewall** — the AWS security group (`terraform/aws/security_groups.tf`) is the sole perimeter control, which is an intentional, acceptable pattern for this box and was left as-is (adding firewalld/nftables rules on top risks breaking Docker's own iptables-based container networking and was out of scope for this pass).
- **Docker port exposure**: `docker ps` / `ss -tlnp` confirmed every container publishes its port on `0.0.0.0` (Docker's default `docker-proxy` behavior) — node-exporter 9100, snmp-exporter 9116, prometheus 9090, cost-exporter 9199, loki 3100, grafana 3000, uptime-kuma 3001, matching the hub Compose files exactly, nothing extra. Actual internet reachability is gated entirely by the security group: only 80, 443, 51820 (WireGuard) are open to `0.0.0.0/0`; 3001 (Uptime Kuma), 9090 (Prometheus), 3100 (Loki) are scoped to `10.0.3.0/24`; and 3000/9100/9116/9199 aren't opened in the security group at all, so they're unreachable from outside despite the container binding to `0.0.0.0`. No mismatch found.
- **nginx (`/etc/nginx/conf.d/home-platform.conf`)**: confirmed it only proxies `grafana.billandjessie.com` → `127.0.0.1:3000` and `status.billandjessie.com` → `127.0.0.1:3001`, nothing else. Both HTTPS server blocks send HSTS. No explicit `ssl_protocols`/`ssl_ciphers` directive, so it runs on nginx's compiled default; confirmed nginx version is 1.30.2 (modern default is TLSv1.2+TLSv1.3 only), so this is fine as-is.
- **Unattended security updates**: `dnf-automatic` was not installed; installed 2026-07-11. Configured in `/etc/dnf/automatic.conf` for **security updates only** (`upgrade_type = security`, `apply_updates = yes`, `download_updates = yes`) rather than the package default of all-updates. `systemctl enable --now dnf-automatic.timer` (runs once daily).
- **auditd**: already installed, active and enabled by default on this AMI. Not modified.
- **journald**: persistent logging already enabled (`/var/log/journal` exists and is populated). Not modified.
- No unexpected local logins found in `last`/`wtmp` — only the instance's own boot record.

## Hub host units (Milestone 19, ADR-0024)

Unlike the rest of this section's hand-made host config, these are installed from Git: `compose/aws/host/install.sh` runs on every hub deploy (`scripts/hub/deploy-hub-stack.sh`, and the manual `scripts/deploy-aws-stack.*`). It installs `nmap` and `dnf-plugins-core`, copies the scripts to root-owned `/usr/local/lib/home-platform/`, and enables:

- **Boot safety** (2026-10-03): every hub deploy runs `systemctl enable` (no restart) on the host-level services that predate Git tracking — `docker`, `wg-quick@wg0`, `rsyslog`, `fail2ban`, `amazon-ssm-agent`, `dnf-automatic.timer` — so a stop/start or reboot brings them back. The deploy's `RESULT` line reports which were already enabled, newly enabled or missing
- `host-update-metrics.timer` (every 6 h): pending updates, reboot needed and AL2023 release → `host_updates.prom` in the stack's `backup-metrics` volume (node-exporter's textfile dir). The NUCs get the same timer from `ansible/roles/exporters`, writing to `/var/lib/node_exporter/textfile`
- `imds-guard.timer` (boot + hourly, and on every deploy): only the hub stack's own Docker network may reach the EC2 metadata service (the hub role's credentials); app containers on `home-platform` are dropped by the `IMDS-GUARD` iptables chain. Self-verifying with automatic rollback; result in `hub_imds_guard_active`. Details in `compose/aws/host/imds-guard.sh` and ADR-0024
- `exposure-check.timer` (Fridays 21:30 UTC, ahead of the Friday-night security review): nmap of the hub's public IP and both sites' WAN IPs → `/var/lib/home-platform/exposure/latest.json` (read-only into home-mcp) + `exposure.prom`. Run on demand with `systemctl start exposure-check` or the `exposure-check-now` voice job


## Hub stack layout (ADR-0029, since 2026-10-03)

`compose/aws/docker-compose.yml` is only the entry point: it `include`s the service groups and defines every volume and network once.

| File | Services |
|------|----------|
| `core.yml` | Traefik, Authentik (server + worker), Postgres, postgres-backup, Redis, home-mcp |
| `observability.yml` | Prometheus, Loki, Alloy, Grafana, Uptime Kuma, cAdvisor, node/snmp/cost/rachio/postgres/redis exporters |
| `web.yml` | Umami |
| `data.yml` | Airflow (ADR-0027), once it lands |

A new shared service goes in the group that matches its role; a new group is one more `include` line. Relative paths in an included file resolve from `compose/aws/`, as before. The stack still deploys as one project (`compose-aws`), so container and volume names are unchanged. `include` needs Compose ≥ 2.20, which `scripts/hub/deploy-hub-stack.sh` checks before every deploy.
