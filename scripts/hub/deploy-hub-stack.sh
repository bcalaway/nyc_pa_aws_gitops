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
# No -t: since the S3 download uses --exact-timestamps, every staged file has
# a fresh mtime on each deploy, and preserving times made --itemize-changes
# list every file (pushing the RESULT line past SSM's 24,000-character
# output limit). Without -t, only files whose content changed are listed and
# written.
rsync -rl --inplace --checksum --delete --exclude='/.env' --itemize-changes "$STAGING/" "$REMOTE_DIR/"

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
# home-mcp's Grafana token (its grafana_alerts tool): a Viewer service account
# "home-mcp", created once with Grafana's admin login and kept in SSM like the
# secrets above. "none" whenever it can't be made yet (Grafana not up, or the
# Terraform grant not applied), so the tool says "not set up" and a later
# deploy finishes the job, instead of this deploy failing.
grafana_home_mcp_token() {
  local p=/home-platform/grafana/home-mcp-token v pw
  if v=$(ssm "$p" 2>/tmp/gf-token.err) && [ -n "$v" ]; then echo "$v"; return; fi
  grep -q ParameterNotFound /tmp/gf-token.err 2>/dev/null || { echo none; return; }
  pw=$(ssm /home-platform/grafana/admin-password 2>/dev/null) || { echo none; return; }
  v=$(GF_ADMIN_PASSWORD="$pw" python3 - <<'PY'
import base64, json, os, time, urllib.request
base = "http://127.0.0.1:3000"
auth = "Basic " + base64.b64encode(("admin:" + os.environ["GF_ADMIN_PASSWORD"]).encode()).decode()
def call(method, path, body=None):
    req = urllib.request.Request(base + path, method=method, headers={"Authorization": auth, "Content-Type": "application/json"},
                                 data=json.dumps(body).encode() if body is not None else None)
    with urllib.request.urlopen(req, timeout=10) as r:
        return json.load(r)
found = call("GET", "/api/serviceaccounts/search?query=home-mcp")["serviceAccounts"]
sa = next((a for a in found if a["name"] == "home-mcp"), None) or call("POST", "/api/serviceaccounts", {"name": "home-mcp", "role": "Viewer"})
print(call("POST", f"/api/serviceaccounts/{sa['id']}/tokens", {"name": f"home-mcp-{int(time.time())}"})["key"])
PY
  ) || { echo "Grafana token for home-mcp not created yet (Grafana unreachable or login refused)." >&2; echo none; return; }
  aws ssm put-parameter --name "$p" --type SecureString --value "$v" --region "$REGION" >/dev/null && echo "$v" || echo none
}
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
  echo "GRAFANA_HOME_MCP_TOKEN=$(grafana_home_mcp_token)"
  # Airflow (ADR-0027, data.yml). The database password comes from the
  # registry's platform_databases onboarding (onboard-app-dbs.sh, which
  # platform-deploy.yml runs before this script).
  echo "AIRFLOW_DB_PASSWORD=$(ssm /home-platform/postgres/airflow-password)"
  echo "AIRFLOW_FERNET_KEY=$(generated_secret /home-platform/airflow/fernet-key fernet_key)"
  echo "AIRFLOW_API_SECRET_KEY=$(generated_secret /home-platform/airflow/api-secret-key openssl rand -hex 32)"
  echo "AIRFLOW_JWT_SECRET=$(generated_secret /home-platform/airflow/jwt-secret openssl rand -hex 32)"
  # home-mcp's read-only token for mkt-data's GET job endpoints (its capture
  # tools). mkt-data reads the same parameter through its own deploy, as
  # READ_TOKEN. "none" until it exists (e.g. before the Terraform grant is
  # applied), so the tools say "not set up" instead of the deploy failing.
  mkt_read=$(generated_secret /home-platform/mkt-data/read-token openssl rand -hex 32 2>/dev/null || true)
  echo "MKT_DATA_READ_TOKEN=${mkt_read:-none}"
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
# The app-job helper and the ignore file that keeps it from being parsed as
# a DAG (ADR-0031). At the DAG root so every app's DAGs can import it.
for f in home_platform_jobs.py .airflowignore; do
  install -m 0644 -o ec2-user -g ec2-user "$REMOTE_DIR/airflow/dags/$f" "$AIRFLOW_DAGS/$f"
done

# Airflow's connections to apps (ADR-0031): for every registry app with
# airflow: true, a job token generated once into SSM at
# /home-platform/<app>/airflow-token (the app gets the same token as
# AIRFLOW_TOKEN through its own deploy) and AIRFLOW_CONN_<APP> for the
# scheduler. The registry comes from platform-deploy.yml's S3 staging.
echo "Building Airflow app connections from the registry..."
aws s3 cp "s3://${BUCKET}/apps-registry/registry.json" /tmp/registry.json --only-show-errors
AIRFLOW_APPS=$(python3 - /tmp/registry.json <<'PY'
import json, re, sys
reg = json.load(open(sys.argv[1]))
for a in reg["apps"]:
    if a.get("airflow", False) is True:
        if not re.fullmatch(r"[a-z][a-z0-9-]{1,30}[a-z0-9]", a["name"]):
            sys.exit(f"bad app name in registry: {a['name']!r}")
        print(a["name"])
PY
)
rm -f /tmp/registry.json
CONN_TMP=$(mktemp /home/ec2-user/airflow/.connections.env.XXXXXX)
chmod 600 "$CONN_TMP"
echo "# Generated by scripts/hub/deploy-hub-stack.sh (ADR-0031). Do not edit." > "$CONN_TMP"
for app in $AIRFLOW_APPS; do
  token=$(generated_secret "/home-platform/${app}/airflow-token" openssl rand -hex 32)
  if [ -z "$token" ]; then
    echo "ERROR: no Airflow job token for ${app} (/home-platform/${app}/airflow-token)." >&2
    rm -f "$CONN_TMP"
    exit 1
  fi
  echo "AIRFLOW_CONN_$(tr 'a-z-' 'A-Z_' <<<"$app")=http://:${token}@${app}:8000" >> "$CONN_TMP"
done
cat "$CONN_TMP" > /home/ec2-user/airflow/connections.env
rm -f "$CONN_TMP"
chmod 600 /home/ec2-user/airflow/connections.env
chown ec2-user:ec2-user /home/ec2-user/airflow/connections.env
echo "Airflow apps: ${AIRFLOW_APPS:-none}" | tr '\n' ' '; echo

echo "Starting stack..."
cd "$REMOTE_DIR"
# The stack file is a list of `include`s (ADR-0029, Compose >= 2.20) and
# the scheduler's env_file is optional (ADR-0031, >= 2.24): needs >= 2.24. Check before touching anything, then make sure the merged config
# resolves, so an older or broken Compose fails here with the stack running.
compose_ver=$(docker compose version --short | sed 's/^v//')
if [ "$(printf '%s\n' 2.24.0 "$compose_ver" | sort -V | head -1)" != 2.24.0 ]; then
  echo "ERROR: Docker Compose $compose_ver on the hub; the stack needs >= 2.24 (include, ADR-0029; optional env_file, ADR-0031)." >&2
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
# Grafana reads its alerting provisioning (alert rules, contact points,
# notification policies) only at startup. Unlike dashboards, it doesn't
# poll. So restart it when those files changed since the last deploy, unless
# `up` just (re)started it anyway. That's what left the mkt-data alert group
# unloaded after PR #110 (docs/gotchas.md). The hash lives outside the synced
# directory so the --delete sync can't remove it.
alert_state=/var/lib/home-platform/grafana-alerting.sha256
alert_sha=$(cd "$REMOTE_DIR/grafana/provisioning/alerting" && sha256sum -- * | sha256sum | cut -d' ' -f1)
if [ "$(cat "$alert_state" 2>/dev/null)" != "$alert_sha" ]; then
  graf_started=$(docker inspect -f '{{.State.StartedAt}}' grafana 2>/dev/null || true)
  if [ -n "$graf_started" ] && [ "$(date -d "$graf_started" +%s 2>/dev/null || echo 0)" -lt "$DEPLOY_START" ]; then
    echo "Grafana alerting provisioning changed; restarting Grafana to load it."
    docker compose restart grafana
  fi
  echo "$alert_sha" > "$alert_state"
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
