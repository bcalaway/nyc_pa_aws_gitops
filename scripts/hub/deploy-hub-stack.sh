#!/usr/bin/env bash
# Runs ON the EC2 hub (as root, via SSM Run Command from
# .github/workflows/platform-deploy.yml). Hub-side counterpart of
# scripts/deploy-aws-stack.sh: same secrets, same stale-file handling, same
# compose commands -- keep the SSM parameter list below in sync with that
# script when adding a secret.
#
# Secrets are read here with the hub's own instance role
# (terraform/aws/tls.tf, hub_platform_deploy), so they never transit the
# GitHub workflow, its logs, or S3 -- same rule as app-deploy.yml.
#
# Usage: deploy-hub-stack.sh <deploy-bucket>

set -euo pipefail

BUCKET="$1"
REMOTE_DIR="/home/ec2-user/compose-aws"
STAGING="/home/ec2-user/.deploy-staging/compose-aws"
REGION="us-east-1"

command -v rsync >/dev/null 2>&1 || dnf install -y rsync

echo "Syncing compose/aws from S3 to staging..."
mkdir -p "$STAGING" "$REMOTE_DIR"
# --exact-timestamps: without it, S3->local sync skips any file whose size
# didn't change unless the local copy is newer, so a same-length edit (a
# version bump like 1.43.105 -> 1.43.106) never reaches the hub
# (docs/gotchas.md, 2026-10-03). rsync below still only touches files whose
# content actually changed.
aws s3 sync "s3://${BUCKET}/compose-aws/" "$STAGING/" --delete --exact-timestamps --only-show-errors

# rsync --inplace, not a plain copy or `aws s3 sync` straight into
# REMOTE_DIR: both of those replace files via a new inode, and a container
# that isn't recreated keeps seeing the old inode of any single-file bind
# mount. --inplace rewrites existing files in the same inode, and existing
# directories are never recreated (see docs/gotchas.md, the 2026-07-12
# Grafana provisioning incident). --delete removes files that are gone from
# the repo; .env is excluded so it's never deleted between the sync and the
# rewrite below.
echo "Updating ${REMOTE_DIR}..."
rsync -rlt --inplace --checksum --delete --exclude='/.env' --itemize-changes "$STAGING/" "$REMOTE_DIR/"

ssm() {
  aws ssm get-parameter --name "$1" --with-decryption --region "$REGION" --query "Parameter.Value" --output text
}

# Authentik API token for home-mcp's read-only audit service account
# (ADR-0024, blueprints/home-mcp-audit.yaml). Generated here on the first
# deploy that needs it and kept in SSM, so the blueprint and home-mcp
# always agree and nobody has to create it by hand. The hub role can write
# only this one parameter (terraform/aws/tls.tf, hub_platform_deploy).
#
# generated_secret <parameter> <generator command...>: same generate-once
# pattern for any platform-owned secret (Airflow's, ADR-0027, below). The
# hub role can write only the parameters terraform/aws/tls.tf lists.
generated_secret() {
  local p="$1" v err; shift
  if v=$(ssm "$p" 2>/tmp/gen-secret.err) && [ -n "$v" ]; then
    echo "$v"
    return
  fi
  err=$(cat /tmp/gen-secret.err); rm -f /tmp/gen-secret.err
  # Only create it when it genuinely doesn't exist -- never replace an
  # existing secret because of a transient read error. An empty result
  # trips the empty-value check below and stops the deploy.
  grep -q ParameterNotFound <<<"$err" || return 0
  v=$("$@")
  aws ssm put-parameter --name "$p" --type SecureString --value "$v" --region "$REGION" >/dev/null && echo "$v"
}
audit_token() { generated_secret /home-platform/authentik/home-mcp-audit-token openssl rand -hex 32; }
# Fernet keys are 32 random bytes, URL-safe base64 (with padding).
fernet_key() { openssl rand -base64 32 | tr '+/' '-_'; }

echo "Building .env from SSM..."
ENV_TMP=$(mktemp "${REMOTE_DIR}/.env.XXXXXX")
chmod 600 "$ENV_TMP"
{
  echo "GRAFANA_SMTP_PASSWORD=$(ssm /home-platform/grafana/smtp-password)"
  echo "POSTGRES_PASSWORD=$(ssm /home-platform/postgres/admin-password)"
  echo "REDIS_PASSWORD=$(ssm /home-platform/authentik/redis-password)"
  echo "RACHIO_API_KEY=$(ssm /home-platform/rachio/api-key)"
  echo "AUTHENTIK_DB_PASSWORD=$(ssm /home-platform/authentik/db-password)"
  echo "AUTHENTIK_SECRET_KEY=$(ssm /home-platform/authentik/secret-key)"
  echo "AUTHENTIK_BOOTSTRAP_PASSWORD=$(ssm /home-platform/authentik/bootstrap-password)"
  echo "AUTHENTIK_GRAFANA_CLIENT_ID=$(ssm /home-platform/authentik/grafana-client-id)"
  echo "AUTHENTIK_GRAFANA_CLIENT_SECRET=$(ssm /home-platform/authentik/grafana-client-secret)"
  echo "AUTHENTIK_TODO_APP_CLIENT_ID=$(ssm /home-platform/authentik/todo-app-client-id)"
  echo "AUTHENTIK_TODO_APP_CLIENT_SECRET=$(ssm /home-platform/authentik/todo-app-client-secret)"
  echo "AUTHENTIK_HUE_CLIENT_ID=$(ssm /home-platform/authentik/hue-client-id)"
  echo "AUTHENTIK_HUE_CLIENT_SECRET=$(ssm /home-platform/authentik/hue-client-secret)"
  echo "AUTHENTIK_HOME_MCP_CLIENT_ID=$(ssm /home-platform/authentik/home-mcp-client-id)"
  echo "AUTHENTIK_HOME_MCP_CLIENT_SECRET=$(ssm /home-platform/authentik/home-mcp-client-secret)"
  # Multi-line private key -> base64 so it survives the .env file as one line.
  echo "VOICE_WORKER_SSH_KEY_B64=$(ssm /home-platform/voice-worker/ssh-private-key | base64 -w0)"
  echo "UMAMI_DB_PASSWORD=$(ssm /home-platform/postgres/umami-password)"
  echo "UMAMI_APP_SECRET=$(ssm /home-platform/umami/app-secret)"
  echo "UMAMI_TWO_FACTOR_KEY=$(ssm /home-platform/umami/two-factor-encryption-key)"
  # Optional (ADR-0022): home-mcp's Actions-only token for voice jobs. Until
  # it's created, voice jobs just report "not set up" -- so a missing
  # parameter writes a placeholder instead of failing the deploy.
  echo "VOICE_JOBS_GITHUB_TOKEN=$(ssm /home-platform/github/voice-jobs-token 2>/dev/null || echo none)"
  # Optional (ADR-0024): home-mcp's read-only token for GitHub security
  # alerts. Until Bill creates it, github_security reports "not set up".
  echo "GITHUB_SECURITY_TOKEN=$(ssm /home-platform/github/security-read-token 2>/dev/null || echo none)"
  echo "AUTHENTIK_HOME_MCP_AUDIT_TOKEN=$(audit_token)"
  # Airflow (ADR-0027, data.yml). The database password comes from the
  # registry's platform_databases onboarding (onboard-app-dbs.sh, which
  # platform-deploy.yml runs before this script).
  echo "AIRFLOW_DB_PASSWORD=$(ssm /home-platform/postgres/airflow-password)"
  echo "AIRFLOW_FERNET_KEY=$(generated_secret /home-platform/airflow/fernet-key fernet_key)"
  echo "AIRFLOW_API_SECRET_KEY=$(generated_secret /home-platform/airflow/api-secret-key openssl rand -hex 32)"
  echo "AIRFLOW_JWT_SECRET=$(generated_secret /home-platform/airflow/jwt-secret openssl rand -hex 32)"
} > "$ENV_TMP"
# A failed lookup inside $(...) doesn't trip set -e (echo's own status
# wins), so check explicitly: an empty value would silently break a service.
if grep -qE '^[A-Z0-9_]+=$' "$ENV_TMP"; then
  echo "ERROR: empty value in generated .env:" >&2
  grep -E '^[A-Z0-9_]+=$' "$ENV_TMP" | cut -d= -f1 >&2
  rm -f "$ENV_TMP"
  exit 1
fi
# Overwrite in place (same inode) rather than mv, for the same bind-mount
# reason as the rsync above.
cat "$ENV_TMP" > "${REMOTE_DIR}/.env"
rm -f "$ENV_TMP"
chmod 600 "${REMOTE_DIR}/.env"

# SSM runs this as root; keep the tree owned by ec2-user like a manual
# deploy leaves it (chown doesn't change inodes).
chown -R ec2-user:ec2-user "$REMOTE_DIR"

# Per-PR previews' network (ADR-0023): internal (no internet), external to
# this stack so preview projects can join it too. Created once.
docker network inspect preview >/dev/null 2>&1 || docker network create --internal preview

# Exposure-check results (ADR-0024): written by a root host unit, read by
# home-mcp through a read-only bind mount. Must exist before compose
# creates the mount, or Docker would create it as an empty root dir anyway.
install -d -m 0755 /var/lib/home-platform/exposure

# Airflow's DAG root (ADR-0027): one folder per project, bind-mounted
# read-only into the Airflow containers. App deploys own dags/<app>/; this
# repo ships only dags/platform/ (platform health DAGs, never app DAGs).
# Must exist before `up`, or Docker would create it root-owned.
AIRFLOW_DAGS=/home/ec2-user/airflow/dags
install -d -m 0755 -o ec2-user -g ec2-user /home/ec2-user/airflow "$AIRFLOW_DAGS" "$AIRFLOW_DAGS/platform"
rsync -rlt --checksum --delete --chmod=D755,F644 "$REMOTE_DIR/airflow/dags/platform/" "$AIRFLOW_DAGS/platform/"
chown -R ec2-user:ec2-user "$AIRFLOW_DAGS/platform"

echo "Starting stack..."
cd "$REMOTE_DIR"
# The stack file is a list of `include`s (ADR-0029), which needs Compose
# >= 2.20. Check before touching anything, then make sure the merged config
# resolves, so an older or broken Compose fails here with the stack running.
compose_ver=$(docker compose version --short | sed 's/^v//')
if [ "$(printf '%s\n' 2.20.0 "$compose_ver" | sort -V | head -1)" != 2.20.0 ]; then
  echo "ERROR: Docker Compose $compose_ver on the hub; the stack needs >= 2.20 for include (ADR-0029)." >&2
  exit 1
fi
echo "Docker Compose $compose_ver"
docker compose config --quiet
# Promtail was replaced by Alloy (2026-10-02). `compose up` leaves a removed
# service's container running, which would ship every log twice; stop it
# first so Alloy also starts from Promtail's final read positions. No-op
# once it's gone.
docker rm -f promtail >/dev/null 2>&1 || true
# --quiet: pull progress is most of the output, and SSM keeps only the first
# 24,000 characters, which would cut off the RESULT line at the end.
docker compose pull --quiet
docker compose build
DEPLOY_START=$(date +%s)
docker compose up -d
# `up` doesn't recreate Prometheus when only prometheus.yml changed (it's a
# bind mount), so the running process keeps the old scrape jobs. SIGHUP
# makes it re-read the file -- but only if it was already running before
# this deploy. If `up` just (re)started it, it has read the new file anyway,
# and a HUP that lands before Prometheus installs its signal handler kills it
# (exit 129).
#
# Sent from INSIDE the container (`docker exec ... kill -HUP 1`), never with
# `docker kill -s HUP`: Docker records any `docker kill` as a manual stop
# (HasBeenManuallyStopped=true, even for a reload signal), so `unless-stopped`
# then refuses to restart the container after a reboot. That's what kept
# Prometheus down after the 2026-10-03 resize (docs/gotchas.md).
prom_started=$(docker inspect -f '{{.State.StartedAt}}' prometheus 2>/dev/null || true)
if [ -n "$prom_started" ] && [ "$(date -d "$prom_started" +%s 2>/dev/null || echo 0)" -lt "$DEPLOY_START" ]; then
  docker exec prometheus kill -HUP 1
else
  echo "Prometheus (re)started by this deploy; skipping the config-reload HUP."
fi
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'

# Host-level units (ADR-0024): pending-update metrics + weekly exposure
# check. After `up` so the backup-metrics volume they write into exists.
echo "Installing host units..."
bash "$STAGING/host/install.sh" "$STAGING" | tee "$STAGING/.host-install.log"
boot=$(sed -n 's/^Boot units: //p' "$STAGING/.host-install.log" | tail -1)

# One-line summary for the run's `result` annotation, which home-mcp's
# last_deploys reads back (GitHub's log downloads aren't reachable from
# Claude's sessions, annotations are): Compose version, what (re)started in
# this deploy, and anything not running.
restarted=() stopped=()
while IFS=$'\t' read -r name state started; do
  [ -n "$name" ] || continue
  [ "$state" = running ] || stopped+=("$name ($state)")
  [ "$(date -d "$started" +%s 2>/dev/null || echo 0)" -ge "$DEPLOY_START" ] && restarted+=("$name")
done < <(docker inspect -f '{{.Name}}{{"\t"}}{{.State.Status}}{{"\t"}}{{.State.StartedAt}}' \
           $(docker compose ps -aq) | sed 's#^/##')
join() { [ $# -gt 0 ] || return 0; printf '%s\n' "$@" | paste -sd, - | sed 's/,/, /g'; }
r=$(join "${restarted[@]}"); n=$(join "${stopped[@]}")
echo "RESULT: hub deployed (Compose ${compose_ver}): $(docker compose ps -q | wc -l) running; restarted: ${r:-none}; not running: ${n:-none}.${boot:+ Boot units: ${boot}.}"
