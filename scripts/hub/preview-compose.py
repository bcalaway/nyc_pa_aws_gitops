#!/usr/bin/env python3
"""Rewrite an app's production Compose fragment into a per-PR preview
(ADR-0023). Runs on the GitHub runner; input is the fragment as JSON
(`yq -o=json`), output is JSON (valid YAML, so Compose reads it as-is).

For every service:
  - no container_name (Compose names it <app>-pr<n>-<service>-1)
  - only the `preview` network (internal: no internet; Traefik + Postgres)
  - APP_NAME=<app>-pr<n> (the platform convention: Postgres role and
    database name), env_file: .env (written on the hub with only the
    preview DB password and a session secret -- no production secrets)
  - mem_limit 384m, cpus 0.5, pids_limit 256
  - all labels replaced
The one Traefik-routed service (the one with traefik.enable=true) gets
preview router labels: Host <app>-pr<n>.preview.billandjessie.com, the
shared wildcard certificate, HSTS and Authentik forward-auth.
The service whose image is the app's own ECR image gets the PR's image.
"""

import argparse
import json
import re
import sys

ap = argparse.ArgumentParser()
ap.add_argument("fragment")
ap.add_argument("--app", required=True)
ap.add_argument("--pr", required=True)
ap.add_argument("--image", required=True)
ap.add_argument("--out", required=True)
ap.add_argument("--outputs", help="GITHUB_OUTPUT file for service/port/host")
a = ap.parse_args()

if not re.fullmatch(r"[a-z0-9-]+", a.app) or not re.fullmatch(r"[0-9]+", a.pr):
    sys.exit("bad --app or --pr")

proj = f"{a.app}-pr{a.pr}"
host = f"{proj}.preview.billandjessie.com"
src = json.load(open(a.fragment))
services = src.get("services") or {}
if not services:
    sys.exit("fragment has no services")

repo_prefix = a.image.rsplit(":", 1)[0]
routed = None
out_services = {}
for name, svc in services.items():
    svc = dict(svc)
    labels = svc.get("labels") or []
    if isinstance(labels, dict):
        labels = [f"{k}={v}" for k, v in labels.items()]
    port = None
    enabled = False
    for lab in labels:
        if lab == "traefik.enable=true":
            enabled = True
        m = re.fullmatch(r"traefik\.http\.services\.[^.]+\.loadbalancer\.server\.port=(\d+)", lab)
        if m:
            port = m.group(1)
    if enabled:
        if routed:
            sys.exit("more than one Traefik-routed service; previews support one")
        if not port:
            sys.exit(f"service {name} has no loadbalancer.server.port label")
        routed = (name, port)

    svc.pop("container_name", None)
    svc.pop("ports", None)  # never publish host ports from a preview
    if str(svc.get("image", "")).split(":")[0] == repo_prefix:
        svc["image"] = a.image
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(e.split("=", 1) if "=" in e else (e, "") for e in env)
    env["APP_NAME"] = proj
    env["PREVIEW"] = "1"
    svc["environment"] = env
    svc["env_file"] = [".env"]
    svc["networks"] = ["preview"]
    svc["mem_limit"] = "384m"
    svc["cpus"] = 0.5
    svc["pids_limit"] = 256
    svc["security_opt"] = ["no-new-privileges:true"]
    svc["cap_drop"] = ["ALL"]
    svc.pop("privileged", None)
    svc.pop("volumes", None)  # no host paths or shared volumes in previews
    svc.pop("devices", None)
    svc.pop("cap_add", None)
    svc["labels"] = []
    out_services[name] = svc

if not routed:
    sys.exit("no service has traefik.enable=true; nothing to preview")
name, port = routed
r = proj
out_services[name]["labels"] = [
    "traefik.enable=true",
    "traefik.docker.network=preview",
    f"traefik.http.routers.{r}.rule=Host(`{host}`)",
    f"traefik.http.routers.{r}.entrypoints=websecure",
    f"traefik.http.routers.{r}.tls.certresolver=route53",
    f"traefik.http.routers.{r}.tls.domains[0].main=*.preview.billandjessie.com",
    f"traefik.http.routers.{r}.middlewares=hsts@docker,authentik-forward-auth@docker",
    f"traefik.http.services.{r}.loadbalancer.server.port={port}",
]

doc = {"services": out_services, "networks": {"preview": {"external": True}}}
with open(a.out, "w") as f:
    json.dump(doc, f, indent=2)
if a.outputs:
    with open(a.outputs, "a") as f:
        f.write(f"service={name}\nport={port}\nhost={host}\n")
print(f"preview {proj}: service {name} on port {port} at https://{host}")
