# ADR-0005: AWS SSM Parameter Store for Secrets

Date: 2026-06-28
Status: Accepted

## Context

The platform requires secrets management for WireGuard keys, TLS certificates, Grafana credentials, Gmail SMTP credentials, and other sensitive values. Secrets must never be committed to Git.

## Options Considered

**Option A: HashiCorp Vault**
- Powerful, feature-rich secrets management
- Requires its own infrastructure to run and maintain
- Overkill for a home platform

**Option B: SOPS with age-encrypted files in Git**
- Encrypted secrets committed to Git
- Decrypted at deploy time
- Requires key management for the age private key
- More complex toolchain

**Option C: AWS SSM Parameter Store**
- Native AWS service, no extra infrastructure
- SecureString parameters encrypted with KMS
- Natively supported by Terraform (`aws_ssm_parameter`) and Ansible (`amazon.aws.aws_ssm`)
- IAM controls access — integrates with GitHub Actions OIDC
- Simple, already in the AWS account

## Decision

AWS SSM Parameter Store for all secrets. SecureString type for sensitive values.

No secrets in Git. Ever.

## Conventions

Parameters namespaced by environment and service:

```
/home-platform/wireguard/hub-private-key
/home-platform/wireguard/nyc-private-key
/home-platform/wireguard/rambles-private-key
/home-platform/grafana/admin-password
/home-platform/gmail/smtp-password
/home-platform/letsencrypt/email
```

## Consequences

- Terraform references SSM parameters via `data "aws_ssm_parameter"`
- Ansible retrieves secrets at runtime via `amazon.aws.aws_ssm` lookup
- GitHub Actions accesses SSM via OIDC role — no long-lived credentials
- Parameter bootstrap (initial secret creation) is a one-time manual step documented in runbooks
