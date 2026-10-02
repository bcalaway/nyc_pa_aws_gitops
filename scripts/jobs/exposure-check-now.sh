#!/usr/bin/env bash
# Voice job (ADR-0022): run the weekly exposure check now (ADR-0024).
# Runs the same systemd unit the weekly timer runs, and waits for it.
# Its output stays on the hub -- the RESULT line deliberately says nothing
# about what was found, because this job's log is public in GitHub Actions.
set -uo pipefail
if ! systemctl cat exposure-check.service >/dev/null 2>&1; then
  echo "RESULT: The exposure check isn't installed on the hub yet; it arrives with the next hub deploy."
  exit 1
fi
if systemctl start exposure-check.service; then
  echo "RESULT: Exposure check finished; ask for the exposure check to hear the results."
else
  echo "RESULT: The exposure check failed on the hub; its journal (unit exposure-check) has the reason."
  exit 1
fi
