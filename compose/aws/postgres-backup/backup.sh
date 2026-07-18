#!/bin/bash
set -euo pipefail
source /etc/backup-env.sh

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
FILE="/tmp/postgres-${TIMESTAMP}.sql.gz"

PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -h postgres -U postgres | gzip > "$FILE"
aws s3 cp "$FILE" "s3://${BACKUP_BUCKET}/postgres-backups/postgres-${TIMESTAMP}.sql.gz" --region us-east-1
rm -f "$FILE"

# Feeds node-exporter's textfile collector (docker-compose.yml) -- Grafana
# alerts on staleness of this timestamp, not on this script's exit code
# directly, since cron failing to fire at all needs the same alert as the
# script itself failing. set -euo pipefail above means any failure before
# this point (pg_dumpall, the S3 upload) skips this write entirely, so an
# unwritten/stale timestamp is itself the failure signal -- no separate
# success/failure gauge needed.
cat > /textfile_collector/postgres_backup.prom.tmp <<EOF
# HELP postgres_backup_last_success_timestamp_seconds Unix timestamp of the last successful pg_dumpall backup
# TYPE postgres_backup_last_success_timestamp_seconds gauge
postgres_backup_last_success_timestamp_seconds $(date -u +%s)
EOF
mv /textfile_collector/postgres_backup.prom.tmp /textfile_collector/postgres_backup.prom

echo "$(date -u -Iseconds) backup complete: postgres-${TIMESTAMP}.sql.gz"
