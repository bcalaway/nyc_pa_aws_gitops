#!/usr/bin/env bash
# Runs ON the hub (root, via SSM). Removes one per-PR preview completely
# (ADR-0023): containers, its database and role, and its files. Safe to
# run when the preview doesn't exist. Usage: preview-down.sh <app> <pr>
set -euo pipefail
APP="$1" PR="$2"
[[ "$APP" =~ ^[a-z0-9-]+$ && "$PR" =~ ^[0-9]+$ ]] || { echo "RESULT: bad preview arguments."; exit 1; }
PROJ="${APP}-pr${PR}"
DIR="/home/ec2-user/previews/${PROJ}"

docker compose -p "$PROJ" down --remove-orphans --volumes 2>/dev/null || true
docker exec -i postgres psql -U postgres -v ON_ERROR_STOP=1 -qtAX <<SQL
DROP DATABASE IF EXISTS "${PROJ}" WITH (FORCE);
DROP ROLE IF EXISTS "${PROJ}";
SQL
rm -rf "$DIR"
echo "RESULT: preview $PROJ removed."
