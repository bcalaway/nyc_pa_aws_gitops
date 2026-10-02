#!/usr/bin/env bash
# Pending OS updates -> node-exporter textfile metrics (Milestone 19, ADR-0024).
#
# Runs on the host (not in a container) from a systemd timer every 6 hours,
# as root, on every dnf-based box: the EC2 hub (Amazon Linux 2023) and the
# NUCs (Rocky Linux 10). Two copies, kept identical:
#   compose/aws/host/update-metrics.sh  -- hub, installed by compose/aws/host/install.sh
#   compose/nuc/host/update-metrics.sh  -- NUCs, installed by ansible/roles/exporters
#
# dnf-automatic already APPLIES security updates daily on all three boxes
# (docs/platform-reference.md, ansible/roles/security). This script only
# reports what's still pending -- non-security updates, anything
# dnf-automatic failed on, a kernel that needs a reboot to take effect, and
# (AL2023 only) a newer Amazon Linux release, which `dnf upgrade` never
# picks up on its own because AL2023 locks its repos to one release.
#
# Usage: update-metrics.sh <textfile-directory>
# Writes <dir>/host_updates.prom atomically (tmp + mv in the same dir).

set -uo pipefail

DIR="${1:?usage: update-metrics.sh <textfile-directory>}"
OUT="$DIR/host_updates.prom"
TMP="$(mktemp "$DIR/.host_updates.prom.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

ok=1

# All pending updates. `check-update` exits 100 when there are updates, 0
# when there are none, 1 on error. Package lines have 3 columns; skip the
# "Obsoleting Packages" section and blank/metadata lines.
all_out="$(dnf -q --refresh check-update 2>/dev/null)"
rc=$?
if [ "$rc" -eq 0 ] || [ "$rc" -eq 100 ]; then
  all_count="$(printf '%s\n' "$all_out" | awk 'NF==3 && $1 ~ /\./ {n++} /^Obsoleting/ {exit} END {print n+0}')"
else
  all_count=0
  ok=0
fi

# Security advisories by severity. dnf4 prints "<advisory> <Severity>/Sec. <pkg>",
# dnf5 prints "<advisory> security <Severity> <pkg> ..."; count package
# lines per severity either way.
sec_out="$(dnf -q updateinfo list --security 2>/dev/null)" || ok=0
count_sev() { printf '%s\n' "$sec_out" | grep -Eic "(^|[[:space:]])$1([/[:space:]]|$)" || true; }
sec_total="$(printf '%s\n' "$sec_out" | grep -Eic '(sec\.|security)' || true)"
critical="$(count_sev Critical)"
important="$(count_sev Important)"
moderate="$(count_sev Moderate)"
low="$(count_sev Low)"

# Reboot needed for an updated kernel/glibc/systemd to take effect.
# needs-restarting comes from dnf-plugins-core; exit 1 = reboot required.
reboot=0
if dnf needs-restarting --help >/dev/null 2>&1; then
  dnf -q needs-restarting -r >/dev/null 2>&1
  [ $? -eq 1 ] && reboot=1
else
  ok=0
fi

{
  echo "# HELP host_updates_pending OS package updates available but not installed."
  echo "# TYPE host_updates_pending gauge"
  echo "host_updates_pending{type=\"all\"} ${all_count}"
  echo "host_updates_pending{type=\"security\"} ${sec_total}"
  echo "host_updates_pending{type=\"critical\"} ${critical}"
  echo "host_updates_pending{type=\"important\"} ${important}"
  echo "host_updates_pending{type=\"moderate\"} ${moderate}"
  echo "host_updates_pending{type=\"low\"} ${low}"
  echo "# HELP host_reboot_required 1 if installed updates need a reboot to take effect."
  echo "# TYPE host_reboot_required gauge"
  echo "host_reboot_required ${reboot}"
} > "$TMP"

# Amazon Linux 2023 only: a newer release (repo version) is available.
if [ -r /etc/amazon-linux-release ] || grep -q 'ID="amzn"' /etc/os-release 2>/dev/null; then
  current="$(rpm -q --qf '%{VERSION}' system-release 2>/dev/null || echo unknown)"
  rel_out="$(dnf check-release-update 2>&1)"
  latest="$(printf '%s\n' "$rel_out" | grep -Eo 'Version 20[0-9]{2}\.[0-9]+\.[0-9]+' | awk '{print $2}' | sort -V | tail -1)"
  avail=0
  [ -n "$latest" ] && avail=1
  {
    echo "# HELP host_os_release_update_available 1 if a newer Amazon Linux 2023 release is available (not applied by dnf upgrade)."
    echo "# TYPE host_os_release_update_available gauge"
    echo "host_os_release_update_available{current=\"${current}\",latest=\"${latest:-$current}\"} ${avail}"
  } >> "$TMP"
fi

{
  echo "# HELP host_updates_check_ok 1 if the last update check ran cleanly."
  echo "# TYPE host_updates_check_ok gauge"
  echo "host_updates_check_ok ${ok}"
  echo "# HELP host_updates_last_check_timestamp_seconds When the update check last ran."
  echo "# TYPE host_updates_last_check_timestamp_seconds gauge"
  echo "host_updates_last_check_timestamp_seconds $(date +%s)"
} >> "$TMP"

chmod 644 "$TMP"
mv -f "$TMP" "$OUT"
trap - EXIT
