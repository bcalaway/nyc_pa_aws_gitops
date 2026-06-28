# ADR-0008: Let's Encrypt with DNS-01 Challenge for TLS

Date: 2026-06-28
Status: Accepted

## Context

Public services (Grafana, Uptime Kuma) need valid TLS certificates. Services are hosted on EC2 and should be accessible at `grafana.billandjessie.com` and `status.billandjessie.com` with trusted HTTPS — no browser warnings.

## Options Considered

**Option A: Self-signed certificates / private CA**
- No cost, full control
- Browser warnings for public-facing services
- Requires installing CA cert on every client device
- Poor user experience

**Option B: Let's Encrypt with HTTP-01 challenge**
- Free, trusted certificates
- Requires port 80 open and publicly reachable
- Renewal requires public HTTP endpoint to remain available

**Option C: Let's Encrypt with DNS-01 challenge via Route53**
- Free, trusted certificates
- No open ports required — domain ownership proven via DNS TXT record
- Certbot + Route53 plugin handles challenge automatically
- Works for both public and private-IP services
- Integrates naturally with Route53 (ADR-0006)

## Decision

Let's Encrypt with DNS-01 challenge against Route53 for all TLS certificates.

Certbot runs on EC2, uses the `certbot-dns-route53` plugin, and renews certificates automatically. No inbound HTTP port required for renewal.

## Services Covered

| Subdomain | Service |
|-----------|---------|
| `grafana.billandjessie.com` | Grafana |
| `status.billandjessie.com` | Uptime Kuma |

The portal (`billandjessie.com`) uses an ACM certificate managed by CloudFront/Terraform — Let's Encrypt is not needed there.

## Consequences

- EC2 IAM role requires Route53 record write permission for the DNS-01 challenge
- Certbot configured as a systemd timer for automatic renewal
- Certificates stored at standard Let's Encrypt paths on EC2
- Certificate renewal is fully automated — no manual intervention
