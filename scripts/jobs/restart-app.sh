#!/usr/bin/env bash
# Voice job (ADR-0022): restart one app's containers, then wait for its
# /health through Traefik on this host. Usage: restart-app.sh <bucket> <app>
set -euo pipefail
APP="$2"
case "$APP" in todo-app|hue) ;; *) echo "RESULT: I can't restart $APP."; exit 2 ;; esac

DIR="/home/ec2-user/apps/$APP"
HOST="$APP.billandjessie.com"
[ -f "$DIR/docker-compose.yml" ] || { echo "RESULT: $APP isn't deployed on the hub."; exit 1; }

cd "$DIR"
docker compose restart
start=$(date +%s)
# Through Traefik on this host (--resolve), the same URL platform_status
# checks, so "healthy" here means healthy from outside too.
for _ in $(seq 1 30); do
  if code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 --resolve "$HOST:443:127.0.0.1" "https://$HOST/health") \
     && [ "$code" -lt 400 ] && [ "$code" -ge 200 ]; then
    echo "RESULT: $APP restarted, health check OK after $(( $(date +%s) - start )) seconds."
    exit 0
  fi
  sleep 2
done
docker compose ps
echo "RESULT: $APP restarted but its health check is still failing after a minute (last status ${code:-none})."
exit 1
