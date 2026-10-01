#!/usr/bin/env bash
# Voice job (ADR-0022): remove unused images older than 7 days. Images used
# by any container (running or stopped) are never touched, so nothing that
# is deployed can be removed. Usage: hub-docker-prune.sh <bucket>
set -euo pipefail
out=$(docker image prune -af --filter "until=168h")
echo "$out"
freed=$(sed -n 's/^Total reclaimed space: //p' <<<"$out")
free=$(df -h --output=avail / | tail -1 | tr -d ' ')
echo "RESULT: Docker cleanup freed ${freed:-0B}; the hub now has $free free."
