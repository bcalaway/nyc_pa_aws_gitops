#!/usr/bin/env bash
# Runs ON THE HUB, from the <app>-capture-export SSM document
# (terraform/aws/ci-roles.tf), for apps with `capture_export: true` in
# apps/registry.yml. It copies one raw capture, byte for byte, from the app's
# job API (GET /jobs/captures/<id>, with the app's own AIRFLOW_TOKEN, read
# inside the container) to the deploy bucket under apps/<app>/exports/<id>/.
# The app's own workflow (e.g. mkt-data's capture-export.yml) then downloads
# it and commits it to a capture/<id> branch, so Claude can fetch it with git
# instead of Bill copying files off the hub.
#
# The app's role can start this document and nothing else new. The hub role
# may write only apps/<app>/exports/*, and those objects expire after 7 days.
#
# Usage: capture-export.sh <bucket> <app> <capture-id>
set -uo pipefail
BUCKET="$1" APP="$2" ID="$3"
if ! [[ "$APP" =~ ^[a-z0-9-]+$ && "$ID" =~ ^[0-9]{1,9}$ ]]; then
  echo "RESULT: refused: bad app name or capture id"; exit 1
fi
d=$(mktemp -d) && chmod 700 "$d"
trap 'rm -rf "$d"' EXIT

# Body to stdout, the capture's metadata (from the response headers) as one
# JSON line to stderr. The token never leaves the container.
docker exec "$APP" python -c '
import json, os, sys, urllib.error, urllib.request as u
req = u.Request("http://localhost:8000/jobs/captures/" + sys.argv[1],
                headers={"Authorization": "Bearer " + os.environ["AIRFLOW_TOKEN"]})
try:
    r = u.urlopen(req, timeout=60)
except urllib.error.HTTPError as e:
    sys.stderr.write(json.dumps({"error": f"HTTP {e.code}"}))
    sys.exit(2)
body = r.read()
sys.stderr.write(json.dumps({
    "id": int(sys.argv[1]), "source": r.headers.get("X-Capture-Source"),
    "sha256": r.headers.get("X-Capture-Sha256"), "content_type": r.headers.get("Content-Type"),
    "size_bytes": len(body),
}))
sys.stdout.buffer.write(body)
' "$ID" > "$d/body" 2> "$d/meta.json"
rc=$?
if [ $rc -ne 0 ]; then
  echo "RESULT: capture $ID not exported: $(head -c 300 "$d/meta.json")"; exit 1
fi
want=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sha256"])' "$d/meta.json")
got=$(sha256sum "$d/body" | cut -d' ' -f1)
if [ "$want" != "$got" ]; then
  echo "RESULT: capture $ID not exported: sha256 mismatch (app says $want, got $got)"; exit 1
fi
aws s3 cp "$d/body" "s3://${BUCKET}/apps/${APP}/exports/${ID}/body" --only-show-errors \
  && aws s3 cp "$d/meta.json" "s3://${BUCKET}/apps/${APP}/exports/${ID}/meta.json" --only-show-errors \
  || { echo "RESULT: capture $ID not exported: S3 upload failed"; exit 1; }
src=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$d/meta.json")
echo "RESULT: capture $ID ($src, $(stat -c %s "$d/body") bytes, sha256 ${got:0:12}) exported to apps/${APP}/exports/${ID}/"
