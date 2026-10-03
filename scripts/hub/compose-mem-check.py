#!/usr/bin/env python3
"""Reject an app Compose fragment that has a service without a memory limit.

ADR-0026: every container on the hub gets a memory limit, so one runaway
app is OOM-killed and restarted instead of pushing the whole host into the
kernel OOM killer (which may pick Postgres, Traefik or Authentik).

Reads `docker compose config --format json` on stdin. A service passes with
`mem_limit` or `deploy.resources.limits.memory` set to a positive size.
Exit 0 if every service passes, 1 (listing the offenders) otherwise.

Runs twice, like preview-compose.py: in app-deploy.yml on the runner, for
early feedback in the app's own CI run, and ON THE HUB in app-deploy.sh,
which is the enforcement (the staged file in S3 is what actually runs).
"""
import json
import re
import sys

UNITS = {"": 1, "b": 1, "k": 1024, "kb": 1024, "m": 1024**2, "mb": 1024**2,
         "g": 1024**3, "gb": 1024**3}


def size_bytes(value):
    """Compose size (int bytes, '512m', '1g', '268435456') -> int, or None."""
    if value is None or isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return int(value)
    m = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*([a-zA-Z]*)\s*", str(value))
    if not m or m.group(2).lower() not in UNITS:
        return None
    return int(float(m.group(1)) * UNITS[m.group(2).lower()])


def limit_of(svc):
    deploy_mem = (((svc.get("deploy") or {}).get("resources") or {})
                  .get("limits") or {}).get("memory")
    return size_bytes(svc.get("mem_limit")) or size_bytes(deploy_mem)


def main():
    try:
        services = json.load(sys.stdin).get("services") or {}
    except (json.JSONDecodeError, AttributeError) as e:
        print(f"could not read compose config: {e}")
        return 1
    missing = sorted(n for n, s in services.items() if not limit_of(s or {}))
    if missing:
        print("no memory limit on: " + ", ".join(missing)
              + " -- every hub container needs mem_limit (ADR-0026; "
              "docs/app-platform.md, onboarding checklist).")
        return 1
    print("memory limits: " + ", ".join(
        f"{n}={limit_of(s) // 1024**2}MiB" for n, s in sorted(services.items())))
    return 0


if __name__ == "__main__":
    sys.exit(main())
