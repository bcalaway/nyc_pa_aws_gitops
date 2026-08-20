# C++ App Starter Template

Starter template for a C++ app on the home platform. Pre-wired with CI/CD, a Dockerfile, and the Postgres/Authentik/Traefik/gRPC integration points from the [platform contract](../../docs/app-platform.md) — see that doc for what each piece means and how onboarding actually works. This template doesn't re-explain platform mechanics; it just implements them.

## Stack

Clang (C++23), CMake + Ninja, vcpkg (manifest mode) for dependencies, clang-tidy, GoogleTest. `cpp-httplib` for the HTTP surface, `libpqxx` for Postgres, `nlohmann-json`, and `grpc`/`protobuf` for the service-to-service API (ADR-0020).

Two servers, one process: an HTTP server (browser-facing, Traefik-routed, port 8000) and a gRPC server (service-to-service, internal-only on the `home-platform` Docker network, port 9090) run on separate threads in the same binary — see `src/main.cpp`.

## Using this template

1. Copy this directory's contents into a new app repo (`github.com/bcalaway/<app-name>`).
2. Replace every `REPLACE_WITH_APP_NAME` (in `deploy/docker-compose.yml` and `.github/workflows/cd.yml`) with the app's real name — it must match the ECR repo / IAM role name from `terraform/aws/apps.tf` in `nyc_pa_aws_gitops`.
3. Set `APP_NAME` in the deploy environment to the same value (comes from SSM per the platform's secrets convention, or just hardcode it as a plain env var in `deploy/docker-compose.yml` since it's not a secret).
4. Follow the onboarding checklist in `docs/app-platform.md` (database, Authentik client, Route53 record, IAM role) — these are platform-side steps, not something this template does for you.
5. Build out `proto/example_service.proto` and `src/grpc_service.cpp` into the real service API, and `src/http_server.cpp` into the real browser-facing routes. `/health`, `/`, `/db-check`, `/login`, `/auth/callback`, and the `ExampleService.Ping` RPC are working examples, not requirements.

## Local development

Requires a C++23 compiler (clang recommended, matching the Dockerfile), CMake 3.28+, Ninja, and [vcpkg](https://github.com/microsoft/vcpkg) (`bootstrap-vcpkg.sh`/`.bat`, then set `VCPKG_ROOT`).

```
cmake -S . -B build -G Ninja -DCMAKE_TOOLCHAIN_FILE=$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake
cmake --build build
./build/app
```

`POSTGRES_PASSWORD` / `AUTHENTIK_CLIENT_ID` / `AUTHENTIK_CLIENT_SECRET` are all optional locally — the app degrades gracefully (see `src/db.cpp` and the `/login` 501 behavior in `src/http_server.cpp`) rather than requiring live Postgres/Authentik to run.

The first configure will build `grpc` and its dependency tree from source via vcpkg — genuinely slow (tens of minutes) on a cold vcpkg cache. Subsequent builds reuse it.

## Auth gating

Once `AUTHENTIK_CLIENT_ID`/`AUTHENTIK_CLIENT_SECRET` are set, every HTTP route except `/health`, `/login`, and `/auth/callback` requires an authenticated session — `/api/*` calls get a `401` JSON response, other page loads redirect to `/login`. See the pre-routing handler in `src/http_server.cpp`. Before those credentials are set (a fresh, not-yet-onboarded app), the app stays fully open rather than locking itself out. This mirrors the fix applied to `todo-app` and the Python/React templates — see CLAUDE.md's Gotchas in `nyc_pa_aws_gitops` if extending it.

OIDC endpoints (`authorization_endpoint`, `token_endpoint`) are discovered at runtime from Authentik's `.well-known/openid-configuration`, not hardcoded — see `src/oidc_client.cpp` for why, and for why the id_token's signature isn't cryptographically verified (a deliberate, documented simplification for this specific flow, not an oversight).

## Service-to-service gRPC

`proto/example_service.proto` defines `ExampleService.Ping` as a working example. The gRPC server (`src/grpc_service.cpp`) listens on port 9090, plaintext, and is never exposed through Traefik — per ADR-0020, it's reachable only by other containers on the shared `home-platform` Docker network, by this app's own container hostname. It also registers the standard `grpc.health.v1.Health` service automatically.

## Tests and lint

```
cmake --build build --target app_tests
ctest --test-dir build --output-on-failure

cmake --build build --target app_lib
clang-tidy -p build src/*.cpp
```

Both also run inside Docker via the `test` / `lint` build stages — `docker build --target test .` / `docker build --target lint .` — which is what `app-ci.yml` actually runs in CI.
