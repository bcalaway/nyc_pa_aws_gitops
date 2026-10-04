#!/usr/bin/env bash
# Runs ON the EC2 hub (as root, via SSM Run Command from
# .github/workflows/platform-release.yml, behind `production` approval).
#
# App database onboarding (ADR-0028): for every app in apps/registry.yml
# with `database: true`, and every entry under `platform_databases:` (shared
# services such as Airflow, ADR-0027), make sure it has
#   - a password in SSM at /home-platform/postgres/<app>-password
#     (generated here only if the parameter genuinely doesn't exist)
#   - a LOGIN role named <app>
#   - a database named <app>, owned by that role
#   - ownership of the database's public schema (Postgres 15+ needs this
#     for a non-owner to CREATE TABLE; docs/gotchas.md)
# and then proves it by logging in as the app with the SSM password and
# running a real CREATE TABLE / DROP TABLE.
#
# Idempotent and additive: it never drops a database or role, never
# overwrites an existing SSM password, and never changes an existing role's
# password -- if the SSM password doesn't log in, it stops and says so.
# Removing an app stays a manual step (ADR-0028).
#
# The registry arrives as JSON (converted on the runner) at
# s3://<bucket>/apps-registry/registry.json.
#
# Usage: onboard-app-dbs.sh <deploy-bucket>

set -euo pipefail

BUCKET="$1"
REGION="us-east-1"
WORK=$(mktemp -d)
chmod 700 "$WORK"
trap 'rm -rf "$WORK"' EXIT

aws s3 cp "s3://${BUCKET}/apps-registry/registry.json" "$WORK/registry.json" --only-show-errors

# Names of apps with database: true, then platform databases. The same name
# check as Terraform's precondition (apps.tf), so nothing odd ever reaches a
# SQL identifier.
# Written to a file first: a failure inside <(...) wouldn't stop the script.
if ! python3 - "$WORK/registry.json" >"$WORK/apps.txt" <<'PY'
import json, re, sys
reg = json.load(open(sys.argv[1]))
names = [a["name"] for a in reg["apps"] if a.get("database", False) is True]
names += [d["name"] for d in reg.get("platform_databases") or []]
for name in names:
    if not re.fullmatch(r"[a-z][a-z0-9-]{1,30}[a-z0-9]", name):
        sys.exit(f"bad name in registry: {name!r}")
if len(set(names)) != len(names):
    sys.exit("a database name appears twice in the registry")
for name in names:
    print(name)
PY
then
  echo "RESULT: app databases not onboarded: apps/registry.yml failed the name check."
  exit 1
fi
mapfile -t APPS <"$WORK/apps.txt"

if [ "${#APPS[@]}" -eq 0 ]; then
  echo "RESULT: app databases: no registry app has database: true and there are no platform databases."
  exit 0
fi

docker exec postgres pg_isready -U postgres -q \
  || { echo "RESULT: app databases not onboarded: the postgres container isn't ready."; exit 1; }

# Admin access is the container's local socket as the postgres superuser,
# same as preview-up.sh -- no admin password leaves SSM.
psql_admin() { docker exec -i postgres psql -U postgres -v ON_ERROR_STOP=1 -qtAX "$@"; }

# Read the app's password, creating it only when SSM says it doesn't exist.
# Prints "<created|existing> <password>". A read error other than
# ParameterNotFound fails the run rather than minting a second password.
app_password() {
  local p="/home-platform/postgres/$1-password" v err
  if v=$(aws ssm get-parameter --name "$p" --with-decryption --region "$REGION" \
           --query Parameter.Value --output text 2>"$WORK/ssm.err") && [ -n "$v" ]; then
    echo "existing $v"
    return
  fi
  err=$(cat "$WORK/ssm.err")
  if ! grep -q ParameterNotFound <<<"$err"; then
    echo "ERROR: couldn't read $p: $err" >&2
    return 1
  fi
  v=$(openssl rand -hex 24)
  # No --overwrite: if something created it in the meantime, this fails
  # instead of replacing it.
  aws ssm put-parameter --name "$p" --type SecureString --value "$v" \
    --description "Postgres password for the $1 app role (scripts/hub/onboard-app-dbs.sh)" \
    --region "$REGION" >/dev/null
  echo "created $v"
}

ok=() changed=() failed=()
for app in "${APPS[@]}"; do
  echo "== $app"
  read -r pw_state pw < <(app_password "$app") || { failed+=("$app (SSM read)"); continue; }
  notes=()
  [ "$pw_state" = created ] && notes+=("password created in SSM")

  role_exists=$(psql_admin -c "SELECT 1 FROM pg_roles WHERE rolname = '${app}'")
  if [ "$role_exists" != 1 ]; then
    # Password goes through psql's stdin as a variable, never on a command
    # line; :'pw' quotes it as a literal.
    psql_admin <<SQL
\set pw '${pw}'
CREATE ROLE "${app}" LOGIN PASSWORD :'pw' NOSUPERUSER NOCREATEDB NOCREATEROLE;
SQL
    notes+=("role created")
  elif [ "$pw_state" = created ]; then
    # The role existed but SSM had no password, so no deploy of this app
    # could have been using one: SSM is now the source of truth.
    psql_admin <<SQL
\set pw '${pw}'
ALTER ROLE "${app}" PASSWORD :'pw';
SQL
    notes+=("role password set from SSM")
  fi

  db_owner=$(psql_admin -c "SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname = '${app}'")
  if [ -z "$db_owner" ]; then
    # CREATE DATABASE can't run inside a transaction or DO block, hence the
    # check above rather than IF NOT EXISTS logic in SQL.
    psql_admin -c "CREATE DATABASE \"${app}\" OWNER \"${app}\""
    notes+=("database created")
  elif [ "$db_owner" != "$app" ]; then
    psql_admin -c "ALTER DATABASE \"${app}\" OWNER TO \"${app}\""
    notes+=("database owner ${db_owner} -> ${app}")
  fi

  schema_owner=$(psql_admin -d "$app" -c "SELECT pg_get_userbyid(nspowner) FROM pg_namespace WHERE nspname = 'public'")
  if [ "$schema_owner" != "$app" ]; then
    psql_admin -d "$app" -c "ALTER SCHEMA public OWNER TO \"${app}\""
    notes+=("public schema owner ${schema_owner} -> ${app}")
  fi

  # The real test, as the app itself over TCP with the SSM password (same
  # auth path the app uses). PGPASSWORD is passed by name only, so its value
  # never appears in a command line.
  check="_platform_onboarding_check_$(openssl rand -hex 4)"
  if ! PGPASSWORD="$pw" docker exec -i -e PGPASSWORD postgres \
         psql -h localhost -U "$app" -d "$app" -v ON_ERROR_STOP=1 -qtAX \
         -c "CREATE TABLE public.${check} (id int)" -c "DROP TABLE public.${check}" 2>"$WORK/verify.err"; then
    echo "verify failed: $(cat "$WORK/verify.err")" >&2
    if grep -q "password authentication failed" "$WORK/verify.err"; then
      failed+=("$app (SSM password doesn't log in, left as is)")
    else
      failed+=("$app (create/drop table failed)")
    fi
    continue
  fi

  if [ "${#notes[@]}" -gt 0 ]; then
    changed+=("$app: $(IFS=,; echo "${notes[*]}" | sed 's/,/, /g')")
  else
    ok+=("$app")
  fi
  echo "   ok${notes:+ (${notes[*]})}"
done

# Names join with ", "; changed/failed entries (which contain commas) with " | ".
join() { local sep="$1"; shift; if [ $# -eq 0 ]; then echo none; else printf '%s\n' "$@" | paste -sd'\t' - | sed "s/\t/${sep}/g"; fi; }
summary="app databases: ${#APPS[@]} checked; unchanged: $(join ', ' "${ok[@]}"); changed: $(join ' | ' "${changed[@]}")"
if [ "${#failed[@]}" -gt 0 ]; then
  echo "RESULT: ${summary}; FAILED: $(join ' | ' "${failed[@]}")."
  exit 1
fi
echo "RESULT: ${summary}."
