# ADR-0013: Claude as Primary Implementer

Date: 2026-06-28
Status: Accepted

## Context

Bill is a busy person. The platform is complex. The original plan implied Bill would run Terraform, Ansible, and RouterOS config with Claude assisting. This is too much friction for sustained progress.

## Decision

Claude is the primary implementer. Bill handles physical tasks and approvals only.

## Division of Labor

### Bill does:
- Physical: rack hardware, connect cables, power on devices
- First boot: set root password, connect to network
- Bootstrap: run a single curl-to-shell script Claude provides
- RB5009 first-time: minimal Winbox web UI config (set IP, enable SSH) using values Claude provides
- PR approvals: click approve in GitHub for changes Claude opens
- Explicit approval always required for: firewall rule changes, DNS changes, anything that incurs AWS cost

### Claude does:
- Write all Terraform, Ansible, RouterOS config, Docker Compose definitions
- Open PRs for every change
- Apply changes after Bill approves
- Monitor health after each change
- Stop and notify Bill (email + Grafana annotation) if something fails — never attempt blind recovery
- Send email + Grafana annotation notification after autonomous changes complete

## AWS Access

Claude uses AWS credentials (access keys) directly in sessions for interactive and bootstrapping work.

GitHub Actions uses OIDC for CI/CD pipeline — no long-lived keys in Actions.

## Consequences

- Roadmap tasks tagged 🧑 (Bill) or 🤖 (Claude)
- Bill's time investment is physical setup + PR approvals
- Claude drives all implementation sessions
- All changes are traceable in Git history and GitHub Actions logs
