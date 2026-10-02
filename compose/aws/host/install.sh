#!/usr/bin/env bash
# Hub host units for Milestone 19 (ADR-0024): pending-update metrics every
# 6 hours and the weekly external exposure check. Runs ON the hub as root,
# called by scripts/hub/deploy-hub-stack.sh on every hub deploy, from its
# S3 staging copy of compose/aws. Idempotent.
#
# The scripts are installed into a root-owned directory before systemd runs
# them as root, so nothing root executes is writable by a non-root user
# (the deployed compose dir itself is owned by ec2-user).
#
# Usage: install.sh <compose-aws-dir>

set -euo pipefail

SRC="${1:?usage: install.sh <compose-aws-dir>}/host"
LIB=/usr/local/lib/home-platform

# nmap for the exposure check; dnf-plugins-core for `dnf needs-restarting`.
for pkg in nmap dnf-plugins-core; do
  rpm -q "$pkg" >/dev/null 2>&1 || dnf install -y -q "$pkg"
done

install -d -o root -g root -m 0755 "$LIB" /var/lib/home-platform/exposure
install -o root -g root -m 0755 "$SRC/update-metrics.sh" "$LIB/update-metrics.sh"
install -o root -g root -m 0755 "$SRC/exposure-check.py" "$LIB/exposure-check.py"
install -o root -g root -m 0644 "$SRC/exposure-expected.json" "$LIB/exposure-expected.json"

# The hub's node-exporter reads textfile metrics from the compose stack's
# backup-metrics volume (postgres-backup already writes there). Resolve its
# host path at run time so a renamed compose project can't break this.
cat > "$LIB/with-textfile-dir.sh" <<'EOF'
#!/usr/bin/env bash
# Runs "$@" with every @TEXTFILE_DIR@ argument replaced by the host path of
# the hub stack's backup-metrics volume (node-exporter's textfile dir).
set -euo pipefail
vol=$(docker volume ls -q --filter label=com.docker.compose.volume=backup-metrics | head -1)
[ -n "$vol" ] || { echo "backup-metrics volume not found" >&2; exit 1; }
dir=$(docker volume inspect -f '{{ .Mountpoint }}' "$vol")
args=()
for a in "$@"; do args+=("${a//@TEXTFILE_DIR@/$dir}"); done
exec "${args[@]}"
EOF
chmod 0755 "$LIB/with-textfile-dir.sh"

cat > /etc/systemd/system/host-update-metrics.service <<EOF
[Unit]
Description=Pending OS update metrics for node-exporter (ADR-0024)
After=network-online.target docker.service

[Service]
Type=oneshot
ExecStart=$LIB/with-textfile-dir.sh $LIB/update-metrics.sh @TEXTFILE_DIR@
Nice=10
EOF

cat > /etc/systemd/system/host-update-metrics.timer <<'EOF'
[Unit]
Description=Check for pending OS updates every 6 hours

[Timer]
OnBootSec=10min
OnUnitActiveSec=6h
RandomizedDelaySec=15min
Persistent=true

[Install]
WantedBy=timers.target
EOF

cat > /etc/systemd/system/exposure-check.service <<EOF
[Unit]
Description=External exposure check of the hub and both sites (ADR-0024)
After=network-online.target docker.service wg-quick@wg0.service

[Service]
Type=oneshot
ExecStart=$LIB/with-textfile-dir.sh $LIB/exposure-check.py --textfile-dir @TEXTFILE_DIR@
TimeoutStartSec=90min
Nice=10
EOF

# Early Sunday morning Eastern, a few hours before the weekly security
# review reads the results.
cat > /etc/systemd/system/exposure-check.timer <<'EOF'
[Unit]
Description=Weekly external exposure check

[Timer]
OnCalendar=Sun *-*-* 06:00:00 UTC
RandomizedDelaySec=30min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now host-update-metrics.timer exposure-check.timer
# Populate update metrics right away instead of waiting for the first tick.
systemctl start --no-block host-update-metrics.service
echo "Host units installed: host-update-metrics.timer, exposure-check.timer"
