# ADR-0006: Route53 for DNS, Migrated from Network Solutions

Date: 2026-06-28
Status: Accepted

## Context

The domain `billandjessie.com` is currently registered at Network Solutions and not pointing at anything. The platform requires DNS management that integrates with Terraform for automated record creation and supports Let's Encrypt DNS-01 challenges.

## Options Considered

**Option A: Stay on Network Solutions**
- Manual DNS management via web UI
- No Terraform provider support for automated record creation
- DNS-01 challenge automation not feasible
- Poor developer experience

**Option B: Migrate to Route53**
- Full Terraform support (`aws_route53_record`)
- Native integration with Let's Encrypt DNS-01 via `certbot` + Route53 plugin
- $0.50/month per hosted zone (~$6/year)
- All infrastructure in one place (AWS)
- DNS records generated from Git

## Decision

Migrate `billandjessie.com` to Route53. Network Solutions remains the registrar but NS records point to Route53 name servers (no registrar transfer required — just update NS records).

## Naming Convention

```
<device>.<site>.billandjessie.com   — internal devices
<service>.billandjessie.com         — public services
```

Examples:
```
router.nyc.billandjessie.com        → 10.0.1.1 (private)
nas1.nyc.billandjessie.com          → 10.0.1.x (private)
router.rambles.billandjessie.com    → 10.0.2.1 (private)
grafana.billandjessie.com           → EC2 public IP
status.billandjessie.com            → EC2 public IP
billandjessie.com                   → CloudFront (portal)
plex.nyc.billandjessie.com          → 10.0.1.x (private)
```

Split-horizon: internal records resolve to private IPs. Public records limited to Grafana, Uptime Kuma, and the portal.

## Consequences

- DNS records defined in Terraform under `terraform/dns/`
- Let's Encrypt certs issued via DNS-01 challenge against Route53 (no open ports required)
- Migration requires updating NS records at Network Solutions — one-time manual step
- Existing hosts file entries (`router`, `nas1`, `nas2`, etc.) preserved at same IPs, converted to DNS records
