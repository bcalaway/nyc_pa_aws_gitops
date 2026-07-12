# Network Inventory

Running list of NYC and Rambles hosts worth preserving a stable IP for — feeds
both RouterOS DHCP reservations and the internal DNS static entries
(`routeros/*/initial-config.rsc`), per [ADR-0009](adr/0009-dhcp-dns-on-router.md).
Each host is resolvable at `<hostname>.<site>.billandjessie.com` from either
site (entries are mirrored on both routers).

Add to this as IPs/MACs are learned. Once a host has both, add it as a DHCP
reservation in the relevant `.rsc` file so it survives a router rebuild.

## NYC (10.0.1.0/24)

### Switch topology

Determined 2026-07-10 by cross-referencing each switch's own MAC address table
(not just the router's, which only sees a single upstream port and can't tell
the switches apart on its own). The three switches are chained, not each on
their own router port:

```
router ether4 -- sw-main gi4 -- (Po2/LAG) -- sw-10g -- sfp-sfpplus1 -- nas2
                     |                          |
                  gi5: Sonos                 sfp-sfpplus4
                  "Main-Bedroom-2"               |
                                              sw-desk (Po1) -- gi5 -- printer
```

The Hue bridge, most Sonos speakers, and the Nighthawk AP are all reachable
via sw-main's gi4 (the same port the router is on) — meaning they're either
on other router ports directly, or behind an unmanaged switch/hub between the
router and sw-main. Not resolved as of 2026-07-10 (Bill: not sure / doesn't
matter for now). The camera NVR is the one exception confirmed on a
*different* router port (ether6) entirely, bypassing the switch chain.

**Link speeds** (verified live 2026-07-11 via `/interface ethernet monitor`
on the router/sw-10g and `show interfaces status` on the SG300s — not
assumed from the "sw-10g" name): every link in the chain is 1Gbps —
router↔sw-main, sw-main↔sw-10g (Po2 LAG), sw-10g↔sw-desk (Po1 LAG),
sw-desk↔printer, router↔NVR — **except sw-10g↔nas2**, which negotiates a
real 10Gbps over an installed SFP-10G-SR module. That's the only 10G
device actually attached to sw-10g right now.

| Hostname | IP | MAC | Status |
|----------|-----|-----|--------|
| rt-nyc (RB5009 itself) | 10.0.1.1 | — | n/a — not a DHCP client. Renamed from `nyc-rb5009` 2026-07-11 to match the switch naming convention |
| printer (HP-M455DN) | 10.0.1.5 | 2C:58:B9:AF:E5:8A | Reserved. Directly attached to sw-desk (gi5) |
| nas1 | ? | ? | Unknown — need IP |
| nas2 (Synology) | 10.0.1.7 | 00:11:32:EA:FE:7D | Static IP on the device itself, outside the DHCP pool (10.0.1.64-254) — no router-side reservation needed. Directly attached to sw-10g (sfp-sfpplus1). Credentials in SSM (`/home-platform/nas/nyc-nas2-*`). SNMP enabled (community "public", read-only, if_mib only — no CPU/disk) and scraped by Prometheus (job=snmp, device=nas2). Also runs `node_exporter` v1.8.2 directly (no Docker/Container Manager installed) at `/volume1/homes/bcalaway/node_exporter/node_exporter-1.8.2.linux-amd64/node_exporter`, scraped as job=node-exporter/instance=nas2 — real CPU/memory/disk/network data, feeds the "System Overview" Grafana dashboard (select nas2 from the instance dropdown; merged with the former standalone nuc5 dashboard 2026-07-12). DSM Task Scheduler boot-up task "node exporter" configured (owner bcalaway, verified directly in `esynoscheduler.db`) so it survives a reboot. **Security review 2026-07-11 (finding #6 — nas2 wasn't covered by the earlier router/switch/AWS pass): no config changes made, several findings reported for Bill's decision — see "nas2 security review" notes below the table** |
| sw-main (Cisco SG300-10) | 10.0.1.10 | EC:E1:A9:C5:86:0D | Static IP on the device itself, not DHCP. First switch in the chain — uplinks to router ether4 (its gi4). Credentials in SSM (`/home-platform/switch/nyc-sw-main-*`). SNMP enabled (community "public", read-only, restricted to the AWS hub 10.0.3.1 only as of 2026-07-11 — see `switches/nyc/sw-main-services.txt`) and scraped by Prometheus (job=snmp, device=sw-main). SSH also enabled. Firmware v1.3.0.62 (2013) — SG300 series is long EOL, no further patches expected |
| sw-desk (Cisco SG300-10) | 10.0.1.11 | 50:67:AE:3D:78:F5 | Static IP on the device itself, not DHCP. Last switch in the chain — uplinks to sw-10g (Po1), printer on gi5, nothing else attached. Credentials in SSM (`/home-platform/switch/nyc-sw-desk-*`). SNMP enabled (community "public", read-only, restricted to the AWS hub 10.0.3.1 only as of 2026-07-11 — see `switches/nyc/sw-desk-services.txt`) and scraped by Prometheus (job=snmp, device=sw-desk). SSH service also enabled now (was off by default) — see CLAUDE.md Gotchas for the auth quirks this device has |
| sw-10g (MikroTik CRS309-1G-8S+) | 10.0.1.12 | 08:55:31:89:55:F4 | Static IP on the device itself, not DHCP. Middle of the chain — sw-main uplinks in via a 2-port LAG (Po2 on sw-main), nas2 direct on sfp-sfpplus1, sw-desk direct on sfp-sfpplus4, furry also direct (normally off). Credentials in SSM (`/home-platform/switch/nyc-sw10g-*`). SNMP enabled and scraped by Prometheus (job=snmp, device=sw-10g). **RouterOS upgraded 6.49.15 → 6.49.20 (`stable` channel, routine same-line patch upgrade) 2026-07-11** — pre-upgrade config exported via `/export` and downloaded off-device before applying (not committed to git, no established pattern for switch backups in this repo). Reboot took roughly 7-8 minutes to come back (CRS309 physical hardware); config, bridge/interface topology, and the service hardening from `routeros/nyc/sw-10g-services.rsc` (telnet/ftp/api/api-ssl disabled, ssh/winbox/www restricted to `10.0.1.0/24,10.0.3.0/24`) all confirmed intact afterward. SNMP scraping and connectivity to nas2/sw-desk/sw-main resumed immediately |
| p7670 (laptop) | 10.0.1.40 | 98:59:7A:F2:10:B6 | Reserved |
| furry | 10.0.1.41 | 7C:57:58:D0:17:5E | Reserved. 10G, attached to sw-10g (per Bill 2026-07-11 — not verifiable via MAC tables since it's normally powered off, hence the "status=waiting, last-seen=never" DHCP lease) |
| nuc4 (future NYC NUC) | 10.0.1.34 | 38:FC:98:99:7E:5B | Reserved (placeholder — not deployed yet, Milestone 8) |
| Nighthawk RS700 (AP) | 10.0.1.2 | 94:18:65:D5:57:44 (+ 2 more radio MACs, 96:18:65:D5:57:45/46) | Static. AP mode, connect via LAN port not WAN. Reachable via sw-main gi4 — see switch topology note above |
| hue-nyc (Philips Hue Bridge) | 10.0.1.71 | 00:17:88:A9:E9:0A | Reserved 2026-07-11, DNS `hue-nyc.nyc.billandjessie.com`. Not directly on the router — arrives via ether4, same as sw-main and the Sonos/AP cluster. Final hop still unresolved (see switch topology note above) |
| Sonos "Main-Bedroom" | 10.0.1.68 | 48:E1:5C:5C:4F:76 | Dynamic DHCP lease, identified 2026-07-10. Reachable via sw-main gi4 |
| Sonos "Main-Bedroom-2" | 10.0.1.69 | 48:E1:5C:65:2A:5C | Dynamic DHCP lease, identified 2026-07-10. Directly attached to sw-main (gi5) — the one Sonos NOT behind gi4 |
| Sonos (unnamed x2) | 10.0.1.73, 10.0.1.74 | 5C:AA:FD:27:EB:50, 5C:AA:FD:27:EB:88 | Dynamic DHCP leases, hostname `SonosZP` (no room name set). Reachable via sw-main gi4 |
| Camera NVR | 10.0.1.65 | 70:DF:F7:15:D2:CB | Dynamic DHCP lease, hostname `VMS4100ATV`, class-id `IP-STB`, identified 2026-07-10. Directly wired to router ether6 — the only device confirmed *not* behind the sw-main/sw-10g/sw-desk chain |

The Sonos speakers and NVR don't have DHCP reservations or DNS entries yet —
added here for inventory/topology purposes only. Say the word if any of them
should get a stable IP + hostname too.

### nas2 security review (2026-07-11, finding #6)

Investigated via SSH through the EC2 hub (`direct-tcpip` channel to
10.0.1.7:22, matching the jump pattern used elsewhere) using the `bcalaway`
credentials from SSM. DSM 7.3.2-86009 (build date 2026/06/18). **No changes
were made** — every finding below was either already fine or judged too
ambiguous/risky to touch without Bill's go-ahead, per the conservative brief
for this pass. Verified read-only throughout: SSH access and the existing
SNMP/`node_exporter` monitoring were untouched and are still working (both
were only ever read from, never reconfigured).

- **SSH exposure**: `sshd_config` has no `AllowUsers`/`ListenAddress`
  restriction and DSM's Terminal setting has `enable_ssh: true`,
  `enable_telnet: false` (good — Telnet is off). There's no SSH-specific
  source-IP allowlist in DSM; access control for SSH is governed by the same
  DSM firewall as everything else (see next finding). `/etc/hosts.allow` and
  `/etc/hosts.deny` are both stock/empty — no tcpd-level restriction either.
  **Not changed** — tightening this meaningfully means turning on the DSM
  firewall (see below), which is a bigger, riskier change than an isolated
  SSH tweak, and the router has no port-forward to 10.0.1.7 regardless (see
  below), so SSH is not WAN-reachable via the direct path today.

- **DSM firewall (Control Panel → Security → Firewall): OFF.**
  `/usr/syno/etc/firewall.d/firewall_settings.json` shows `"status": false`,
  confirmed independently via `iptables -t filter` showing empty INPUT/
  FORWARD/OUTPUT chains (default ACCEPT, no rules at all) and via
  `SYNO.Core.Security.Firewall.Profile` (only a stock `default`/`custom`
  profile pair exists, neither active). This means there is **no IP-based
  access control at the OS level** for any DSM service (5000/5001 web UI,
  SSH, SMB/AFP/NFS, etc.) — everything currently listens on `0.0.0.0`/`:::`
  wide open, relying entirely on the LAN boundary (no WAN port-forward) for
  protection. **Not changed** — authoring DSM firewall rules risks blocking
  Plex remote streaming, file-share access, or QuickConnect if done
  incorrectly, and the task brief explicitly calls out DSM firewall rules
  affecting Plex/app functionality as off-limits without sign-off. Flagging
  as the top recommendation: enable the DSM firewall with an allow-list for
  `10.0.1.0/24,10.0.3.0/24` (matching the pattern already used for
  sw-main/sw-desk SNMP) plus whatever QuickConnect/Plex needs, ideally
  tested by Bill or with an explicit go-ahead given the family-facing risk.

- **WAN reachability of the DSM web UI**: no `dst-nat`/port-forward rule
  exists on the NYC router for 10.0.1.7 or ports 5000/5001 (checked
  `routeros/nyc/initial-config.rsc` — the only NAT rule present is the
  standard `srcnat`/masquerade for outbound traffic), so the direct
  IP:port path is not exposed. **However, QuickConnect is enabled**
  (`SYNO.Core.QuickConnect` → `"enabled": true`, `server_alias:
  "bcalaway-nas2"`, relay domain `quickconnect.to`), with the `dsm_portal`
  permission explicitly turned on alongside `mobile_apps`, `cloudstation`,
  and `file_sharing`. QuickConnect uses Synology's relay/NAT-traversal
  service to make the DSM portal reachable from the internet without any
  port-forward — functionally this **is** internet exposure of the admin
  panel, just via a different mechanism than a forwarded port. **Not
  changed** — QuickConnect may be in active use for legitimate remote
  Plex/file access by the family, so disabling it (or just the
  `dsm_portal` permission within it) needs Bill's confirmation it's safe
  to turn off first. Flagging as the second-highest-priority finding.

- **Account security**: the generic `admin` account still exists and is
  enabled — `/etc/shadow` shows a real password hash for `admin` (not
  locked/disabled), alongside the named `bcalaway` account which already
  has administrator rights (`groups=100(users),101(administrators)`).
  Per this project's convention (named personal accounts, not generic
  `admin`), `admin` should ideally be disabled — but whether anything
  (scheduled tasks, other integrations) still authenticates as `admin`
  is unknown, and the task brief says not to touch this if there's any
  ambiguity about lockout risk. **Not changed** — reporting only.
  2FA: `SYNO.Core.OTP.EnforcePolicy` shows `otp_enforce_option: "none"`
  (not enforced org-wide); per-user 2FA enrollment wasn't checked further
  since that needs each user's own DSM session, not something to probe
  via SSH. AutoBlock (DSM's brute-force lockout feature) also appears
  unconfigured — its sqlite DB (`/etc/synoautoblock.db`) only has an empty
  `AutoBlockIP` table with no rule/config tables, consistent with it
  never having been enabled. Recommend Bill enable both AutoBlock and
  2FA enforcement for admin-capable accounts when convenient; neither
  touches Plex/file-share functionality so both are likely safe self-serve
  changes, just left for Bill since they're account-security policy
  decisions rather than "obviously broken" config.

- **Patch level**: DSM 7.3.2-86009 (built 2026/06/18) — current, not EOL.
  `SYNO.Core.Upgrade.Server` check reports no update available (already on
  the latest). Auto-update config: `auto_download: true`, `upgrade_type:
  "hotfix"` — DSM auto-downloads hotfix/security-level updates already, no
  action needed.

- **Other services observed listening**: SMB (445/139), NFS (2049), AFP
  (548 v6 only), RPC (111), Plex (32400), and DSM's nginx (80/443/5000/
  5001/5357) — no FTP or WebDAV packages installed (`/var/packages/` has no
  FTP/WebDAV entries), no Telnet (confirmed disabled above). SMB config has
  `enable_ntlmv1_auth: false` (legacy insecure NTLM already off, good).
  Nothing here looks like an obviously-unused legacy service to prune —
  all observed services correspond to features in active use (Plex, file
  shares, `node_exporter`/SNMP monitoring already documented above).

## Rambles (10.0.2.0/24)

| Hostname | IP | MAC | Status |
|----------|-----|-----|--------|
| rt-rambles (RB5009 itself) | 10.0.2.1 | — | n/a — not a DHCP client. Renamed from `rambles-rb5009` 2026-07-11 to match the switch naming convention |
| kvm-nuc5 | 10.0.2.226 | 30:52:53:07:DB:22 | Reserved. Remote KVM for nuc5 (the Rambles NUC, MINISFORUM MS-01) — this is the KVM device's own IP, **not** nuc5's own network interface. Connected directly to the router, not via the switch (per Bill 2026-07-11) |
| switch (MikroTik CRS310-8G+2S+IN) | ? | CC:28:AA:3E:A7:20 (likely) | IP still unknown — no management IP found via DHCP leases, ARP, or MikroTik neighbor discovery from the router (2026-07-10). MAC is a guess: it's the one address on the router's ether3 (the trunk port carrying nearly every other Rambles device) that never took a DHCP lease and doesn't answer on any scanned IP — consistent with a switch sending STP/LLDP traffic without a working management IP, but unconfirmed. Not remotely manageable/SNMP-monitorable until its IP is set or discovered. Needs physical/console access, same as sw-desk/sw-main's initial setup at NYC — see Gotchas in CLAUDE.md. nuc5/kvm-nuc5/ZenWiFi AP are *not* behind this switch — see their own rows |
| nuc5 | 10.0.2.10 | ? | Static IP set during install (outside the DHCP pool, not a router-side reservation). Connected directly to the router, believed 10GbE (per Bill 2026-07-11, not yet independently verified). Rocky Linux 10.2 installed 2026-07-10. SSH/sudo access via key (`/home-platform/ansible/nuc-private-key`, passwordless sudo) only as of 2026-07-11 — password auth (`/home-platform/nuc/rambles-nuc5-*`) is now disabled at the OS level (see security review note below); that SSM parameter is stale for login purposes. Fully provisioned via Ansible (Milestone 8): Docker + Compose, `node_exporter`/`blackbox_exporter`/`speedtest_exporter` running (`compose/nuc/`), scraped by Prometheus on the AWS hub over WireGuard. **Security review 2026-07-11** (`ansible/roles/security/`): SSH hardened (`PasswordAuthentication no`, `PermitRootLogin no`, verified via fresh key-only connection before and after the change); `fail2ban` installed (EPEL) with an sshd jail (5 attempts/10min → 1h ban, `firewallcmd-rich-rules` banaction); `dnf-automatic` installed and enabled for security-only auto-apply updates (daily timer, not full/all-package updates); Docker daemon confirmed Unix-socket-only (`-H fd://`), no TCP exposure. **Found and fixed a real gap**: the `exporters` role's firewalld rich-rules (in the `public` zone) only govern the `INPUT` chain, but Docker publishes container ports via DNAT+`FORWARD`, and firewalld's own base `filter_FORWARD` chain unconditionally accepts DNAT'd connections (`ct status dnat accept`) ahead of any zone/policy rule — a known firewalld/Docker interaction gap (open upstream: firewalld/firewalld#1536, `StrictForwardPorts` doesn't fully cover Docker-originated DNAT). This meant ports 9100/9115/9798 were reachable from the whole Rambles LAN, not just the WireGuard subnet as intended — confirmed empirically (curl from this workstation, on the LAN but not WireGuard, successfully pulled `node_exporter` metrics). Fixed with `firewall-cmd --direct` rules in the `raw` table's `PREROUTING` chain (runs before Docker's DNAT), dropping non-10.0.3.0/24 traffic to those three ports; reverified all three ports blocked from the LAN afterward while containers/monitoring kept working. Also noted, not changed: firewalld's `public` zone lists `cockpit` as an allowed service — this is RHEL/Rocky's stock default zone config, not something Ansible added; the package isn't installed so it's currently inert, but worth knowing if cockpit is ever added later. This DNAT/firewalld gap will recur for nuc4 (NYC) once provisioned — the `security` role handles it automatically since it's now in `site.yml`. **speedtest-exporter scheduling fixed 2026-07-11**: real bandwidth tests (saturate the link for their duration) were firing roughly every 30 minutes at essentially random times, disrupting active users. `SPEEDTEST_CACHE_FOR` raised from 1800s to 86400s (24h) and paired with a `speedtest-trigger.timer` systemd unit (`ansible/roles/exporters`) that hits `/metrics` daily at 5am, which reliably wins the race against Prometheus's own 15s scraping to be the request that resets the cache each day — real tests now consistently land in this off-peak window instead of drifting. Note: this schedule isn't persisted across an exporter container restart (the exporter's cache is in-memory only), so an Ansible reprovision or host reboot will cause one off-schedule test at that moment; the next day's 5am timer re-anchors it |
| ZenWiFi AP (ASUS, mesh) | 10.0.2.251 | 10:7C:61:51:A2:50 | Main node connected directly to the router (per Bill 2026-07-11) — 3-node mesh, the other 2 nodes backhaul wirelessly. Note: this MAC showed up on the router's ether3 (the switch trunk) in the bridge table, not a dedicated port like nuc5/kvm-nuc5 — Bill says that's wrong/is likely a different mesh node being seen, so treating "directly on the router" as authoritative here rather than the bridge-table read |
| hue-rambles (Philips Hue Bridge) | 10.0.2.244 | EC:B5:FA:0F:85:97 | Reserved 2026-07-11, DNS `hue-rambles.rambles.billandjessie.com`. MAC vendor confirmed Philips Lighting BV. Directly on the router's ether6 — its own dedicated port, confirmed via the router's bridge table (nothing else shares it, same clean pattern as nuc5/ether8 and kvm-nuc5/ether7) |

Everything else on Rambles' DHCP lease table (11 phones/tablets/laptops, a
couple of AV/IoT devices, all named or unnamed personal devices) is ordinary
dynamic leases behind the switch on router ether3 — not infrastructure, not
tracked individually here.

## Log collection (syslog -> rsyslog -> Loki, see CLAUDE.md)

| Device | Status |
|--------|--------|
| sw-desk | Working |
| sw-main | Working |
| sw-10g | Working |
| nas2 | Working (DSM Log Center, BSD/RFC3164, UDP) |
| nuc5 | Working (rsyslog forwarding via `ansible/roles/logging`, applied 2026-07-11) |
| rt-nyc | Working — see note below |
| rt-rambles | Working — see note below |
| aws-hub (host journal) | Working — Promtail's `journal` scrape job reads `/var/log/journal` directly, no rsyslog hop needed |

**rt-nyc/rt-rambles note (2026-07-11):** previously documented here as broken (RouterOS 7.19.6 bug, packets never leaving the router per tcpdump/`/tool sniffer` on the LAN address). That diagnosis was based on watching the wrong source interface — the routers' self-generated syslog is actually sourced from their **WireGuard address** (10.0.3.2/10.0.3.3), not their LAN address (10.0.1.1/10.0.2.1), which makes sense since that's the interface the route to the hub goes out. Confirmed via real log content (router config-change and login/logout entries) arriving in `/var/log/network-devices/10.0.3.2.log` and `10.0.3.3.log` on the hub. Promtail now watches both the LAN-address and WireGuard-address paths for each router (the LAN-address ones are dormant no-ops). CLAUDE.md's Gotchas entry about this should be treated as superseded by this note.
