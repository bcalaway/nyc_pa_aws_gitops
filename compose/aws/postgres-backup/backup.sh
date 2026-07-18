#!/bin/bash
set -euo pipefail
source /etc/backup-env.sh

TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
FILE="/tmp/postgres-${TIMESTAMP}.sql.gz"

PGPASSWORD="$POSTGRES_PASSWORD" pg_dumpall -h postgres -U postgres | gzip > "$FILE"
aws s3 cp "$FILE" "s3://${BACKUP_BUCKET}/postgres-backups/postgres-${TIMESTAMP}.sql.gz" --region us-east-1
rm -f "$FILE"

echo "$(date -u -Iseconds) backup complete: postgres-${TIMESTAMP}.sql.gz"
