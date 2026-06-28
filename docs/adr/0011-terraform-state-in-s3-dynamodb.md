# ADR-0011: Terraform State in S3 + DynamoDB

Date: 2026-06-28
Status: Accepted

## Context

Terraform requires a backend for storing state. The default local backend stores state on disk, which is not suitable for a GitOps workflow where GitHub Actions runs Terraform.

## Options Considered

**Option A: Local state**
- Simple to start
- State file cannot be shared between local machine and GitHub Actions
- State not backed up
- Not suitable for CI/CD

**Option B: Terraform Cloud**
- Managed state backend
- Free tier available
- Adds an external dependency outside the AWS account

**Option C: S3 + DynamoDB**
- S3 stores the state file
- DynamoDB provides state locking (prevents concurrent applies)
- Native AWS — no external dependencies
- Standard best practice for AWS-hosted projects
- Integrates naturally with the OIDC GitHub Actions role

## Decision

S3 + DynamoDB backend for all Terraform state.

## Bootstrap

The S3 bucket and DynamoDB table are created manually (or via a small bootstrap script) before any other Terraform is run. This is a one-time step. Everything else is managed by Terraform.

Bootstrap resources:

- S3 bucket: `home-platform-terraform-state` (versioning enabled, private)
- DynamoDB table: `home-platform-terraform-locks` (partition key: `LockID`)

## Consequences

- GitHub Actions authenticates to AWS via OIDC and has read/write access to the state bucket and lock table
- State is versioned in S3 — rollback is possible
- Concurrent applies are prevented by DynamoDB lock
- Bootstrap procedure documented in `docs/runbooks/terraform-bootstrap.md`
