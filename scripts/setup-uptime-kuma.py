"""One-time (idempotent) setup for Uptime Kuma: creates the admin account if
needed and adds monitors for the services already running on the AWS hub.

Usage:
    python scripts/setup-uptime-kuma.py

Requires: pip install uptime-kuma-api boto3
Requires: AWS credentials configured, WireGuard tunnel active.
"""
import subprocess
import json

from uptime_kuma_api import UptimeKumaApi, MonitorType

KUMA_URL = "http://10.0.3.1:3001"
AWS_CLI = r"C:\Program Files\Amazon\AWSCLIV2\aws.exe"

MONITORS = [
    dict(type=MonitorType.HTTP, name="Grafana", url="http://grafana:3000/api/health", interval=60),
    dict(type=MonitorType.HTTP, name="Prometheus", url="http://prometheus:9090/-/healthy", interval=60),
    dict(type=MonitorType.HTTP, name="Loki", url="http://loki:3100/ready", interval=60),
    dict(type=MonitorType.HTTP, name="cost-exporter", url="http://cost-exporter:9199/metrics", interval=60),
    dict(type=MonitorType.PING, name="NYC WireGuard tunnel", hostname="10.0.3.2", interval=60),
    dict(type=MonitorType.PING, name="Rambles WireGuard tunnel", hostname="10.0.3.3", interval=60),

    # Public-facing endpoints -- exercise the real path (DNS, TLS, nginx, backend).
    dict(type=MonitorType.HTTP, name="Grafana (public)", url="https://grafana.billandjessie.com/api/health", interval=60),
    dict(type=MonitorType.HTTP, name="Status page (public)", url="https://status.billandjessie.com", interval=60),
    dict(type=MonitorType.HTTP, name="Portal (public)", url="https://billandjessie.com", interval=60),

    # Network devices, pinged from the hub over the WireGuard tunnel.
    dict(type=MonitorType.PING, name="rt-nyc", hostname="10.0.1.1", interval=60),
    dict(type=MonitorType.PING, name="rt-rambles", hostname="10.0.2.1", interval=60),
    dict(type=MonitorType.PING, name="sw-main", hostname="10.0.1.10", interval=60),
    dict(type=MonitorType.PING, name="sw-desk", hostname="10.0.1.11", interval=60),
    dict(type=MonitorType.PING, name="sw-10g", hostname="10.0.1.12", interval=60),
    dict(type=MonitorType.PING, name="nas2", hostname="10.0.1.7", interval=60),

    # WiFi APs -- added 2026-09-28 after a Rambles WiFi outage that the
    # router/WAN-level monitoring above never caught (router and WAN uplink
    # both stayed healthy throughout; the mesh AP itself was never watched).
    #
    # NYC: the Nighthawk RS700's own management IP (10.0.1.2) doesn't answer
    # ICMP *or* TCP when the request arrives via the hub's WireGuard-routed
    # path -- confirmed 2026-09-28 from the hub itself (both curl and ping
    # timed out completely), while every other NYC device monitored the same
    # way (router, switches, nas2) responds fine over that same path. It
    # only answers a device on its own local LAN segment. So a monitor on
    # 10.0.1.2 directly would show "down" permanently regardless of real
    # health. Proxied instead via hue-nyc (10.0.1.71), which is wired
    # directly to the Nighthawk -- if that responds, the AP's basic
    # LAN-side forwarding is alive, even though its own management IP won't
    # answer remotely.
    dict(type=MonitorType.PING, name="hue-nyc (NYC AP proxy)", hostname="10.0.1.71", interval=60),
    dict(type=MonitorType.PING, name="ZenWiFi AP (Rambles, main node)", hostname="10.0.2.251", interval=60),
    # Known 3rd mesh satellite (docs/network-inventory.md) -- dynamic lease,
    # not a static reservation, so this IP could drift.
    dict(type=MonitorType.PING, name="ZenWiFi satellite (Rambles, .246)", hostname="10.0.2.246", interval=60),
]


def get_ssm_param(name, decrypt=False):
    cmd = [AWS_CLI, "ssm", "get-parameter", "--name", name, "--region", "us-east-1", "--output", "json"]
    if decrypt:
        cmd.append("--with-decryption")
    out = subprocess.check_output(cmd)
    return json.loads(out)["Parameter"]["Value"]


def main():
    password = get_ssm_param("/home-platform/uptime-kuma/admin-password", decrypt=True)

    with UptimeKumaApi(KUMA_URL) as api:
        if api.need_setup():
            print("Running first-time setup...")
            api.setup("admin", password)
        api.login("admin", password)

        existing = {m["name"] for m in api.get_monitors()}
        for m in MONITORS:
            if m["name"] in existing:
                print(f"Skipping (already exists): {m['name']}")
                continue
            print(f"Adding monitor: {m['name']}")
            api.add_monitor(**m)


if __name__ == "__main__":
    main()
