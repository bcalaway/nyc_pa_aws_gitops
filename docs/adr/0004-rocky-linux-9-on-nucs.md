# ADR-0004: Rocky Linux 9 on NUCs

Date: 2026-06-28
Status: Accepted

## Context

The Linux NUCs need an OS. The user is comfortable with Red Hat-style Linux. Several free RHEL-compatible distributions are available.

## Options Considered

**Option A: Ubuntu / Debian**
- Widely used, large community
- Not Red Hat-style — different package manager, init conventions, file layout
- User less comfortable with this family

**Option B: AlmaLinux 9**
- Free 1:1 RHEL clone
- Strong community, good long-term support
- Comparable to Rocky Linux

**Option C: Rocky Linux 9**
- Free 1:1 RHEL clone
- Strong community momentum
- Familiar Red Hat conventions (dnf, systemd, SELinux, firewalld)
- 10-year support lifecycle matching RHEL 9
- User's preferred Linux family

## Decision

Rocky Linux 9 on both NUCs (NYC and Rambles).

## NUC Hardware

| Site    | Hardware | CPU | RAM | Storage |
|---------|----------|-----|-----|---------|
| NYC | Intel NUC 11 Enthusiast (NUC11PHKi7C) | i7-1165G7 + RTX 2060 | 64GB | 2TB SSD |
| Rambles | MINISFORUM MS-01 | i9-13900H | 32GB | 1TB SSD |

Both NUCs are starting from a fresh install as part of this project.

## Consequences

- Ansible playbooks use dnf, systemctl, firewalld conventions
- SELinux enabled (default Rocky Linux 9 posture)
- neovim installed as standard editor on all NUCs
- NUC provisioning fully automated via Ansible — goal is fresh OS to operational in one playbook run
