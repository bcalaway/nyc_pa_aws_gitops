# ADR-0002: Centralized Prometheus on AWS, Not Per-Site

Date: 2026-06-28
Status: Accepted

## Context

Metrics need to be collected from both sites (NYC and Rambles) and from AWS itself. Two architectures were considered: a single Prometheus on AWS scraping all exporters through the WireGuard tunnel, or a local Prometheus per site federating up to AWS.

## Options Considered

**Option A: Local Prometheus per site, federated to AWS**
- Each site runs its own Prometheus
- AWS Prometheus scrapes or receives remote_write from site instances
- No metrics gap during WireGuard tunnel failover
- Significantly more infrastructure to maintain (3 Prometheus instances, federation config)

**Option B: Single Prometheus on AWS EC2**
- AWS Prometheus scrapes all exporters at both sites through the WireGuard tunnel
- Simpler — one instance, one config, one retention policy
- Small metrics gap possible during WireGuard failover (typically seconds)
- Acceptable for a home setup

## Decision

Single centralized Prometheus on AWS EC2. All exporters at NYC and Rambles are scraped through the WireGuard tunnel.

The small metrics gap during tunnel failover is acceptable. The added complexity of federation is not justified for a home platform.

## Exporters Deployed Per Site

- `node_exporter` — NUCs and NAS
- `snmp_exporter` — MikroTik routers and switches
- `blackbox_exporter` — WAN health probes (latency, packet loss) per interface
- `speedtest_exporter` — periodic throughput tests per WAN interface

All exporters run as Docker containers on the NUCs, managed via Docker Compose in Git.

## WAN Monitoring

All 4 WAN connections are monitored independently regardless of failover state:

| Site    | Connection    |
|---------|---------------|
| NYC     | Verizon FiOS  |
| NYC     | Building WiFi |
| Rambles | Blue Ridge Cable |
| Rambles | Starlink      |

`blackbox_exporter` uses policy routing to force probes out each interface independently.

## Consequences

- All metrics visible in a single Grafana instance on AWS
- Metrics gap of seconds possible during WireGuard tunnel failover — documented and accepted
- Prometheus config lives in Git under `monitoring/prometheus/`
