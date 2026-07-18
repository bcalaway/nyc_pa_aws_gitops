#!/bin/bash
set -euo pipefail

# cron-spawned processes don't inherit the container's environment, so
# `docker run -e` / compose `environment:` vars (POSTGRES_PASSWORD,
# BACKUP_BUCKET) aren't otherwise visible to backup.sh when cron runs it.
# Dump the environment once at startup so backup.sh can source it.
printenv | sed "s/^\(.*\)=\(.*\)$/export \1='\2'/" > /etc/backup-env.sh
chmod 600 /etc/backup-env.sh

exec cron -f
