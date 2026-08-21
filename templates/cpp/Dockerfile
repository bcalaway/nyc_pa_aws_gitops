# Multi-stage build following the convention app-ci.yml (nyc_pa_aws_gitops)
# relies on: a `lint` stage and a `test` stage ahead of the final runtime
# stage, so the platform's CI workflow stays language-agnostic instead of
# hardcoding per-language tooling. `docker build` with no --target builds
# the last stage (`final`) -- exactly what app-build-push.yml pushes to ECR.
#
# vcpkg dependency install (`grpc` and its whole transitive tree -- protobuf,
# abseil, c-ares, re2, zlib, openssl -- built from source) is genuinely slow
# on a cold cache, tens of minutes. It's split into its own layer, keyed only
# on vcpkg.json's content via COPY ordering.
#
# Real binary caching: GitHub Packages via a NuGet feed, vcpkg's own
# currently-documented/recommended approach for GitHub Actions --
# https://learn.microsoft.com/vcpkg/consume/binary-caching-github-packages
# (same fix applied to hue/agent/Dockerfile 2026-08-21, confirmed live there:
# a cold-cache build with this feed populated dropped from 1h20m to 16s.
# vcpkg's older x-gha binary-caching backend has been removed from current
# vcpkg entirely -- silently warns and no-ops instead of erroring, so don't
# reach for that). The built-in GITHUB_TOKEN doesn't have package-registry
# permissions for this per that same doc, so it needs a real classic PAT
# (write:packages -- a fine-grained PAT does NOT work, confirmed live via
# 403s from the GitHub Packages service) passed in as a build secret, never
# baked into the image or any layer -- see app-build-push.yml's `vcpkg_pat`
# secret and this template's cd.yml. Falls back to a plain local
# BuildKit cache mount when the PAT secret isn't present (e.g. building this
# image locally, or a pull_request-triggered CI run without secrets access),
# which degrades to the old slow behavior rather than failing the build.

FROM ubuntu:24.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang clang-tidy cmake ninja-build git curl zip unzip tar pkg-config ca-certificates python3 \
      bison flex mono-complete \
    # bison/flex: not needed by this template's own code, but vcpkg's libpq
    # port (pulled in by libpqxx) builds Postgres's parser/lexer from source
    # and fails without them -- confirmed live, see CLAUDE.md's Gotchas.
    # mono-complete: runs vcpkg's `nuget.exe` (a .NET Framework binary) to
    # authenticate against the GitHub Packages NuGet feed below.
    && rm -rf /var/lib/apt/lists/*
ENV CC=clang CXX=clang++

RUN git clone --depth 1 https://github.com/microsoft/vcpkg.git /opt/vcpkg \
    && /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics
ENV VCPKG_ROOT=/opt/vcpkg

WORKDIR /app
COPY vcpkg.json ./
RUN --mount=type=secret,id=vcpkg_pat \
    --mount=type=cache,target=/vcpkg-cache \
    sh -c '\
      if [ -s /run/secrets/vcpkg_pat ]; then \
        PAT="$(cat /run/secrets/vcpkg_pat)"; \
        FEED_URL="https://nuget.pkg.github.com/bcalaway/index.json"; \
        NUGET_EXE="$(/opt/vcpkg/vcpkg fetch nuget | tail -n 1)"; \
        mono "$NUGET_EXE" sources add -Source "$FEED_URL" -StorePasswordInClearText -Name GitHubPackages -UserName bcalaway -Password "$PAT"; \
        mono "$NUGET_EXE" setapikey "$PAT" -Source "$FEED_URL"; \
        export VCPKG_BINARY_SOURCES="clear;nuget,$FEED_URL,readwrite"; \
      else \
        export VCPKG_DEFAULT_BINARY_CACHE=/vcpkg-cache; \
      fi; \
      /opt/vcpkg/vcpkg install --triplet x64-linux --x-install-root=/app/vcpkg_installed'

COPY CMakeLists.txt ./
COPY proto/ proto/
COPY src/ src/
COPY tests/ tests/

RUN cmake -S . -B build -G Ninja \
      -DCMAKE_TOOLCHAIN_FILE=${VCPKG_ROOT}/scripts/buildsystems/vcpkg.cmake \
      -DVCPKG_MANIFEST_INSTALL=OFF \
      -DVCPKG_INSTALLED_DIR=/app/vcpkg_installed \
      -DVCPKG_TARGET_TRIPLET=x64-linux \
      -DCMAKE_BUILD_TYPE=Release

FROM base AS lint
# Builds app_lib first (not just configure) so the generated proto headers
# clang-tidy needs to resolve #includes actually exist on disk.
RUN cmake --build build --target app_lib -j
RUN clang-tidy -p build $(find src -name '*.cpp')

FROM base AS test
RUN cmake --build build --target app_tests -j
RUN ctest --test-dir build --output-on-failure

FROM base AS build-final
RUN cmake --build build --target app -j

FROM ubuntu:24.04 AS final
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build-final /app/build/app /usr/local/bin/app
EXPOSE 8000 9090
CMD ["/usr/local/bin/app"]
