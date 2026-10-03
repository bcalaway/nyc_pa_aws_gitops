#!/usr/bin/env bash
# Runs ON the hub as root, from the SSM document <app>-deploy (Milestone 20,
# ADR-0025). Was a script assembled inside app-deploy.yml and sent with
# AWS-RunShellScript, which let any holder of an app's CI role run any
# command on the hub; now the script is fixed in Terraform and the only
# input is the app name, which the document hard-codes per app.
#
# Pulls the app's Compose file (staged by app-deploy.yml in S3), writes its
# .env from SSM with the hub's own role, checks every service has a memory
# limit (ADR-0026, compose-mem-check.py beside this script), and brings it up.
# Then delivers the app's Airflow DAGs, if it has any (ADR-0031, app-dags.py).
#
# Usage: app-deploy.sh <bucket> <app>
set -euo pipefail
BUCKET="$1" APP="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
[[ "$APP" =~ ^[a-z][a-z0-9-]{0,30}$ ]] || { echo "RESULT: bad app name."; exit 1; }
[[ "$BUCKET" =~ ^[a-z0-9.-]+$ ]] || { echo "RESULT: bad bucket."; exit 1; }

DIR="/home/ec2-user/apps/${APP}"
mkdir -p "$DIR"
# Staged beside the live file and only moved into place once it passes the
# memory-limit check, so a rejected fragment never replaces the running one.
NEW="$DIR/docker-compose.yml.new"
aws s3 cp "s3://${BUCKET}/apps/${APP}/docker-compose.yml" "$NEW" --only-show-errors
aws ecr get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin 147856894209.dkr.ecr.us-east-1.amazonaws.com >/dev/null

# .env: everything under /home-platform/<app>/ (name -> UPPER_SNAKE), plus
# the platform-issued Postgres and Authentik credentials.
umask 077
ENV_TMP=$(mktemp "$DIR/.env.XXXXXX")
aws ssm get-parameters-by-path --path "/home-platform/${APP}/" --with-decryption \
  --query "Parameters[*].[Name,Value]" --output text \
  | while IFS=$'\t' read -r name value; do
      [ -n "$name" ] || continue
      key=$(basename "$name" | tr 'a-z-' 'A-Z_')
      echo "${key}=${value}"
    done > "$ENV_TMP"
for cred in "postgres:${APP}-password:POSTGRES_PASSWORD" \
            "authentik:${APP}-client-id:AUTHENTIK_CLIENT_ID" \
            "authentik:${APP}-client-secret:AUTHENTIK_CLIENT_SECRET"; do
  IFS=: read -r ns param key <<<"$cred"
  value=$(aws ssm get-parameter --name "/home-platform/${ns}/${param}" --with-decryption \
            --query Parameter.Value --output text 2>/dev/null || true)
  [ -n "$value" ] && echo "${key}=${value}" >> "$ENV_TMP"
done
mv -f "$ENV_TMP" "$DIR/.env"
chmod 600 "$DIR/.env"

cd "$DIR"
if ! check=$(docker compose -f "$NEW" config --format json | python3 "$HERE/compose-mem-check.py"); then
  rm -f "$NEW"
  echo "RESULT: ${APP} not deployed: ${check}"
  exit 1
fi
echo "$check"
mv -f "$NEW" docker-compose.yml
docker compose pull --quiet
docker compose up -d

# Airflow DAGs (ADR-0031), after the app is up so a DAG never calls an
# endpoint its app doesn't have yet. Staged by app-deploy.yml on every
# deploy (empty when the repo has none); checked by app-dags.py before any
# file reaches Airflow's DAG folder. Delivered only for airflow: true apps,
# which are exactly the ones with an AIRFLOW_TOKEN in their .env.
DAGS_ROOT=/home/ec2-user/airflow/dags
dags_note="no DAGs"
DAG_TAR=$(mktemp)
DAG_STAGE=$(mktemp -d)
trap 'rm -rf "$DAG_TAR" "$DAG_STAGE"' EXIT
if ! aws s3 cp "s3://${BUCKET}/apps/${APP}/dags.tar.gz" "$DAG_TAR" --only-show-errors 2>/dev/null; then
  dags_note="no DAG archive staged"
elif ! n=$(python3 "$HERE/app-dags.py" "$DAG_TAR" "$DAG_STAGE"); then
  echo "RESULT: ${APP} deployed, but its DAGs were rejected (Airflow unchanged): ${n}"
  exit 1
elif [ "$n" -gt 0 ]; then
  if ! grep -q '^AIRFLOW_TOKEN=' .env; then
    dags_note="${n} DAG files NOT delivered: ${APP} isn't airflow: true in apps/registry.yml (or the hub stack hasn't deployed since)"
  elif [ ! -d "$DAGS_ROOT" ]; then
    dags_note="${n} DAG files NOT delivered: no Airflow DAG folder on the hub"
  else
    install -d -m 0755 -o ec2-user -g ec2-user "$DAGS_ROOT/$APP"
    rsync -r --checksum --delete --chmod=D755,F644 "$DAG_STAGE/" "$DAGS_ROOT/$APP/"
    chown -R ec2-user:ec2-user "$DAGS_ROOT/$APP"
    dags_note="${n} DAG files delivered to dags/${APP}/"
  fi
elif [ -d "$DAGS_ROOT/$APP" ]; then
  # The repo has no DAGs any more: remove the ones it used to deliver.
  rm -rf "${DAGS_ROOT:?}/${APP:?}"
  dags_note="DAGs removed (none in the repo)"
fi
echo "RESULT: ${APP} deployed; ${dags_note}."
