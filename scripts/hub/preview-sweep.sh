#!/usr/bin/env bash
# Runs ON the hub (root, via SSM): nightly from preview-sweep.yml, or on
# demand as the preview-cleanup voice job. Removes previews whose PR is
# closed, that are older than MAX_DAYS, or that have no metadata (orphans
# from a failed deploy). PR state comes from GitHub's anonymous API; the
# repos are public (ADR-0023). Usage: preview-sweep.sh [<bucket>]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MAX_DAYS=7
OWNER=bcalaway
now=$(date +%s)
removed=() kept=()

declare -A seen
for meta in /home/ec2-user/previews/*/meta; do
  [ -f "$meta" ] || continue
  # shellcheck disable=SC1090
  repo=$(sed -n 's/^repo=//p' "$meta"); pr=$(sed -n 's/^pr=//p' "$meta")
  app=$(sed -n 's/^app=//p' "$meta"); created=$(sed -n 's/^created=//p' "$meta")
  proj="${app}-pr${pr}"; seen[$proj]=1
  state=$(curl -fsS --max-time 10 "https://api.github.com/repos/${OWNER}/${repo}/pulls/${pr}" \
            | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])' 2>/dev/null || echo unknown)
  age_days=$(( (now - ${created:-$now}) / 86400 ))
  if [ "$state" = "closed" ] || [ "$age_days" -ge "$MAX_DAYS" ]; then
    bash "$HERE/preview-down.sh" "$app" "$pr" >/dev/null && removed+=("$proj ($([ "$state" = closed ] && echo "PR closed" || echo "${age_days} days old"))")
  else
    kept+=("$proj")
  fi
done

# Orphans: preview projects running without metadata.
while read -r name; do
  [ -n "$name" ] && [ -z "${seen[$name]:-}" ] || continue
  app="${name%-pr*}"; pr="${name##*-pr}"
  bash "$HERE/preview-down.sh" "$app" "$pr" >/dev/null && removed+=("$name (orphan)")
done < <(docker compose ls -a --format json | python3 -c '
import json, re, sys
for p in json.load(sys.stdin):
    if re.fullmatch(r"[a-z0-9-]+-pr[0-9]+", p["Name"]): print(p["Name"])')

r=$(IFS=,; echo "${removed[*]:-}"); k=$(IFS=,; echo "${kept[*]:-}")
echo "RESULT: preview cleanup removed ${#removed[@]}${r:+ (${r//,/, })}; ${#kept[@]} still running${k:+ (${k//,/, })}."
