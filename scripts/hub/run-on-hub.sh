#!/usr/bin/env bash
# Runs ON A GITHUB RUNNER (not the hub): ships one of these scripts to the
# hub via SSM Run Command, waits, prints its output, and fails if it did.
# The script travels base64-encoded inside the command (no S3 staging), so
# callers only need ssm:SendCommand on the hub plus ec2:DescribeInstances,
# which every app's CI role already has (app-deploy.yml).
#
# Usage: run-on-hub.sh <script> [args...]   (args: simple tokens only)
# Writes the script's last `RESULT:` line to $GITHUB_OUTPUT as `result`.
set -uo pipefail
SCRIPT="$1"; shift
for a in "$@"; do
  [[ "$a" =~ ^[A-Za-z0-9._:/-]+$ ]] || { echo "::error::refusing unsafe argument: $a"; exit 1; }
done

HUB_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=home-platform-hub" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
if [ -z "$HUB_ID" ] || [ "$HUB_ID" = "None" ]; then
  echo "::error::Could not find a running home-platform-hub instance"; exit 1
fi

name="$(basename "$SCRIPT" .sh)-${GITHUB_RUN_ID:-local}-$$"
b64=$(base64 -w0 "$SCRIPT")
CMD=$(jq -n --arg b64 "$b64" --arg n "$name" --arg args "$*" '{
  commands: [
    ("echo " + $b64 + " | base64 -d > /tmp/" + $n + ".sh"),
    ("bash /tmp/" + $n + ".sh " + $args + " > /tmp/" + $n + ".log 2>&1; rc=$?"),
    ("tail -c 20000 /tmp/" + $n + ".log; rm -f /tmp/" + $n + ".sh /tmp/" + $n + ".log"),
    "exit $rc"
  ],
  executionTimeout: ["1200"]
}')
CMD_ID=$(aws ssm send-command --instance-ids "$HUB_ID" --document-name AWS-RunShellScript \
  --comment "$(basename "$SCRIPT") ${GITHUB_REPOSITORY:-} run ${GITHUB_RUN_ID:-}" \
  --parameters "$CMD" --query Command.CommandId --output text) || exit 1
echo "SSM command $CMD_ID"
for _ in $(seq 1 130); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed|None|"") sleep 10 ;; *) break ;; esac
done
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$HUB_ID" > "${RUNNER_TEMP:-/tmp}/ssm-$CMD_ID.json"
OUT=$(jq -r '.StandardOutputContent' "${RUNNER_TEMP:-/tmp}/ssm-$CMD_ID.json")
echo "$OUT"
jq -r '.StandardErrorContent' "${RUNNER_TEMP:-/tmp}/ssm-$CMD_ID.json" >&2
STATUS=$(jq -r '.Status' "${RUNNER_TEMP:-/tmp}/ssm-$CMD_ID.json")
RESULT=$(sed -n 's/^RESULT: //p' <<<"$OUT" | tail -1)
[ -n "${GITHUB_OUTPUT:-}" ] && echo "result=${RESULT}" >> "$GITHUB_OUTPUT"
if [ "$STATUS" != "Success" ]; then
  echo "::error title=result::${RESULT:-$(basename "$SCRIPT") failed on the hub ($STATUS)}"
  exit 1
fi
echo "::notice title=result::${RESULT:-done}"
