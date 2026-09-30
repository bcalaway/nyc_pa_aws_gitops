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
aws s3 sync "s3://${BUCKET}/compose-aws/" "$STAGING/" --delete --only-show-errors

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

echo "Starting stack..."
cd "$REMOTE_DIR"
docker compose pull
docker compose build
docker compose up -d
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Status}}'
