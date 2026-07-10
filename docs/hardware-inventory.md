# Hardware Inventory

## NYC

| Device | Model | Specs | Role | Status |
|--------|-------|-------|------|--------|
| Router | MikroTik RB5009UG+S+IN | 8x 1G + 1x 2.5G + 1x 10G SFP+ | Router, WireGuard peer, DHCP, DNS | Purchased, not yet deployed |
| Switch | MikroTik CRS309-1G-8S+IN | 8x 10G SFP+ + 1x 1G | Core switch | Deployed |
| WiFi | Netgear Nighthawk RS700 | WiFi 7 | AP mode (demoted from router) | Deployed |
| NUC | Intel NUC 11 Enthusiast NUC11PHKi7C | i7-1165G7, RTX 2060, 64GB RAM, 2TB SSD | Application server | Purchased, pending fresh OS install |
| NAS | Synology DiskStation DS1621xs+ | 6-bay | NAS, Plex, file shares | Deployed |

## Rambles

| Device | Model | Specs | Role | Status |
|--------|-------|-------|------|--------|
| Router | MikroTik RB5009UG+S+IN | 8x 1G + 1x 2.5G + 1x 10G SFP+ | Router, WireGuard peer, DHCP, DNS, dual-WAN | Purchased, not yet deployed |
| Switch | MikroTik CRS310-8G+2S+IN | 8x 1G + 2x 10G SFP+ | Core switch | Deployed |
| WiFi | ASUS ZenWiFi AX6600 | 3-node mesh, WiFi 6 | AP mode (mesh retained) | Deployed |
| NUC | MINISFORUM MS-01 | i9-13900H, 32GB RAM, 1TB SSD | Application server | Purchased, in transit |

## WAN Connections

| Site | Connection | Provider | Type | Role |
|------|------------|----------|------|------|
| NYC | FiOS | Verizon | Fiber | Primary WAN |
| NYC | Building WiFi | Building | WiFi → GL.iNet bridge | Backup WAN |
| Rambles | Cable | Blue Ridge | 2Gb Cable | Primary WAN |
| Rambles | Starlink | SpaceX | Satellite | Backup WAN (bypass mode) |

## Planned / Future

| Item | Purpose | Notes |
|------|---------|-------|
| GL.iNet travel router | NYC WAN2 bridge (building WiFi → ethernet) | ~$40-60, model TBD |
| MikroTik RB5009 (3rd unit) | Cold spare | Future |
| Second Synology NAS | Rambles NAS + NYC→Rambles replication | Future |
| Environmental sensors | Temperature, humidity monitoring | Hardware TBD |
| UPS (NYC) | Power backup | Future |
| UPS (Rambles) | Power backup | Future |
