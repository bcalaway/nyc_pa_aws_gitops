#!/usr/bin/env bash
# Voice job (ADR-0022): run the nightly backup now, inside the running
# postgres-backup container (same script, credentials and S3 target as the
# 03:00 cron run). Usage: postgres-backup-now.sh <bucket>
set -euo pipefail
out=$(docker exec postgres-backup /usr/local/bin/backup.sh 2>&1) || {
  echo "$out"
  echo "RESULT: the Postgres backup failed; check the run log."
  exit 1
}
echo "$out"
file=$(sed -n 's/.*backup complete: //p' <<<"$out" | tail -1)
echo "RESULT: Postgres backed up to S3${file:+ as $file}."
