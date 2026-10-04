#!/usr/bin/env bash
# Voice job (ADR-0022): the NUC deploy, same script as Platform release.
# ansible/ and compose/nuc/ were staged from main by voice-job.yml.
# Usage: deploy-nucs.sh <bucket>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOG=$(mktemp)
bash "$HERE/../hub/deploy-nucs-on-hub.sh" "$1" 2>&1 | tee "$LOG"
rc=${PIPESTATUS[0]}
ran=$(sed -n 's/^Running site.yml on: //p' "$LOG" | tail -1)
skipped=$(sed -n 's/^Skipping unreachable NUCs: //p' "$LOG" | tail -1)
rm -f "$LOG"
if [ "$rc" -ne 0 ]; then
  echo "RESULT: NUC deploy failed${ran:+ on $ran}; check the run log."
  exit "$rc"
fi
echo "RESULT: NUCs deployed: ${ran//,/, }.${skipped:+ Skipped ${skipped//,/, }, unreachable.}"
