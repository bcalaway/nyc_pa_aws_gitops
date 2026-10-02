#!/usr/bin/env python3
"""Weekly external exposure check (Milestone 19, ADR-0024).

Runs on the EC2 hub as root from a systemd timer (exposure-check.timer,
installed by compose/aws/host/install.sh), and on demand through the
`exposure-check-now` voice job. Scans, from outside each network:

  hub      the hub's own public IP (looked up from IMDS)
  nyc      NYC's current WAN IP     } read from the hub's WireGuard peer
  rambles  Rambles' current WAN IP  } endpoints, since both are dynamic

TCP: the 1,000 most common ports (SYN scan). UDP: a short list of ports
that matter if exposed (DNS, NTP, SNMP, IKE, SSDP, mDNS, WireGuard). UDP
only counts as open on a real reply -- "open|filtered" is what every
silently-dropped port looks like, so it's ignored.

Results stay on the hub: /var/lib/home-platform/exposure/latest.json (read
by home-mcp's exposure_check tool through a read-only bind mount) plus a few
node-exporter textfile metrics. Nothing detailed is printed, because voice
job output ends up in this public repo's Actions logs.

Caveats, said again in the tool's answer:
- The hub scanning its own public IP hairpins through AWS's internet
  gateway; security-group rules apply as for any internet source, but it
  isn't a truly independent vantage point.
- The site routers trust the hub for WireGuard, so a port opened only to
  the hub's IP would look exposed here when it isn't to the internet.
- Rambles is skipped when its tunnel has no recent handshake (closed
  November through April).

Usage: exposure-check.py [--textfile-dir DIR]
"""

import argparse
import datetime
import json
import os
import subprocess
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET

STATE_DIR = "/var/lib/home-platform/exposure"
EXPECTED_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "exposure-expected.json")
UDP_PORTS = "53,123,161,500,1900,4500,5353,51820"
SITE_BY_LAN = {"10.0.1.0/24": "nyc", "10.0.2.0/24": "rambles"}
STALE_HANDSHAKE_SECONDS = 15 * 60


def hub_public_ip():
    req = urllib.request.Request(
        "http://169.254.169.254/latest/api/token",
        method="PUT",
        headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
    )
    token = urllib.request.urlopen(req, timeout=3).read().decode()
    req = urllib.request.Request(
        "http://169.254.169.254/latest/meta-data/public-ipv4",
        headers={"X-aws-ec2-metadata-token": token},
    )
    return urllib.request.urlopen(req, timeout=3).read().decode().strip()


def site_endpoints():
    """{site: (ip, handshake_age_seconds)} from `wg show all dump`."""
    out = subprocess.run(["wg", "show", "all", "dump"], capture_output=True, text=True, check=True).stdout
    now = time.time()
    sites = {}
    for line in out.splitlines():
        f = line.split("\t")
        # Peer lines have 9 fields: iface, pubkey, psk, endpoint, allowed-ips,
        # latest-handshake, rx, tx, keepalive. Interface lines have 5.
        if len(f) != 9 or f[3] in ("(none)", ""):
            continue
        allowed = f[4].split(",")
        for lan, site in SITE_BY_LAN.items():
            if lan in allowed:
                ip = f[3].rsplit(":", 1)[0].strip("[]")
                handshake = int(f[5] or 0)
                sites[site] = (ip, now - handshake if handshake else None)
    return sites


def nmap(args):
    r = subprocess.run(["nmap", "-Pn", "-n", "-oX", "-"] + args, capture_output=True, text=True, timeout=1800, check=False)
    if r.returncode != 0:
        raise RuntimeError(f"nmap exited {r.returncode}")
    ports = []
    for port in ET.fromstring(r.stdout).iter("port"):
        state = port.find("state").get("state")
        if state != "open":
            continue
        svc = port.find("service")
        ports.append({"port": int(port.get("portid")), "service": svc.get("name") if svc is not None else ""})
    return ports


def scan(ip):
    tcp = nmap(["-sS", "-T3", "--top-ports", "1000", "--open", ip])
    udp = nmap(["-sU", "-T3", "-p", UDP_PORTS, ip])
    return tcp, udp


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--textfile-dir", default="")
    a = ap.parse_args()

    os.makedirs(STATE_DIR, exist_ok=True)
    with open(EXPECTED_FILE) as fh:
        expected = json.load(fh)

    result = {"scanned_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"), "targets": [], "errors": []}
    targets = []
    try:
        targets.append(("hub", hub_public_ip()))
    except Exception as exc:  # noqa: BLE001 -- report, don't crash the run
        result["errors"].append(f"hub public IP lookup failed: {type(exc).__name__}")
    try:
        for site, (ip, age) in sorted(site_endpoints().items()):
            if age is None or age > STALE_HANDSHAKE_SECONDS:
                result["errors"].append(f"{site} skipped: no recent WireGuard handshake")
                continue
            targets.append((site, ip))
    except Exception as exc:  # noqa: BLE001
        result["errors"].append(f"WireGuard endpoint lookup failed: {type(exc).__name__}")

    for name, ip in targets:
        entry = {"name": name, "ip": ip}
        try:
            tcp, udp = scan(ip)
        except Exception as exc:  # noqa: BLE001
            entry["error"] = f"scan failed: {exc}"
            result["targets"].append(entry)
            continue
        want = expected.get(name, {})
        entry["open_tcp"] = tcp
        entry["open_udp"] = udp
        entry["unexpected"] = (
            [f"tcp/{p['port']}" for p in tcp if p["port"] not in want.get("tcp", [])]
            + [f"udp/{p['port']}" for p in udp if p["port"] not in want.get("udp", [])]
        )
        result["targets"].append(entry)

    tmp = os.path.join(STATE_DIR, ".latest.json.tmp")
    with open(tmp, "w") as fh:
        json.dump(result, fh, indent=1)
    os.chmod(tmp, 0o644)
    os.replace(tmp, os.path.join(STATE_DIR, "latest.json"))

    if a.textfile_dir:
        lines = [
            "# HELP exposure_unexpected_open_ports Ports open to the internet that aren't on the expected list.",
            "# TYPE exposure_unexpected_open_ports gauge",
        ]
        for t in result["targets"]:
            if "unexpected" in t:
                lines.append(f'exposure_unexpected_open_ports{{target="{t["name"]}"}} {len(t["unexpected"])}')
        lines += [
            "# HELP exposure_last_scan_timestamp_seconds When the exposure check last finished.",
            "# TYPE exposure_last_scan_timestamp_seconds gauge",
            f"exposure_last_scan_timestamp_seconds {int(time.time())}",
        ]
        tmp = os.path.join(a.textfile_dir, ".exposure.prom.tmp")
        with open(tmp, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(a.textfile_dir, "exposure.prom"))

    # Deliberately says nothing about the findings: this line ends up in the
    # public repo's Actions logs when run as a voice job.
    print("RESULT: Exposure check finished; ask for the exposure check to hear the results.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
