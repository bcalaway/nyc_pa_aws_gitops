#!/usr/bin/env bash
# Deploys/updates the AWS monitoring stack (Prometheus, Grafana, Loki, Uptime Kuma) to EC2.
# Requires: WireGuard tunnel active, AWS credentials configured, EC2 SSH key at ~/.ssh/home-platform.pem.
# Linux counterpart of deploy-aws-stack.ps1 -- keep both in sync when changing deploy logic.
# CI deploys use scripts/hub/deploy-hub-stack.sh instead (same SSM parameter
# list, read on the hub) -- a new secret must be added there and to the
# hub_platform_deploy policy in terraform/aws/tls.tf too.

set -euo pipefail

SSH_KEY="$HOME/.ssh/home-platform.pem"
EC2_HOST="ec2-user@10.0.3.1"
REMOTE_DIR="/home/ec2-user/compose-aws"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_DIR="$SCRIPT_DIR/../compose/aws"

ssm() {
  aws ssm get-parameter --name "$1" --with-decryption --region us-east-1 --query "Parameter.Value" --output text
}

echo "Fetching Grafana SMTP password from SSM..."
GRAFANA_SMTP_PASSWORD=$(ssm "/home-platform/grafana/smtp-password")

echo "Fetching Postgres admin password from SSM..."
POSTGRES_PASSWORD=$(ssm "/home-platform/postgres/admin-password")

echo "Fetching Redis password from SSM..."
REDIS_PASSWORD=$(ssm "/home-platform/authentik/redis-password")

echo "Fetching Rachio API key from SSM..."
RACHIO_API_KEY=$(ssm "/home-platform/rachio/api-key")

echo "Fetching Authentik secrets from SSM..."
AUTHENTIK_DB_PASSWORD=$(ssm "/home-platform/authentik/db-password")
AUTHENTIK_SECRET_KEY=$(ssm "/home-platform/authentik/secret-key")
AUTHENTIK_BOOTSTRAP_PASSWORD=$(ssm "/home-platform/authentik/bootstrap-password")
AUTHENTIK_GRAFANA_CLIENT_ID=$(ssm "/home-platform/authentik/grafana-client-id")
AUTHENTIK_GRAFANA_CLIENT_SECRET=$(ssm "/home-platform/authentik/grafana-client-secret")
AUTHENTIK_TODO_APP_CLIENT_ID=$(ssm "/home-platform/authentik/todo-app-client-id")
AUTHENTIK_TODO_APP_CLIENT_SECRET=$(ssm "/home-platform/authentik/todo-app-client-secret")
AUTHENTIK_HUE_CLIENT_ID=$(ssm "/home-platform/authentik/hue-client-id")
AUTHENTIK_HUE_CLIENT_SECRET=$(ssm "/home-platform/authentik/hue-client-secret")
AUTHENTIK_HOME_MCP_CLIENT_ID=$(ssm "/home-platform/authentik/home-mcp-client-id")
AUTHENTIK_HOME_MCP_CLIENT_SECRET=$(ssm "/home-platform/authentik/home-mcp-client-secret")
# Multi-line private key -> base64 so it survives the .env file as one line.
VOICE_WORKER_SSH_KEY_B64=$(ssm "/home-platform/voice-worker/ssh-private-key" | base64 -w0)

echo "Fetching Umami secrets from SSM..."
UMAMI_DB_PASSWORD=$(ssm "/home-platform/postgres/umami-password")
UMAMI_APP_SECRET=$(ssm "/home-platform/umami/app-secret")
UMAMI_TWO_FACTOR_KEY=$(ssm "/home-platform/umami/two-factor-encryption-key")
# Optional (ADR-0022): "none" until the voice jobs token exists.
VOICE_JOBS_GITHUB_TOKEN=$(ssm "/home-platform/github/voice-jobs-token" 2>/dev/null || echo none)
# Optional (ADR-0024): "none" until the GitHub security-read token exists.
GITHUB_SECURITY_TOKEN=$(ssm "/home-platform/github/security-read-token" 2>/dev/null || echo none)
# ADR-0024: home-mcp's Authentik audit token, generated once if missing
# (same as scripts/hub/deploy-hub-stack.sh's audit_token).
if ! AUTHENTIK_HOME_MCP_AUDIT_TOKEN=$(ssm "/home-platform/authentik/home-mcp-audit-token" 2>&1); then
  grep -q ParameterNotFound <<<"$AUTHENTIK_HOME_MCP_AUDIT_TOKEN" || { echo "ERROR: can't read the Authentik audit token from SSM" >&2; exit 1; }
  AUTHENTIK_HOME_MCP_AUDIT_TOKEN=$(openssl rand -hex 32)
  aws ssm put-parameter --name "/home-platform/authentik/home-mcp-audit-token" --type SecureString \
    --value "$AUTHENTIK_HOME_MCP_AUDIT_TOKEN" --region us-east-1 >/dev/null
fi

cat > "$LOCAL_DIR/.env" <<EOF
GRAFANA_SMTP_PASSWORD=$GRAFANA_SMTP_PASSWORD
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
REDIS_PASSWORD=$REDIS_PASSWORD
RACHIO_API_KEY=$RACHIO_API_KEY
AUTHENTIK_DB_PASSWORD=$AUTHENTIK_DB_PASSWORD
AUTHENTIK_SECRET_KEY=$AUTHENTIK_SECRET_KEY
AUTHENTIK_BOOTSTRAP_PASSWORD=$AUTHENTIK_BOOTSTRAP_PASSWORD
AUTHENTIK_GRAFANA_CLIENT_ID=$AUTHENTIK_GRAFANA_CLIENT_ID
AUTHENTIK_GRAFANA_CLIENT_SECRET=$AUTHENTIK_GRAFANA_CLIENT_SECRET
AUTHENTIK_TODO_APP_CLIENT_ID=$AUTHENTIK_TODO_APP_CLIENT_ID
AUTHENTIK_TODO_APP_CLIENT_SECRET=$AUTHENTIK_TODO_APP_CLIENT_SECRET
AUTHENTIK_HUE_CLIENT_ID=$AUTHENTIK_HUE_CLIENT_ID
AUTHENTIK_HUE_CLIENT_SECRET=$AUTHENTIK_HUE_CLIENT_SECRET
AUTHENTIK_HOME_MCP_CLIENT_ID=$AUTHENTIK_HOME_MCP_CLIENT_ID
AUTHENTIK_HOME_MCP_CLIENT_SECRET=$AUTHENTIK_HOME_MCP_CLIENT_SECRET
VOICE_WORKER_SSH_KEY_B64=$VOICE_WORKER_SSH_KEY_B64
UMAMI_DB_PASSWORD=$UMAMI_DB_PASSWORD
UMAMI_APP_SECRET=$UMAMI_APP_SECRET
UMAMI_TWO_FACTOR_KEY=$UMAMI_TWO_FACTOR_KEY
VOICE_JOBS_GITHUB_TOKEN=$VOICE_JOBS_GITHUB_TOKEN
GITHUB_SECURITY_TOKEN=$GITHUB_SECURITY_TOKEN
AUTHENTIK_HOME_MCP_AUDIT_TOKEN=$AUTHENTIK_HOME_MCP_AUDIT_TOKEN
EOF

echo "Copying compose stack to EC2..."
ssh -i "$SSH_KEY" "$EC2_HOST" "mkdir -p $REMOTE_DIR"

# Delete remote files that no longer exist locally before copying. scp -r alone
# only adds/overwrites, so a removed dashboard/config would silently keep being
# provisioned forever -- confirmed 2026-07-12 when a couple of deleted dashboard
# JSON files kept getting served after being removed from this repo.
#
# IMPORTANT: this must delete individual stale FILES, never directories. An
# earlier version of this fix did `rm -rf $REMOTE_DIR && mkdir -p` before
# copying, which recreates directories like grafana/provisioning with a new
# inode -- for a container that's still running (not recreated, since no
# service definition changed) with that path bind-mounted, Docker's bind mount
# doesn't follow the path to the new inode, so the container sees "no such
# file or directory" until it's restarted. Confirmed live: this broke Grafana's
# dashboard provisioning the same day this fix was first added. Deleting only
# the specific stale files (not their parent directories) avoids the problem
# entirely, since existing directory inodes are never touched.
mapfile -t LOCAL_FILES < <(cd "$LOCAL_DIR" && find . -type f -printf '%P\n')
mapfile -t REMOTE_FILES < <(ssh -i "$SSH_KEY" "$EC2_HOST" "find $REMOTE_DIR -type f -printf '%P\n'" | grep -v '^\.env$' || true)
mapfile -t STALE_FILES < <(comm -23 <(printf '%s\n' "${REMOTE_FILES[@]}" | sort) <(printf '%s\n' "${LOCAL_FILES[@]}" | sort))
for f in "${STALE_FILES[@]}"; do
  [ -z "$f" ] && continue
  echo "  Removing stale remote file: $f"
  ssh -i "$SSH_KEY" "$EC2_HOST" "rm -f '$REMOTE_DIR/$f'"
done

scp -i "$SSH_KEY" -r "$LOCAL_DIR"/* "$EC2_HOST:$REMOTE_DIR/"
scp -i "$SSH_KEY" "$LOCAL_DIR/.env" "$EC2_HOST:$REMOTE_DIR/.env"

# Per-PR previews' network (ADR-0023), created once; see deploy-hub-stack.sh.
ssh -i "$SSH_KEY" "$EC2_HOST" "docker network inspect preview >/dev/null 2>&1 || docker network create --internal preview"
# Exposure-check results dir (ADR-0024), bind-mounted into home-mcp.
ssh -i "$SSH_KEY" "$EC2_HOST" "sudo install -d -m 0755 /var/lib/home-platform/exposure"

echo "Starting stack..."
# Promtail -> Alloy (2026-10-02): remove the old container first; see deploy-hub-stack.sh.
ssh -i "$SSH_KEY" "$EC2_HOST" "docker rm -f promtail >/dev/null 2>&1 || true"
ssh -i "$SSH_KEY" "$EC2_HOST" "cd $REMOTE_DIR && docker compose pull && docker compose build && docker compose up -d && docker kill -s HUP prometheus >/dev/null"

echo "Installing host units (ADR-0024)..."
ssh -i "$SSH_KEY" "$EC2_HOST" "sudo bash $REMOTE_DIR/host/install.sh $REMOTE_DIR"

echo "Done. Services on EC2 (reachable via WireGuard):"
echo "  Grafana:      http://10.0.3.1:3000"
echo "  Prometheus:   http://10.0.3.1:9090"
echo "  Uptime Kuma:  http://10.0.3.1:3001"
echo "  Loki:         http://10.0.3.1:3100"
