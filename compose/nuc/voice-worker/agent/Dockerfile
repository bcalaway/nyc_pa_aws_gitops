# Disposable coding-agent image for voice tasks (Milestone 18, ADR-0021).
# Runs headless Claude Code against /work. Holds no credentials: the
# Claude OAuth token arrives per-run via --env-file, and there is never a
# GitHub token in here at all. At runtime it has no network except the
# allowlisting proxy (Anthropic + PyPI) -- see ../squid.conf.
#
# Python toolchain first because todo-app (the first allowed repo) is
# Python; add Node/C++ toolchains here as more repos are allowed.
FROM python:3.12-slim-bookworm

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*

RUN useradd --uid 10001 --create-home --shell /bin/bash agent
USER agent
WORKDIR /home/agent
ENV PATH=/home/agent/.local/bin:$PATH \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_USER=1

# Claude Code's native installer (standalone binary, no Node needed).
RUN curl -fsSL https://claude.ai/install.sh | bash \
 && claude --version

RUN git config --global user.name "voice-agent" \
 && git config --global user.email "voice-agent@invalid" \
 && git config --global --add safe.directory /work
