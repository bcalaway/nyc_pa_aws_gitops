# Home Platform Architecture

Version 0.1 (Draft)

Author: Bill Calaway + ChatGPT

---

# Vision

Create a highly reliable, reproducible, GitOps-managed home infrastructure spanning two physical locations:

* NYC Apartment
* Poconos Cottage

using AWS as a cloud control plane.

The entire platform should be:

* Infrastructure as Code
* Reproducible
* Observable
* Well documented
* Easy to recover from hardware failures
* Expandable over many years

The GitHub repository is the source of truth.

---

# High Level Goals

## Reliability

The network should continue operating when:

* an ISP fails
* a VPN tunnel fails
* AWS becomes unavailable
* a router fails (future)
* a Linux NUC fails
* a switch reboots

The goal is graceful degradation rather than catastrophic failure.

---

## GitOps

Everything practical should be defined in Git.

Examples:

* AWS infrastructure
* DNS
* DHCP
* Router configuration
* Linux configuration
* Monitoring
* Alerting
* Dashboards
* Documentation
* Recovery procedures

Configuration changes should occur through Pull Requests.

---

## Observability

The entire platform should be observable.

Metrics:

* Prometheus

Dashboards:

* Grafana

Logs:

* Loki

Long-term storage:

* S3

Alerts:

* Grafana Alerting
* Alertmanager (future)

---

# Sites

## NYC

Internet

* Verizon FiOS

Backup Internet

* Building WiFi

Current Router

* Netgear Nighthawk RS700

Switch

* MikroTik CRS309-1G-8S+IN

Storage

* Synology NAS
* Plex

Server

* Linux NUC (planned)

---

## Poconos

Internet

* 2Gb Cable

Backup Internet

* Starlink

WiFi

* ASUS ZenWiFi AX6600 (3-node mesh)

Switch

* MikroTik CRS310-8G+2S+IN

Server

* Linux NUC (planned)

---

## AWS

Purpose

Cloud control plane

Responsibilities

* WireGuard hub
* Grafana
* Prometheus
* Loki
* S3
* Future automation

AWS is NOT intended to become the default Internet gateway.

Only infrastructure traffic should traverse AWS.

---

# Networking Philosophy

Internet traffic should remain local.

Example

NYC → Internet

uses

FiOS

NOT

NYC → AWS → Internet

Likewise

Poconos → Internet

uses

Cable or Starlink.

AWS carries:

* site-to-site traffic
* monitoring
* logging
* administration

---

# Planned Topology

NYC

FiOS
↓

Router
↓

CRS309

↓

10Gb devices

↓

Linux NUC

↓

Synology

Poconos

Cable
Starlink
↓

Router

↓

CRS310

↓

ASUS WiFi

↓

Clients

↓

Linux NUC

AWS

WireGuard Hub

↓

Grafana

↓

Prometheus

↓

Loki

↓

S3

---

# Router Philosophy

Current consumer routers are acceptable initially.

Long term:

Dedicated routers should become the network edge.

Switches should remain switches.

Linux NUCs should run applications.

Routing should not depend upon a Linux server.

---

# Proposed Router Hardware

Recommended

MikroTik RB5009

Initial purchase

2 routers

One per site

Future

Cold spare

Eventually

Two routers per site with VRRP

---

# Availability Philosophy

Tier 1

Must survive

* Internet
* WiFi
* DHCP
* DNS
* Routing

Tier 2

Temporary outage acceptable

* VPN
* Monitoring
* SSH

Tier 3

Developer services

* CI/CD
* Experiments
* Containers

---

# DNS

Replace hosts files.

Current hosts

router
printer
nas1
nas2
sw-main
sw-desk
sw-10g
p7670
furry

Current addresses should remain unchanged.

Preferred naming

router.nyc.home.arpa

nas1.nyc.home.arpa

etc.

DNS records should be generated from Git.

---

# Monitoring

Prometheus

Collect

* Router metrics
* Switch metrics
* NAS metrics
* Linux metrics
* VPN metrics
* Internet health
* Disk health
* Temperature
* UPS
* Plex

Grafana

Single pane of glass.

Loki

Collect

* Router logs
* Linux logs
* Docker logs
* VPN logs

Archive

S3

---

# Git Repository

home-platform/

README.md

docs/

terraform/

ansible/

routeros/

compose/

monitoring/

dns/

scripts/

.github/

---

# Deployment Workflow

Developer

↓

Commit

↓

Pull Request

↓

Terraform Plan

↓

Validation

↓

Manual Approval

↓

Terraform Apply

↓

Ansible

↓

Router Configuration

↓

Docker Deployment

↓

Health Checks

↓

Grafana Annotation

---

# Documentation

The repository should contain

Architecture

Roadmap

Recovery

Hardware Inventory

IP Plan

Runbooks

Architecture Decision Records

---

# Desired Dashboard

NYC

* FiOS
* Building WiFi
* Router
* Switch
* NUC
* Synology
* Plex

Poconos

* Cable
* Starlink
* Router
* Switch
* ASUS
* NUC

AWS

* EC2
* WireGuard
* Grafana
* Prometheus
* Loki
* S3

Deployments

GitHub Actions

Recent Deployments

Recent Alerts

---

# Long-Term Vision

The repository should eventually be capable of rebuilding the entire platform from scratch.

Replacing a failed router should involve:

Install replacement hardware

↓

Bootstrap

↓

Pull configuration from Git

↓

Restore certificates

↓

Join monitoring

↓

Operational

The same philosophy should apply to Linux servers and AWS.

---

# Open Questions

* Final IP addressing plan
* VLAN design
* Router hardware selection
* DNS implementation
* DHCP implementation
* WireGuard topology
* Dynamic routing
* UPS selection
* Remote power management
* Backup strategy
* Secret management
* Certificate management
* Home Assistant integration (future)
* Kubernetes (future)

---

# Success Criteria

The platform is considered complete when:

* Entire infrastructure is defined in Git.
* Changes occur via Pull Requests.
* Every device is monitored.
* Recovery from hardware failure is documented.
* AWS provides observability but is not an Internet bottleneck.
* DNS replaces hosts files.
* WAN failover is automatic.
* Rebuilding a router or NUC requires minimal manual work.
