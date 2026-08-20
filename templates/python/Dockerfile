# Multi-stage build following the convention app-ci.yml (nyc_pa_aws_gitops)
# relies on: a `lint` stage and a `test` stage ahead of the final runtime
# stage, so the platform's CI workflow stays language-agnostic instead of
# hardcoding Python tooling. `docker build` with no --target builds the
# last stage (`final`) -- exactly what app-build-push.yml pushes to ECR.

FROM python:3.12-slim AS base
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app/ app/

FROM base AS dev
COPY requirements-dev.txt .
RUN pip install --no-cache-dir -r requirements-dev.txt
COPY tests/ tests/
COPY ruff.toml .

FROM dev AS lint
RUN ruff check app/ tests/

FROM dev AS test
RUN pytest

FROM base AS final
EXPOSE 8000
# --proxy-headers/--forwarded-allow-ips: Traefik terminates TLS and proxies
# to the app over plain HTTP on the internal Docker network. Without this,
# uvicorn ignores Traefik's X-Forwarded-Proto and builds http:// redirect
# URIs (e.g. for OIDC), which Authentik's strict-match redirect_uris reject.
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers", "--forwarded-allow-ips=*"]
