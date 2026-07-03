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
    dict(type=MonitorType.PING, name="NYC WireGuard tunnel", hostname="10.0.3.2", interval=60),
    dict(type=MonitorType.PING, name="Rambles WireGuard tunnel", hostname="10.0.3.3", interval=60),
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
