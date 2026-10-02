#!/usr/bin/env bash
# Runs ON A GITHUB RUNNER (not the hub): runs one of the hub's fixed SSM
# Command documents (terraform/aws/ci-roles.tf, Milestone 20 / ADR-0025),
# waits, prints its output, and fails if it did. The app workflows use this
# instead of run-on-hub.sh: their roles may run only these documents, and
# can pass only the parameters each one declares (validated again by SSM's
# allowedPattern and by the script on the hub).
#
# Usage: run-document.sh <document-name> [name=value ...]
# Writes the document's last `RESULT:` line to $GITHUB_OUTPUT as `result`.
set -uo pipefail
DOC="$1"; shift
[[ "$DOC" =~ ^[A-Za-z0-9_.-]+$ ]] || { echo "::error::bad document name: $DOC"; exit 1; }
PARAMS='{}'
for kv in "$@"; do
  [[ "$kv" =~ ^([a-z][A-Za-z0-9]*)=([A-Za-z0-9._-]+)$ ]] || { echo "::error::refusing unsafe parameter: $kv"; exit 1; }
  PARAMS=$(jq -c --arg k "${BASH_REMATCH[1]}" --arg v "${BASH_REMATCH[2]}" '. + {($k): [$v]}' <<<"$PARAMS")
done

HUB_ID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=home-platform-hub" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
if [ -z "$HUB_ID" ] || [ "$HUB_ID" = "None" ]; then
  echo "::error::Could not find a running home-platform-hub instance"; exit 1
fi

CMD_ID=$(aws ssm send-command --instance-ids "$HUB_ID" --document-name "$DOC" \
  --comment "${GITHUB_REPOSITORY:-} run ${GITHUB_RUN_ID:-}" \
  --parameters "$PARAMS" --query Command.CommandId --output text) || exit 1
echo "SSM command $CMD_ID ($DOC)"
for _ in $(seq 1 130); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed|None|"") sleep 10 ;; *) break ;; esac
done
OUTFILE="${RUNNER_TEMP:-/tmp}/ssm-$CMD_ID.json"
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$HUB_ID" > "$OUTFILE"
OUT=$(jq -r '.StandardOutputContent' "$OUTFILE")
echo "$OUT"
jq -r '.StandardErrorContent' "$OUTFILE" >&2
STATUS=$(jq -r '.Status' "$OUTFILE")
RESULT=$(sed -n 's/^RESULT: //p' <<<"$OUT" | tail -1)
[ -n "${GITHUB_OUTPUT:-}" ] && echo "result=${RESULT}" >> "$GITHUB_OUTPUT"
if [ "$STATUS" != "Success" ]; then
  echo "::error title=result::${RESULT:-$DOC failed on the hub ($STATUS)}"
  exit 1
fi
echo "::notice title=result::${RESULT:-done}"
