#!/usr/bin/env bash
# Voice job (ADR-0022/0023): run the nightly preview sweep now. Removes
# previews whose PR is closed, older than 7 days, or orphaned.
# Usage: preview-cleanup.sh <bucket>
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
bash "$HERE/../hub/preview-sweep.sh" "$1"
