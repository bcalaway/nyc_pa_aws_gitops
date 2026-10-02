"""exposure_check: what the internet can reach, and when certificates expire (Milestone 19, ADR-0024).

Read-only. Two parts:

1. The latest weekly port scan, written by the hub's exposure-check.timer
   (compose/aws/host/exposure-check.py) to /var/lib/home-platform/exposure,
   mounted read-only here at EXPOSURE_FILE. It scans the hub's public IP and
   both sites' WAN IPs from outside, and compares what's open with
   compose/aws/host/exposure-expected.json. A fresh scan can be started with
   the `exposure-check-now` voice job.
2. TLS certificate expiry for every public hostname, checked live on each
   call (Traefik renews Let's Encrypt certificates about 30 days out, so
   anything under 14 days means renewal is failing).
"""

import asyncio
import datetime
import json
import os
import socket
import ssl

EXPOSURE_FILE = os.environ.get("EXPOSURE_FILE", "/exposure/latest.json")
STALE_DAYS = 8
CERT_WARN_DAYS = 14
HOSTS = [
    h.strip()
    for h in os.environ.get(
        "TLS_HOSTS",
        "billandjessie.com,auth.billandjessie.com,grafana.billandjessie.com,status.billandjessie.com,"
        "analytics.billandjessie.com,mcp.billandjessie.com,todo-app.billandjessie.com,hue.billandjessie.com,"
        "auth.preview.billandjessie.com",
    ).split(",")
    if h.strip()
]


def _cert_days(host: str) -> float:
    ctx = ssl.create_default_context()
    with socket.create_connection((host, 443), timeout=8) as sock, ctx.wrap_socket(sock, server_hostname=host) as tls:
        cert = tls.getpeercert()
    expires = datetime.datetime.fromtimestamp(ssl.cert_time_to_seconds(cert["notAfter"]), datetime.timezone.utc)
    return (expires - datetime.datetime.now(datetime.timezone.utc)).total_seconds() / 86400


async def _certs() -> tuple[list[str], list[str], int]:
    results = await asyncio.gather(*(asyncio.to_thread(_cert_days, h) for h in HOSTS), return_exceptions=True)
    problems, couldnt = [], []
    soonest = None
    for host, res in zip(HOSTS, results):
        if isinstance(res, ssl.SSLCertVerificationError):
            problems.append(f"{host} has an invalid certificate ({res.verify_message})")
        elif isinstance(res, Exception):
            couldnt.append(f"{host} ({type(res).__name__})")
        else:
            soonest = res if soonest is None else min(soonest, res)
            if res < CERT_WARN_DAYS:
                problems.append(f"{host} certificate expires in {res:.0f} days (renewal may be failing)")
    return problems, couldnt, int(soonest) if soonest is not None else -1


def _scan() -> tuple[list[str], list[str], list[str]]:
    """(problems, info, couldnt) from the latest scan file. Targets the scan
    skipped (Rambles in its closed season) are reported as info, not errors."""
    try:
        with open(EXPOSURE_FILE) as fh:
            data = json.load(fh)
    except FileNotFoundError:
        return [], [], ["port scan (no results yet; it runs Friday late afternoon, or ask to run the exposure check now)"]
    except (OSError, ValueError) as exc:
        return [], [], [f"port scan results ({type(exc).__name__})"]
    problems, info, couldnt = [], [], []
    when = datetime.datetime.fromisoformat(data["scanned_at"])
    age = (datetime.datetime.now(datetime.timezone.utc) - when).days
    info.append(f"port scan from {when:%a %b %-d} ({age} day{'s' if age != 1 else ''} ago)")
    if age > STALE_DAYS:
        problems.append(f"the weekly port scan hasn't run for {age} days")
    for t in data.get("targets", []):
        name = t["name"]
        if "error" in t:
            couldnt.append(f"{name} scan ({t['error']})")
            continue
        if t.get("unexpected"):
            problems.append(f"{name} has unexpected open ports: {', '.join(t['unexpected'])}")
        else:
            opened = [f"tcp/{p['port']}" for p in t.get("open_tcp", [])] + [f"udp/{p['port']}" for p in t.get("open_udp", [])]
            info.append(f"{name}: only expected ports open ({', '.join(opened) or 'none'})")
    skipped = [e for e in data.get("errors", []) if " skipped:" in e]
    if skipped:
        info.append("not scanned: " + ", ".join(skipped))
    couldnt.extend(e for e in data.get("errors", []) if " skipped:" not in e)
    return problems, info, couldnt


async def exposure_check() -> str:
    (cert_problems, cert_couldnt, soonest), (scan_problems, scan_info, scan_couldnt) = await asyncio.gather(
        _certs(), asyncio.to_thread(_scan)
    )
    problems = scan_problems + cert_problems
    if problems:
        head = f"{len(problems)} exposure issue{'s' if len(problems) != 1 else ''}: " + "; ".join(problems) + "."
    else:
        head = "Nothing unexpected is reachable from the internet, and all certificates are current."
    lines = [head]
    if scan_info:
        lines.append("Scan: " + "; ".join(scan_info) + ".")
    if soonest >= 0:
        lines.append(f"Certificates: {len(HOSTS)} public hostnames checked; the soonest expires in {soonest} days.")
    lines.append(
        "Caveats: the hub scans its own public IP through AWS's gateway, and the site routers trust the hub, "
        "so a port opened only to the hub would show up here too."
    )
    couldnt = scan_couldnt + cert_couldnt
    if couldnt:
        lines.append("Couldn't check: " + "; ".join(couldnt) + ".")
    return "\n".join(lines)
