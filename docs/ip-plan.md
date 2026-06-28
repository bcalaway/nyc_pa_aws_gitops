# IP Plan

## Subnets

| Network | Subnet | Purpose |
|---------|--------|---------|
| NYC LAN | 10.0.1.0/24 | All NYC devices |
| Rambles LAN | 10.0.2.0/24 | All Rambles devices |
| WireGuard overlay | 10.0.3.0/24 | VPN tunnel IPs |

## WireGuard Peers

| Peer | WireGuard IP | Notes |
|------|-------------|-------|
| AWS EC2 hub | 10.0.3.1 | Elastic IP, static anchor |
| NYC RB5009 | 10.0.3.2 | Site peer |
| Rambles RB5009 | 10.0.3.3 | Site peer |
| Laptop | 10.0.3.4 | Road warrior client |

## NYC Reserved Hosts (10.0.1.x)

Existing reservations carried over from hosts file. Current names:

| Hostname | DNS Name | IP |
|----------|----------|----|
| router | router.nyc.billandjessie.com | TBD |
| printer | printer.nyc.billandjessie.com | TBD |
| nas1 | nas1.nyc.billandjessie.com | TBD |
| nas2 | nas2.nyc.billandjessie.com | TBD |
| sw-main | sw-main.nyc.billandjessie.com | TBD |
| sw-desk | sw-desk.nyc.billandjessie.com | TBD |
| sw-10g | sw-10g.nyc.billandjessie.com | TBD |
| p7670 | p7670.nyc.billandjessie.com | TBD |
| furry | furry.nyc.billandjessie.com | TBD |

> Note: Actual IPs to be filled in when migrating from hosts files. Existing IPs must be preserved.

## AWS / Public

| Service | DNS Name | IP |
|---------|----------|----|
| EC2 WireGuard hub | — | Elastic IP (assigned at deploy time) |
| Grafana | grafana.billandjessie.com | EC2 Elastic IP |
| Uptime Kuma | status.billandjessie.com | EC2 Elastic IP |
| Portal | billandjessie.com | CloudFront (managed) |

## DNS Naming Convention

```
<device>.<site>.billandjessie.com   — internal devices (private IP)
<service>.billandjessie.com         — public services (public IP)
```

Sites: `nyc`, `rambles`
