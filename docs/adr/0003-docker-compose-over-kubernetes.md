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

## Revisited 2026-07-17

Reconsidered as part of planning the app platform (ADR-0014 through ADR-0019) — same conclusion, reaffirmed rather than reversed. A single hub node doesn't need a scheduler; k8s's actual value (multi-node scheduling) doesn't apply until there's more than one node running app workloads. Revisit again specifically if the NUCs ever join as app compute nodes alongside the hub (see ADR-0015) — a k3s cluster spanning hub + NUCs is where this decision would actually flip, not before. Traefik (ADR-0018) was chosen partly because it ships built into k3s by default, so that choice pays forward into this future migration rather than being thrown away if it happens.
