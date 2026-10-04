#!/usr/bin/env bash
# terraform-apply.sh <dir> <label>: init and apply terraform/<dir>, then
# write one `result` annotation (home-mcp's last_deploys reads it back; the
# full log isn't reachable from Claude's sessions) and a summary line.
# Used by platform-release.yml. Fails when the apply fails.
set -uo pipefail
DIR="terraform/$1"; LABEL="$2"
cd "$DIR" || exit 1
terraform init -no-color -input=false > init.txt 2>&1 || { cat init.txt; echo "::error title=result::$LABEL: terraform init failed"; exit 1; }
terraform apply -auto-approve -no-color -input=false 2>&1 | tee apply.txt
STATUS=${PIPESTATUS[0]}
# IAM is eventually consistent: an apply that grants the CI role a new app's
# ARNs and then creates that app's resources can be refused even after
# ci-roles.tf's time_sleep (ecr:CreateRepository for calendar-svc, #126;
# ssm:DescribeDocument for secmaster-svc, #132). By then the grant itself is
# applied, so wait and apply once more; whatever already succeeded is a no-op.
if [ "$STATUS" -ne 0 ] && grep -qE 'AccessDenied|is not authorized to perform' apply.txt; then
  echo "::warning::$LABEL: access denied, likely IAM propagation; retrying in 90s"
  sleep 90
  terraform apply -auto-approve -no-color -input=false 2>&1 | tee apply.txt
  STATUS=${PIPESTATUS[0]}
fi
line=$(grep -hE '^(Apply complete!|No changes\.)' apply.txt 2>/dev/null | tail -1)
err=$(grep -hE '^Error: ' apply.txt 2>/dev/null | head -1)
if [ "$STATUS" -ne 0 ] || [ -n "$err" ]; then
  echo "::error title=result::$LABEL: apply failed: ${err#Error: }"
  echo "- $LABEL: **failed**${err:+ (${err#Error: })}" >> "$GITHUB_STEP_SUMMARY"
  exit 1
fi
echo "::notice title=result::$LABEL: ${line:-apply produced no summary}"
echo "- $LABEL: ${line:-apply produced no summary}" >> "$GITHUB_STEP_SUMMARY"
