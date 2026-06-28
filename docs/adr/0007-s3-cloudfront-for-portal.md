# ADR-0007: S3 + CloudFront for Portal Landing Page

Date: 2026-06-28
Status: Accepted

## Context

`billandjessie.com` needs a landing page that links to Grafana, Uptime Kuma, and other services. The page itself does not need to be dynamic — it is a portal with links, not an application.

## Options Considered

**Option A: Serve from nginx on EC2**
- Simple — same instance as Grafana
- Landing page goes down if EC2 goes down
- Defeats the purpose of a portal (unavailable exactly when you need it most)

**Option B: S3 static website + CloudFront**
- Fully independent of EC2
- Highly available (S3 + CloudFront SLA)
- HTTPS via CloudFront + ACM certificate
- Virtually free for low traffic
- Portal stays up even when EC2, WireGuard, or other services are down

## Decision

S3 + CloudFront for `billandjessie.com`. The portal is a static HTML page.

The portal is intentionally kept separate from EC2 so it remains available during infrastructure failures.

## Portal Content

- Links to `grafana.billandjessie.com`
- Links to `status.billandjessie.com` (Uptime Kuma)
- Links to other services as they are added
- Future: embedded Grafana status panel

## Consequences

- Portal defined in Terraform (`terraform/aws/`)
- Static HTML lives in the repo under `portal/`
- CloudFront distribution + S3 bucket created by Terraform
- ACM certificate for `billandjessie.com` managed by Terraform
- Deploying portal changes is a GitHub Actions workflow that syncs `portal/` to S3
