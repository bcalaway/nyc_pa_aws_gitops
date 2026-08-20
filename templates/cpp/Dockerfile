# Multi-stage build following the convention app-ci.yml (nyc_pa_aws_gitops)
# relies on: a `lint` stage and a `test` stage ahead of the final runtime
# stage, so the platform's CI workflow stays language-agnostic instead of
# hardcoding per-language tooling. `docker build` with no --target builds
# the last stage (`final`) -- exactly what app-build-push.yml pushes to ECR.
#
# vcpkg dependency install (`grpc` and its whole transitive tree -- protobuf,
# abseil, c-ares, re2, zlib, openssl -- built from source) is genuinely slow
# on a cold cache, tens of minutes. It's split into its own layer, keyed only
# on vcpkg.json's content via COPY ordering, and additionally uses a BuildKit
# cache mount for vcpkg's own binary cache so repeated builds (local
# iteration, or CI across runs with cache persistence) don't pay that cost
# again just because application source changed.

FROM ubuntu:24.04 AS base
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      build-essential clang clang-tidy cmake ninja-build git curl zip unzip tar pkg-config ca-certificates python3 \
      bison flex \
    && rm -rf /var/lib/apt/lists/*
ENV CC=clang CXX=clang++

RUN git clone --depth 1 https://github.com/microsoft/vcpkg.git /opt/vcpkg \
    && /opt/vcpkg/bootstrap-vcpkg.sh -disableMetrics
ENV VCPKG_ROOT=/opt/vcpkg

WORKDIR /app
COPY vcpkg.json ./
RUN --mount=type=cache,target=/vcpkg-cache \
    VCPKG_DEFAULT_BINARY_CACHE=/vcpkg-cache \
    /opt/vcpkg/vcpkg install --triplet x64-linux --x-install-root=/app/vcpkg_installed

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
