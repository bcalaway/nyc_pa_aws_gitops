#!/usr/bin/env bash
# IMDS guard (ADR-0024 finding, 2026-10-02): only the hub stack's own Docker
# network may reach the EC2 instance metadata service (169.254.169.254),
# which hands out the hub role's credentials -- and that role can read every
# platform secret in SSM.
#
# Why it's needed: the instance's IMDS hop limit is 2 (terraform/aws/ec2.tf)
# so containers can use the role at all. That's intended for the platform's
# own services (Traefik's Route53 certificates, postgres-backup's S3 upload,
# cost-exporter, home-mcp's aws_posture), which live on the compose stack's
# default network. But app containers (todo-app, hue, future apps) run on
# the shared `home-platform` bridge and could reach it too, so one
# compromised app could read every secret.
#
# How: a dedicated chain, jumped to from DOCKER-USER for traffic to the IMDS
# address. It lets the stack's default bridge through and drops every other
# Docker bridge. An allow-list rather than a block-list, so a new app
# network is covered without anyone remembering to add it. Only forwarded
# container traffic passes DOCKER-USER; the host's own IMDS use (SSM agent,
# deploy scripts, aws CLI) is untouched.
#
# Safety: with --verify it checks, from inside each container's network
# namespace, that the platform services that need IMDS still get a token
# and that app containers don't. If a platform service has lost access it
# removes the block again (fail open, not broken certificates) and says so.
# The result is exported as hub_imds_guard_active for node-exporter, which
# aws_posture reports on.
#
# Runs as root from imds-guard.service: at boot, after every hub deploy
# (compose/aws/host/install.sh), and hourly (a recreated compose network
# gets a new bridge name, so the allow rule has to follow it).
#
# Usage: imds-guard.sh [--verify] [--textfile-dir DIR]

set -uo pipefail

IMDS=169.254.169.254
CHAIN=IMDS-GUARD
# Platform services that must keep IMDS access (checked with --verify).
NEEDS_IMDS=(traefik postgres-backup cost-exporter home-mcp)
VERIFY=0
TEXTFILE_DIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --verify) VERIFY=1 ;;
    --textfile-dir) TEXTFILE_DIR="$2"; shift ;;
  esac
  shift
done

log() { echo "imds-guard: $*"; }

write_metric() {  # $1 = 1 active, 0 not active
  [ -n "$TEXTFILE_DIR" ] && [ -d "$TEXTFILE_DIR" ] || return 0
  local tmp="$TEXTFILE_DIR/.imds_guard.prom.$$"
  {
    echo "# HELP hub_imds_guard_active 1 if only the hub stack's own network can reach the EC2 metadata service."
    echo "# TYPE hub_imds_guard_active gauge"
    echo "hub_imds_guard_active $1"
    echo "# HELP hub_imds_guard_last_run_timestamp_seconds When the IMDS guard last ran."
    echo "# TYPE hub_imds_guard_last_run_timestamp_seconds gauge"
    echo "hub_imds_guard_last_run_timestamp_seconds $(date +%s)"
  } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$TEXTFILE_DIR/imds_guard.prom"
}

open_guard() {  # remove the block (allow everything), keep the chain
  iptables -F "$CHAIN" 2>/dev/null || true
}

bridge_of() {  # docker network name -> host bridge interface
  local net="$1" id name
  id=$(docker network inspect -f '{{.Id}}' "$net" 2>/dev/null) || return 1
  name=$(docker network inspect -f '{{index .Options "com.docker.network.bridge.name"}}' "$net" 2>/dev/null)
  if [ -n "$name" ] && [ "$name" != "<no value>" ]; then echo "$name"; else echo "br-${id:0:12}"; fi
}

# The stack's default network, found from a container we know belongs to it
# rather than assuming the compose project name.
# At boot Docker may still be starting the stack: wait up to 3 minutes.
project=""
for _ in $(seq 1 18); do
  project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' traefik 2>/dev/null)
  [ -n "$project" ] && break
  sleep 10
done
if [ -z "$project" ]; then
  log "traefik isn't running, so the hub stack's network can't be identified; leaving IMDS unchanged"
  write_metric 0
  exit 0
fi
allowed_br=$(bridge_of "${project}_default") || {
  log "network ${project}_default not found; leaving IMDS unchanged"
  write_metric 0
  exit 0
}
ip link show "$allowed_br" >/dev/null 2>&1 || {
  log "bridge $allowed_br for ${project}_default doesn't exist on the host; leaving IMDS unchanged"
  write_metric 0
  exit 0
}

# Build (or rebuild) the chain atomically enough: flush, then fill.
iptables -N "$CHAIN" 2>/dev/null || true
iptables -F "$CHAIN"
iptables -A "$CHAIN" -i "$allowed_br" -j RETURN
iptables -A "$CHAIN" -i docker0 -j DROP
iptables -A "$CHAIN" -i "br-+" -j DROP
# Bridges given a custom name by a network option: drop those too.
for net in $(docker network ls -q --filter driver=bridge); do
  br=$(bridge_of "$net") || continue
  [ "$br" = "$allowed_br" ] && continue
  case "$br" in docker0|br-*) ;; *) iptables -A "$CHAIN" -i "$br" -j DROP ;; esac
done
iptables -C DOCKER-USER -d "$IMDS/32" -j "$CHAIN" 2>/dev/null \
  || iptables -I DOCKER-USER 1 -d "$IMDS/32" -j "$CHAIN"
log "only $allowed_br (${project}_default) may reach $IMDS"

if [ "$VERIFY" -eq 0 ]; then
  write_metric 1
  exit 0
fi

# Can the container whose name is $1 get an IMDSv2 token? 0 = yes, 1 = no,
# 2 = not running (can't tell).
can_reach() {
  local pid
  pid=$(docker inspect -f '{{if .State.Running}}{{.State.Pid}}{{end}}' "$1" 2>/dev/null)
  [ -n "$pid" ] && [ "$pid" != "0" ] || return 2
  nsenter -t "$pid" -n curl -s -o /dev/null -m 3 -X PUT "http://$IMDS/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 10" && return 0
  return 1
}

# At boot the platform containers may still be starting: wait up to 3
# minutes for each before judging.
broken=()
for c in "${NEEDS_IMDS[@]}"; do
  rc=2
  for _ in $(seq 1 18); do
    can_reach "$c"; rc=$?
    [ "$rc" -ne 2 ] && break
    sleep 10
  done
  case "$rc" in
    0) log "ok: $c can still reach IMDS" ;;
    1) broken+=("$c") ;;
    2) log "skipped: $c isn't running" ;;
  esac
done

if [ "${#broken[@]}" -gt 0 ]; then
  open_guard
  log "ROLLED BACK: ${broken[*]} lost IMDS access with the guard on (probably routed via another network); IMDS is open to all containers again"
  write_metric 0
  exit 1
fi

# App containers: everything on home-platform that isn't part of the stack.
leaks=()
for c in $(docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' home-platform 2>/dev/null); do
  [ "$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null)" = "$project" ] && continue
  if can_reach "$c"; then leaks+=("$c"); else log "ok: $c is blocked from IMDS"; fi
done
if [ "${#leaks[@]}" -gt 0 ]; then
  log "WARNING: still reachable from ${leaks[*]}"
  write_metric 0
  exit 1
fi

write_metric 1
exit 0
