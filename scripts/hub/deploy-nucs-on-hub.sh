#!/usr/bin/env bash
# Runs ON the EC2 hub (as root, via SSM Run Command from
# .github/workflows/platform-deploy.yml). Hub-side counterpart of
# scripts/deploy-nucs.sh: stages ansible/ and compose/nuc/, refreshes the
# NUC SSH key from SSM, and runs site.yml as ec2-user -- the same user and
# paths a manual run uses, so both paths leave the hub in the same state.
#
# NUCs that don't answer on SSH are skipped rather than failing the run:
# Rambles (nuc5) is closed November through April, and a closed site
# shouldn't block deploys to nuc4. Skipped hosts are listed in the output.
#
# Usage: deploy-nucs-on-hub.sh <deploy-bucket>

set -euo pipefail

BUCKET="$1"
REMOTE_DIR="/home/ec2-user/home-platform"
REGION="us-east-1"
KEY_FILE="/home/ec2-user/.ssh/ansible-nuc"

command -v ansible-playbook >/dev/null 2>&1 || dnf install -y ansible-core

echo "Syncing ansible/ and compose/nuc/ from S3..."
mkdir -p "$REMOTE_DIR/ansible" "$REMOTE_DIR/compose/nuc"
aws s3 sync "s3://${BUCKET}/ansible/" "$REMOTE_DIR/ansible/" --delete --only-show-errors
aws s3 sync "s3://${BUCKET}/compose-nuc/" "$REMOTE_DIR/compose/nuc/" --delete --only-show-errors
chown -R ec2-user:ec2-user "$REMOTE_DIR"

echo "Refreshing NUC SSH key from SSM..."
install -d -m 700 -o ec2-user -g ec2-user /home/ec2-user/.ssh
( umask 077
  aws ssm get-parameter --name /home-platform/ansible/nuc-private-key --with-decryption \
    --region "$REGION" --query Parameter.Value --output text | tr -d '\r' > "$KEY_FILE" )
[ -s "$KEY_FILE" ] || { echo "ERROR: empty NUC key from SSM" >&2; exit 1; }
chown ec2-user:ec2-user "$KEY_FILE"
chmod 600 "$KEY_FILE"

as_ec2() { sudo -u ec2-user -H bash -c "cd '$REMOTE_DIR/ansible' && $1"; }

# Probe each NUC with a cheap ping (SSH + python) and keep only the ones
# that answer. `ansible -o` prints one line per host.
echo "Checking which NUCs are reachable..."
PROBE=$(as_ec2 "ansible nucs -m ping -o -T 10" 2>&1 || true)
echo "$PROBE"
REACHABLE=$(echo "$PROBE" | awk '/ \| SUCCESS/ {print $1}' | paste -sd, -)
SKIPPED=$(echo "$PROBE" | awk '/ \| (UNREACHABLE|FAILED)/ {print $1}' | paste -sd, -)

if [ -z "$REACHABLE" ]; then
  echo "ERROR: no NUCs reachable -- nothing deployed." >&2
  exit 1
fi
[ -n "$SKIPPED" ] && echo "Skipping unreachable NUCs: $SKIPPED"

echo "Running site.yml on: $REACHABLE"
as_ec2 "ansible-playbook site.yml --limit '$REACHABLE'"

[ -n "$SKIPPED" ] && echo "NOTE: not deployed to $SKIPPED (unreachable) -- run again when it's back."
echo "Done."
