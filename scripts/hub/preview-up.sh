#!/usr/bin/env bash
# Runs ON the hub (root, via SSM from app-preview.yml). Brings up or
# updates one per-PR preview (ADR-0023):
#   - project/role/database/host name: <app>-pr<n>
#   - first deploy: a Postgres role + database owned by it, seeded with a
#     copy of the app's production database (--no-owner --no-acl, restored
#     *as the preview role*, so it owns everything and nothing else)
#   - the Compose file was already rewritten by the workflow (preview
#     network only, no production secrets, preview Traefik labels); this
#     adds a .env with only the preview DB password and a session secret
#   - at most MAX_PREVIEWS running at once
# Usage: preview-up.sh <bucket> <app> <repo> <pr> <service> <port>
# Ends with one `RESULT:` line; exit 3 means "no capacity", not an error.
set -euo pipefail

BUCKET="$1" APP="$2" REPO="$3" PR="$4" SERVICE="$5" PORT="$6"
MAX_PREVIEWS=2
[[ "$APP" =~ ^[a-z0-9-]+$ && "$REPO" =~ ^[A-Za-z0-9_.-]+$ && "$PR" =~ ^[0-9]+$ \
   && "$SERVICE" =~ ^[a-z0-9_-]+$ && "$PORT" =~ ^[0-9]+$ ]] || { echo "RESULT: bad preview arguments."; exit 1; }

PROJ="${APP}-pr${PR}"
HOST="${PROJ}.preview.billandjessie.com"
DIR="/home/ec2-user/previews/${PROJ}"
psql_admin() { docker exec -i postgres psql -U postgres -v ON_ERROR_STOP=1 -qtAX "$@"; }

# Capacity: running preview projects other than this one.
others=$(docker compose ls --format json | python3 -c '
import json, re, sys
proj = sys.argv[1]
print(sum(1 for p in json.load(sys.stdin)
          if re.fullmatch(r"[a-z0-9-]+-pr[0-9]+", p["Name"]) and p["Name"] != proj
          and p["Status"].startswith("running")))' "$PROJ")
if [ "$others" -ge "$MAX_PREVIEWS" ]; then
  echo "RESULT: no room for $PROJ: $others previews are already running (limit $MAX_PREVIEWS). Close a PR or run preview cleanup."
  exit 3
fi

docker network inspect preview >/dev/null 2>&1 || { echo "RESULT: the preview network doesn't exist yet; deploy the hub stack first."; exit 1; }
for c in traefik postgres; do
  docker inspect -f '{{json .NetworkSettings.Networks}}' "$c" | grep -q '"preview"' \
    || { echo "RESULT: $c isn't on the preview network yet; deploy the hub stack first."; exit 1; }
done

mkdir -p "$DIR"
chmod 700 "$DIR"
aws s3 cp "s3://${BUCKET}/apps/${APP}/previews/pr-${PR}/docker-compose.yml" "$DIR/docker-compose.yml" --only-show-errors

# First deploy of this PR: role, database, copy of production data.
if [ ! -f "$DIR/.env" ]; then
  pw=$(openssl rand -hex 24)
  psql_admin <<SQL
DROP DATABASE IF EXISTS "${PROJ}" WITH (FORCE);
DROP ROLE IF EXISTS "${PROJ}";
CREATE ROLE "${PROJ}" LOGIN PASSWORD '${pw}' NOSUPERUSER NOCREATEDB NOCREATEROLE;
CREATE DATABASE "${PROJ}" OWNER "${PROJ}";
SQL
  if [ "$(psql_admin -c "SELECT 1 FROM pg_database WHERE datname = '${APP}'")" = "1" ]; then
    docker exec postgres pg_dump -U postgres --no-owner --no-acl "$APP" \
      | docker exec -i -e PGPASSWORD="$pw" postgres psql -h localhost -U "$PROJ" -d "$PROJ" -v ON_ERROR_STOP=1 -q
    seeded="with a copy of production data"
  else
    seeded="with an empty database"
  fi
  umask 077
  printf 'POSTGRES_PASSWORD=%s\nSESSION_SECRET=%s\n' "$pw" "$(openssl rand -hex 32)" > "$DIR/.env"
  printf 'repo=%s\npr=%s\napp=%s\ncreated=%s\nhost=%s\n' "$REPO" "$PR" "$APP" "$(date +%s)" "$HOST" > "$DIR/meta"
else
  seeded="keeping its existing database"
fi

aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 147856894209.dkr.ecr.us-east-1.amazonaws.com >/dev/null
cd "$DIR"
docker compose -p "$PROJ" pull --quiet
docker compose -p "$PROJ" up -d --remove-orphans

# Health from inside the preview network (via Traefik's container), since
# the public URL is behind forward-auth.
for _ in $(seq 1 30); do
  if docker exec traefik wget -q -T 5 -O /dev/null "http://${PROJ}-${SERVICE}-1:${PORT}/health" 2>/dev/null; then
    echo "RESULT: preview ready at https://${HOST} (${seeded})."
    exit 0
  fi
  sleep 2
done
docker compose -p "$PROJ" logs --tail 40 || true
echo "RESULT: $PROJ started but its health check didn't pass within a minute; see the run log."
exit 1
