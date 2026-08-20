# ADR-0020: gRPC for Service-to-Service Communication

Date: 2026-08-20
Status: Accepted

## Context

Every app onboarded so far (Python/React templates, `todo-app`) is a standalone web app: a browser talks to it through Traefik, it optionally talks to Postgres, and that's the whole interaction surface. Nothing on the platform has needed to call another app's API directly yet.

That changes starting with the C++ starter template — Bill's explicit direction is that apps should be able to call each other's service APIs, and that this should be a platform-wide convention going forward, not a one-off built into a single app. Before wiring that into a starter template, the platform needs a standard answer for *how* two services on the hub talk to each other, so every future app (in every language) follows the same pattern instead of each inventing its own.

## Options Considered

**Option A: Plain REST/JSON, reusing each app's existing browser-facing HTTP surface**
- Zero new tooling — every template already speaks HTTP/JSON
- No schema contract: nothing catches a caller and callee drifting out of sync except runtime errors: no codegen, no compile-time type checking across the C++/Python/JS boundary
- As more services start calling each other, this is exactly the kind of implicit, undocumented contract that's caused real pain elsewhere in this platform (e.g. the RouterOS/WireGuard reapply incident, CLAUDE.md's Gotchas) — cheap now, drifts expensive later

**Option B: gRPC (HTTP/2 + Protobuf)**
- Contract is a `.proto` file, not a convention — codegen produces a typed client and server stub in whatever language each side is written in, so a C++ service and a future Python or Node service can call each other with compile-time-checked message shapes
- Efficient binary framing over HTTP/2, with streaming available for free if a future app ever needs it (no current app does — not a reason to choose it, just a lower-effort ceiling than REST)
- Real cost: every template now needs a gRPC library and a protoc/codegen step wired into its build, and vcpkg building `grpc` and its dependency tree (protobuf, abseil, c-ares, re2) from source on Windows is genuinely slow (tens of minutes, first build)

**Option C: A message queue / event bus (e.g. NATS, RabbitMQ)**
- Right shape for async, fire-and-forget, or fan-out patterns
- Wrong shape for what's actually needed today: direct request/response calls between two known services
- Introduces a new stateful shared service to run, monitor, and back up, for zero current consumers — the platform's established pattern (e.g. the `home-platform` Docker network migration, ADR-0018/0019) is to build shared infrastructure when a real consumer needs it, not speculatively
- Rejected for now on the same grounds ADR-0016 rejected Aurora: solving a scale/shape problem this platform doesn't have yet

## Decision

gRPC (Option B) becomes the platform standard for service-to-service calls. Every app template built from here forward exposes a gRPC server for its service API, **in addition to**, not instead of, the existing HTTP/JSON surface — the two solve different problems:

- **HTTP/JSON via Traefik** stays the browser-facing and health-check interface. Authentik's OIDC login (ADR-0017) is fundamentally a browser-redirect flow; gRPC doesn't replace it and isn't meant to.
- **gRPC** is for one app's backend calling another app's backend directly, without a browser in the loop.

**Networking**: gRPC servers are internal-only, reachable by other containers on the shared `home-platform` Docker network by hostname — the same trust boundary as Postgres and Redis (ADR-0016; Redis under ADR-0017). Never published to the internet, no Traefik route, no TLS at this hop — the Docker network boundary *is* the security boundary here, matching Postgres's existing internal-only `sslmode=disable` precedent. Standard port convention: **9090** (distinct from each app's HTTP port, conventionally 8000), documented per-app in its `deploy/docker-compose.yml` the same way port 8000 already is.

**External or browser-facing gRPC** (e.g. grpc-web from a JS frontend, or a gRPC consumer outside the Docker network) is explicitly out of scope for this ADR. Traefik does support HTTP/2 (h2c) backend routing, but no current app needs it, so it isn't being built speculatively — same reasoning the `home-platform` network migration itself followed. If a real consumer shows up, that's a small, targeted Traefik change against a concrete need, not a platform-wide upgrade made in advance of one.

**Proto ownership**: `.proto` files live in each app's own repo under `proto/`, per ADR-0014's app-code-stays-in-the-app-repo boundary — not centralized in `nyc_pa_aws_gitops`, which would make the platform repo an app-logic dependency (exactly what ADR-0014 exists to prevent). If two apps ever need to share a contract, that's a call for a future ADR once a second real consumer exists, not a shared-proto-package built ahead of time for a problem with one participant.

## Consequences

- Every future starter template needs a gRPC library and codegen wired into its build (C++: `grpc`/`protobuf` via vcpkg, code generated by CMake). The Python and React templates are **not** retrofitted with a gRPC server as part of this ADR — they have no current gRPC consumer, and adding one speculatively would be the same mistake Option C was rejected for. They pick it up when a real caller needs to reach them.
- New port convention: every app template that speaks gRPC exposes it on 9090, internal-only on the `home-platform` network, never a Traefik label.
- gRPC health checks use the standard `grpc.health.v1.Health` service rather than reusing each app's HTTP `/health` — a gRPC-only caller shouldn't need to also speak HTTP just to check liveness.
- No shared proto registry yet. Revisit if/when a second app actually needs to consume another app's `.proto`.
