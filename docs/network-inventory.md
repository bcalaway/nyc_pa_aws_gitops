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
| router (RB5009 itself) | 10.0.1.1 | — | n/a — not a DHCP client |
| printer (HP-M455DN) | 10.0.1.5 | 2C:58:B9:AF:E5:8A | Reserved. Directly attached to sw-desk (gi5) |
| nas1 | ? | ? | Unknown — need IP |
| nas2 (Synology) | 10.0.1.7 | 00:11:32:EA:FE:7D | Static IP on the device itself, outside the DHCP pool (10.0.1.64-254) — no router-side reservation needed. Directly attached to sw-10g (sfp-sfpplus1). Credentials in SSM (`/home-platform/nas/nyc-nas2-*`). SNMP enabled (community "public", read-only, if_mib only — no CPU/disk) and scraped by Prometheus (job=snmp, device=nas2). Also runs `node_exporter` v1.8.2 directly (no Docker/Container Manager installed) at `/volume1/homes/bcalaway/node_exporter/node_exporter-1.8.2.linux-amd64/node_exporter`, scraped as job=node-exporter/instance=nas2 — real CPU/memory/disk/network data, feeds the "NAS2" Grafana dashboard. DSM Task Scheduler boot-up task "node exporter" configured (owner bcalaway, verified directly in `esynoscheduler.db`) so it survives a reboot |
| sw-main (Cisco SG300-10) | 10.0.1.10 | EC:E1:A9:C5:86:0D | Static IP on the device itself, not DHCP. First switch in the chain — uplinks to router ether4 (its gi4). Credentials in SSM (`/home-platform/switch/nyc-sw-main-*`). SNMP enabled (community "public", read-only) and scraped by Prometheus (job=snmp, device=sw-main). SSH also enabled |
| sw-desk (Cisco SG300-10) | 10.0.1.11 | 50:67:AE:3D:78:F5 | Static IP on the device itself, not DHCP. Last switch in the chain — uplinks to sw-10g (Po1), printer on gi5, nothing else attached. Credentials in SSM (`/home-platform/switch/nyc-sw-desk-*`). SNMP enabled (community "public", read-only) and scraped by Prometheus (job=snmp, device=sw-desk). SSH service also enabled now (was off by default) — see CLAUDE.md Gotchas for the auth quirks this device has |
| sw-10g (MikroTik CRS309-1G-8S+) | 10.0.1.12 | 08:55:31:89:55:F4 | Static IP on the device itself, not DHCP. Middle of the chain — sw-main uplinks in via a 2-port LAG (Po2 on sw-main), nas2 direct on sfp-sfpplus1, sw-desk direct on sfp-sfpplus4, furry also direct (normally off). Credentials in SSM (`/home-platform/switch/nyc-sw10g-*`). SNMP enabled and scraped by Prometheus (job=snmp, device=sw-10g) |
| p7670 (laptop) | 10.0.1.40 | 98:59:7A:F2:10:B6 | Reserved |
| furry | 10.0.1.41 | 7C:57:58:D0:17:5E | Reserved. 10G, attached to sw-10g (per Bill 2026-07-11 — not verifiable via MAC tables since it's normally powered off, hence the "status=waiting, last-seen=never" DHCP lease) |
| nuc4 (future NYC NUC) | 10.0.1.34 | 38:FC:98:99:7E:5B | Reserved (placeholder — not deployed yet, Milestone 8) |
| Nighthawk RS700 (AP) | 10.0.1.2 | 94:18:65:D5:57:44 (+ 2 more radio MACs, 96:18:65:D5:57:45/46) | Static. AP mode, connect via LAN port not WAN. Reachable via sw-main gi4 — see switch topology note above |
| Philips Hue Bridge | 10.0.1.71 | 00:17:88:A9:E9:0A | Dynamic DHCP lease (hostname `001788a9e90a`), identified 2026-07-10. Reachable via sw-main gi4 |
| Sonos "Main-Bedroom" | 10.0.1.68 | 48:E1:5C:5C:4F:76 | Dynamic DHCP lease, identified 2026-07-10. Reachable via sw-main gi4 |
| Sonos "Main-Bedroom-2" | 10.0.1.69 | 48:E1:5C:65:2A:5C | Dynamic DHCP lease, identified 2026-07-10. Directly attached to sw-main (gi5) — the one Sonos NOT behind gi4 |
| Sonos (unnamed x2) | 10.0.1.73, 10.0.1.74 | 5C:AA:FD:27:EB:50, 5C:AA:FD:27:EB:88 | Dynamic DHCP leases, hostname `SonosZP` (no room name set). Reachable via sw-main gi4 |
| Camera NVR | 10.0.1.65 | 70:DF:F7:15:D2:CB | Dynamic DHCP lease, hostname `VMS4100ATV`, class-id `IP-STB`, identified 2026-07-10. Directly wired to router ether6 — the only device confirmed *not* behind the sw-main/sw-10g/sw-desk chain |

None of the newly-identified IoT devices (Hue, Sonos, NVR) have DHCP
reservations or DNS entries yet — added here for inventory/topology purposes
only. Say the word if any of them should get a stable IP + hostname too.

## Rambles (10.0.2.0/24)

| Hostname | IP | MAC | Status |
|----------|-----|-----|--------|
| router (RB5009 itself) | 10.0.2.1 | — | n/a — not a DHCP client |
| kvm-nuc5 | 10.0.2.226 | 30:52:53:07:DB:22 | Reserved. Remote KVM for nuc5 (the Rambles NUC, MINISFORUM MS-01) — this is the KVM device's own IP, **not** nuc5's own network interface |
| switch (MikroTik CRS310-8G+2S+IN) | ? | CC:28:AA:3E:A7:20 (likely) | IP still unknown — no management IP found via DHCP leases, ARP, or MikroTik neighbor discovery from the router (2026-07-10). MAC is a guess: it's the one address on the router's ether3 (the trunk port carrying nearly every other Rambles device) that never took a DHCP lease and doesn't answer on any scanned IP — consistent with a switch sending STP/LLDP traffic without a working management IP, but unconfirmed. Passing traffic fine (nuc5/kvm-nuc5 reachable through it) but not remotely manageable/SNMP-monitorable until its IP is set or discovered. Needs physical/console access, same as sw-desk/sw-main's initial setup at NYC — see Gotchas in CLAUDE.md |
| nuc5 | 10.0.2.10 | ? | Static IP set during install (outside the DHCP pool, not a router-side reservation). Rocky Linux 10.2 installed 2026-07-10. SSH/sudo access via key (`/home-platform/ansible/nuc-private-key`, passwordless sudo) — password auth (`/home-platform/nuc/rambles-nuc5-*`) still valid too. Fully provisioned via Ansible (Milestone 8): Docker + Compose, `node_exporter`/`blackbox_exporter`/`speedtest_exporter` running (`compose/nuc/`), scraped by Prometheus on the AWS hub over WireGuard |

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
| NYC RB5009 | **Broken** — RouterOS 7.19.6 bug, syslog packets never leave the router despite the firewall counting them as sent. Confirmed via tcpdump on the hub and RouterOS's own `/tool sniffer` on the router itself |
| Rambles RB5009 | **Broken** — confirmed same bug, same RouterOS 7.19.6. sw-10g (older RouterOS 6.49.15) does NOT have this problem, so it's specific to this RouterOS version/RB5009 model, not RouterOS generally. Needs MikroTik-specific research (forum/support) to actually fix -- not something to keep guessing at |
