#!/bin/sh
# Container entrypoint (Dockerfile `final` stage): apply database migrations,
# then start the app. Migrations run only when a database is configured, so
# the app still starts standalone before it's onboarded to Postgres.
#
# One replica per app on this platform, so running `upgrade head` at start is
# safe; a failed migration stops the container instead of serving a schema
# the code doesn't expect.
set -e
if [ -n "$POSTGRES_PASSWORD" ] || [ -n "$DATABASE_URL" ]; then
  echo "Applying database migrations..."
  alembic upgrade head
fi
# --proxy-headers/--forwarded-allow-ips: Traefik terminates TLS and proxies
# to the app over plain HTTP on the internal Docker network. Without this,
# uvicorn ignores Traefik's X-Forwarded-Proto and builds http:// redirect
# URIs (e.g. for OIDC), which Authentik's strict-match redirect_uris reject.
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --proxy-headers '--forwarded-allow-ips=*'
