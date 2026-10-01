#!/usr/bin/env bash
# Voice job (ADR-0022): redeploy the hub stack, same script as Platform
# deploy. compose/aws was staged from main by voice-job.yml.
# Usage: deploy-hub.sh <bucket>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
if ! bash "$HERE/../hub/deploy-hub-stack.sh" "$1"; then
  echo "RESULT: hub deploy failed; check the run log."
  exit 1
fi
cd /home/ec2-user/compose-aws
total=$(docker compose ps -a --format '{{.Service}}' | wc -l)
running=$(docker compose ps --status running --format '{{.Service}}' | wc -l)
if [ "$running" -lt "$total" ]; then
  down=$(comm -23 <(docker compose ps -a --format '{{.Service}}' | sort) <(docker compose ps --status running --format '{{.Service}}' | sort) | paste -sd, -)
  echo "RESULT: hub redeployed, but only $running of $total services are running; not running: ${down//,/, }."
  exit 1
fi
echo "RESULT: hub redeployed, all $total services running."
