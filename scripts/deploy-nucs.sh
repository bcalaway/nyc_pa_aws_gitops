#!/usr/bin/env bash
# Runs the Ansible NUC-provisioning playbook from the EC2 hub.
# Ansible's control node doesn't support Windows, so this pushes ansible/ and
# compose/nuc/ to EC2 (which already has WireGuard routes to both site LANs)
# and triggers the run there via SSH.
# Requires: WireGuard tunnel active, AWS credentials configured, EC2 SSH key
# at ~/.ssh/home-platform.pem.
# Linux counterpart of deploy-nucs.ps1 -- keep both in sync when changing deploy logic.

set -euo pipefail

SSH_KEY="$HOME/.ssh/home-platform.pem"
EC2_HOST="ec2-user@10.0.3.1"
REMOTE_DIR="/home/ec2-user/home-platform"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$SCRIPT_DIR/.."

echo "Fetching Ansible NUC private key from SSM..."
NUC_KEY=$(aws ssm get-parameter --name "/home-platform/ansible/nuc-private-key" --with-decryption --region us-east-1 --query "Parameter.Value" --output text)
NUC_KEY_UNIX=$(printf '%s' "$NUC_KEY" | tr -d '\r')

echo "Ensuring Ansible is installed on EC2..."
ssh -i "$SSH_KEY" "$EC2_HOST" "command -v ansible-playbook >/dev/null 2>&1 || sudo dnf install -y ansible-core"

echo "Copying ansible/ and compose/nuc/ to EC2..."
ssh -i "$SSH_KEY" "$EC2_HOST" "mkdir -p $REMOTE_DIR/ansible $REMOTE_DIR/compose/nuc"
scp -i "$SSH_KEY" -r "$REPO_ROOT"/ansible/* "$EC2_HOST:$REMOTE_DIR/ansible/"
scp -i "$SSH_KEY" -r "$REPO_ROOT"/compose/nuc/* "$EC2_HOST:$REMOTE_DIR/compose/nuc/"

echo "Installing NUC SSH key on EC2..."
TMP_KEY_FILE=$(mktemp)
printf '%s\n' "$NUC_KEY_UNIX" > "$TMP_KEY_FILE"
ssh -i "$SSH_KEY" "$EC2_HOST" "mkdir -p ~/.ssh"
scp -i "$SSH_KEY" "$TMP_KEY_FILE" "$EC2_HOST:~/.ssh/ansible-nuc"
ssh -i "$SSH_KEY" "$EC2_HOST" "chmod 600 ~/.ssh/ansible-nuc"
rm -f "$TMP_KEY_FILE"

echo "Running playbook..."
ssh -i "$SSH_KEY" "$EC2_HOST" "cd $REMOTE_DIR/ansible && ansible-playbook site.yml"

echo "Done."
