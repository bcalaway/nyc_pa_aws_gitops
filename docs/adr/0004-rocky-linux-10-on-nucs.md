# ADR-0004: Rocky Linux 10 on NUCs

Date: 2026-06-28
Status: Accepted
Revised: 2026-07-10 — originally decided as Rocky Linux 9; revised to 10 before either NUC was installed

## Context

The Linux NUCs need an OS. The user is comfortable with Red Hat-style Linux. Several free RHEL-compatible distributions are available.

## Options Considered

**Option A: Ubuntu / Debian**
- Widely used, large community
- Not Red Hat-style — different package manager, init conventions, file layout
- User less comfortable with this family

**Option B: AlmaLinux**
- Free 1:1 RHEL clone
- Strong community, good long-term support
- Comparable to Rocky Linux

**Option C: Rocky Linux**
- Free 1:1 RHEL clone
- Strong community momentum
- Familiar Red Hat conventions (dnf, systemd, SELinux, firewalld)
- 10-year support lifecycle matching RHEL
- User's preferred Linux family

## Decision

Rocky Linux 10 on both NUCs (NYC and Rambles).

## Revision (2026-07-10)

Originally decided as Rocky Linux 9. Revised to Rocky Linux 10 before either NUC had actually been installed — neither NYC's nor Rambles' NUC had Rocky deployed yet, so this is a course-correction rather than a migration.

Reasoning: Rocky 10's longer remaining support runway (released 2025, vs. Rocky 9's 2022) pushes the next forced OS migration further out. For infrastructure that just needs to run Docker Compose and a handful of exporters reliably for years, that outweighs Rocky 9's greater real-world maturity. Neither NUC's hardware (i7-1165G7, i9-13900H) is new enough that either OS would have meaningfully different driver/hardware support.

## NUC Hardware

| Site    | Hardware | CPU | RAM | Storage |
|---------|----------|-----|-----|---------|
| NYC | Intel NUC 11 Enthusiast (NUC11PHKi7C) | i7-1165G7 + RTX 2060 | 64GB | 2TB SSD |
| Rambles | MINISFORUM MS-01 | i9-13900H | 32GB | 1TB SSD |

Both NUCs are starting from a fresh install as part of this project.

## Consequences

- Ansible playbooks use dnf, systemctl, firewalld conventions
- SELinux enabled (default Rocky Linux posture)
- neovim installed as standard editor on all NUCs
- NUC provisioning fully automated via Ansible — goal is fresh OS to operational in one playbook run
