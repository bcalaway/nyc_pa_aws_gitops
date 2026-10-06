#!/usr/bin/env bash
# run-on-hub.sh <label> <script-name>: run scripts/hub/<script-name>
# on the hub via SSM, wait for it, print its output, fail on error.
# Used by platform-release.yml. Needs HUB_ID, DEPLOY_BUCKET, RUNNER_TEMP and
# GITHUB_STEP_SUMMARY in the environment, and the scripts staged in S3.
set -euo pipefail
LABEL="$1"; SCRIPT="$2"
CMD=$(jq -n --arg b "$DEPLOY_BUCKET" --arg s "$SCRIPT" '{
  commands: [
    "set -e",
    ("aws s3 cp s3://" + $b + "/scripts-hub/" + $s + " /tmp/" + $s + " --only-show-errors"),
    ("bash /tmp/" + $s + " " + $b)
  ],
  executionTimeout: ["2400"]
}')
CMD_ID=$(aws ssm send-command \
  --instance-ids "$HUB_ID" \
  --document-name "AWS-RunShellScript" \
  --comment "$LABEL, GitHub run $GITHUB_RUN_ID" \
  --parameters "$CMD" \
  --query "Command.CommandId" --output text)
echo "Sent $LABEL as SSM command $CMD_ID"
# Up to 40 minutes: image pulls and builds on the hub can be slow.
for i in $(seq 1 240); do
  STATUS=$(aws ssm list-command-invocations --command-id "$CMD_ID" \
    --query "CommandInvocations[0].Status" --output text 2>/dev/null || echo Pending)
  case "$STATUS" in Pending|InProgress|Delayed|None|"") sleep 10 ;; *) break ;; esac
done
aws ssm get-command-invocation --command-id "$CMD_ID" --instance-id "$HUB_ID" > "$RUNNER_TEMP/$SCRIPT.json"
echo "--- stdout ---"; jq -r '.StandardOutputContent' "$RUNNER_TEMP/$SCRIPT.json"
echo "--- stderr ---"; jq -r '.StandardErrorContent' "$RUNNER_TEMP/$SCRIPT.json"
# SSM truncates inline output at 24,000 characters; the full log
# is in the hub's /var/lib/amazon/ssm/.../stdout for this command id.
STATUS=$(jq -r '.Status' "$RUNNER_TEMP/$SCRIPT.json")
echo "- $LABEL: **$STATUS**" >> "$GITHUB_STEP_SUMMARY"
# The script's last `RESULT:` line becomes this step's `result`
# annotation, which home-mcp's last_deploys reads back. (If SSM's
# 24,000-character cut drops it, the label-only fallback is used.)
RESULT=$(jq -r '.StandardOutputContent' "$RUNNER_TEMP/$SCRIPT.json" | sed -n 's/^RESULT: //p' | tail -1)
if [ "$STATUS" != "Success" ]; then
  echo "::error title=result::$LABEL failed ($STATUS)${RESULT:+: $RESULT}"
  # The cause, where Claude's sessions can read it: run logs aren't reachable
  # from them, annotations are. The last lines of stderr (or stdout when
  # stderr is empty), newlines encoded as an annotation expects.
  TAIL=$(jq -r '.StandardErrorContent' "$RUNNER_TEMP/$SCRIPT.json" | tail -15)
  [ -n "${TAIL//[[:space:]]/}" ] || TAIL=$(jq -r '.StandardOutputContent' "$RUNNER_TEMP/$SCRIPT.json" | tail -15)
  TAIL=${TAIL//'%'/'%25'}; TAIL=${TAIL//$'\r'/'%0D'}; TAIL=${TAIL//$'\n'/'%0A'}
  echo "::error title=output::$TAIL"
  exit 1
fi
echo "::notice title=result::${RESULT:-$LABEL succeeded}"
