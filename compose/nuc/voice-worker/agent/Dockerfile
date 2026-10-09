# Disposable coding-agent image for voice tasks (Milestone 18, ADR-0021).
# Runs headless Claude Code against /work. Holds no credentials: the
# Claude OAuth token arrives per-run via --env-file, and there is never a
# GitHub token in here at all. At runtime it has no network except the
# allowlisting proxy (Anthropic, PyPI, npm registry) -- see ../squid.conf.
#
# Toolchains: Python (todo-app, hue's hub backend) and Node 24 (hue's React
# frontend; same major as hue/hub/Dockerfile's node:24-slim build stage).
# hue's C++ agent still can't be built here: vcpkg pulls sources from
# GitHub, which the proxy deliberately blocks, so PR CI is its only check.
# Keep the major in step with hue's frontend (hue/hub/Dockerfile, node:24-slim);
# Dependabot doesn't propose majors here for that reason (.github/dependabot.yml).
# node:26 never actually built here: #33's bump only reached nuc4 on 2026-10-03
# after the same-size S3 sync fix, and its build failed.
# Base images from public.ecr.aws/docker/library, AWS's mirror of Docker's official images: no Docker Hub
# rate limits or outages (Bill, 2026-10-09; nyc_pa_aws_gitops docs/gotchas.md).
FROM public.ecr.aws/docker/library/node:24-bookworm-slim AS node

FROM public.ecr.aws/docker/library/python:3.12-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates libstdc++6 \
 && rm -rf /var/lib/apt/lists/*

# Node from the official image rather than a third-party apt repo: same
# binary hue's CI uses, no extra signing key to trust.
COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=node /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/npm/bin/npm-cli.js /usr/local/bin/npm \
 && ln -s ../lib/node_modules/npm/bin/npx-cli.js /usr/local/bin/npx \
 && node --version && npm --version

RUN useradd --uid 10001 --create-home --shell /bin/bash agent
USER agent
WORKDIR /home/agent
ENV PATH=/home/agent/.local/bin:$PATH \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_USER=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false \
    NPM_CONFIG_AUDIT=false

# Claude Code's native installer (standalone binary, no Node needed).
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

RUN git config --global user.name "voice-agent" \
 && git config --global user.email "voice-agent@invalid" \
 && git config --global --add safe.directory /work
