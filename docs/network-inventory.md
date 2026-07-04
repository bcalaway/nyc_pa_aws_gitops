# Network Inventory

Running list of NYC and Rambles hosts worth preserving a stable IP for — feeds
both RouterOS DHCP reservations (`routeros/*/initial-config.rsc`) and the
internal Route53 records planned for Milestone 4 (`docs/adr/0006-route53-for-dns.md`).

Add to this as IPs/MACs are learned. Once a host has both, add it as a DHCP
reservation in the relevant `.rsc` file so it survives a router rebuild.

## NYC (10.0.1.0/24)

| Hostname | IP | MAC | Status |
|----------|-----|-----|--------|
| router (RB5009 itself) | 10.0.1.1 | — | n/a — not a DHCP client |
| printer (HP-M455DN) | 10.0.1.5 | 2C:58:B9:AF:E5:8A | Reserved |
| nas1 | ? | ? | Unknown — need IP |
| nas2 (Synology) | 10.0.1.7 | 00:11:32:EA:FE:7D | Static IP on the device itself, outside the DHCP pool (10.0.1.64-254) — no router-side reservation needed. Credentials in SSM (`/home-platform/nas/nyc-nas2-*`), SNMP not yet enabled |
| sw-main (Cisco SG300-10) | 10.0.1.10 | EC:E1:A9:C5:86:0D | Static IP on the device itself, not DHCP. Credentials in SSM (`/home-platform/switch/nyc-sw-main-*`), SNMP not yet enabled |
| sw-desk (Cisco SG300-10) | 10.0.1.11 | 50:67:AE:3D:78:F5 | Static IP on the device itself, not DHCP. Credentials in SSM (`/home-platform/switch/nyc-sw-desk-*`), SNMP not currently enabled (port 161 refused connection) — needs to be turned on via the switch's web UI, no CLI/SSH access found |
| sw-10g (MikroTik CRS309-1G-8S+) | 10.0.1.12 | 08:55:31:89:55:F4 | Static IP on the device itself, not DHCP. Credentials in SSM (`/home-platform/switch/nyc-sw10g-*`). SNMP enabled and scraped by Prometheus (job=snmp, device=sw-10g) |
| p7670 (laptop) | 10.0.1.40 | 98:59:7A:F2:10:B6 | Reserved |
| furry | 10.0.1.41 | 7C:57:58:D0:17:5E | Reserved |
| nuc4 (future NYC NUC) | 10.0.1.34 | 38:FC:98:99:7E:5B | Reserved (placeholder — not deployed yet, Milestone 8) |

Other devices seen on NYC's live DHCP lease table but not yet named/tracked
(Sonos speakers, a camera NVR, smart-home devices at .64/.65/.68/.69/.71/.73/.74)
— not on Bill's original preserve list, left as ordinary dynamic leases unless
that changes.

## Rambles (10.0.2.0/24)

No reservations yet — network is brand new (RB5009 deployed 2026-07-04).
