# ADR-0003: Docker Compose Over Kubernetes

Date: 2026-06-28
Status: Accepted

## Context

The platform runs containerized workloads on Linux NUCs and on AWS EC2. An orchestration approach is needed. Kubernetes and Docker Compose were considered.

## Options Considered

**Option A: Kubernetes**
- Full container orchestration, auto-scheduling, self-healing
- Significant operational overhead for a home setup
- Requires etcd, control plane, kubelets, CNI plugins
- Overkill for a small number of well-defined services
- Adds complexity to provisioning and recovery

**Option B: Docker Compose**
- Simple, declarative, file-based service definitions
- Trivial to provision: `docker compose up -d`
- Compose files live in Git — fully reproducible
- Ansible deploys and manages Compose stacks
- Well-understood, minimal dependencies
- Easy to recover: fresh OS install + Ansible playbook = fully operational

## Decision

Docker Compose on all nodes (NUCs and EC2). Kubernetes is explicitly deferred — it can be revisited if workloads grow to justify the complexity.

The goal is that standing up a NUC from scratch requires only a Rocky Linux install followed by running an Ansible playbook.

## Consequences

- No container scheduling or auto-healing across nodes — services are pinned per host
- Compose files live in Git under `compose/aws/`, `compose/nyc/`, `compose/rambles/`
- Ansible manages deployment, updates, and restarts
- Recovery procedure is: install OS → run playbook → done
