"""gRPC server (ADR-0020): the app's service-to-service API.

Internal-only: listens on GRPC_PORT (9090 by convention), plaintext, reachable
only by other containers on the `home-platform` Docker network at
`<app-name>:9090`. Never routed through Traefik. Runs in the same process
and event loop as the FastAPI app (started from its lifespan in app/main.py).

Also serves the standard grpc.health.v1.Health service, so callers and
probes (e.g. `grpc_health_probe -addr=<app>:9090`) can check it.

ExampleService.Ping is a working example -- replace proto/example_service.proto
and ExampleService below with the real API.
"""

import grpc
from grpc_health.v1 import health, health_pb2, health_pb2_grpc

from app.grpc_gen import example_service_pb2, example_service_pb2_grpc

EXAMPLE_SERVICE = example_service_pb2.DESCRIPTOR.services_by_name["ExampleService"].full_name


class ExampleService(example_service_pb2_grpc.ExampleServiceServicer):
    # Method name comes from the proto, hence not snake_case.
    async def Ping(self, request, context):
        return example_service_pb2.PingResponse(message=f"pong: {request.message}")


async def start_grpc_server(port: int) -> tuple[grpc.aio.Server, int]:
    """Start the server; returns it and the bound port (port 0 picks a free one)."""
    server = grpc.aio.server()
    example_service_pb2_grpc.add_ExampleServiceServicer_to_server(ExampleService(), server)

    health_servicer = health.aio.HealthServicer()
    health_pb2_grpc.add_HealthServicer_to_server(health_servicer, server)

    bound = server.add_insecure_port(f"[::]:{port}")
    await server.start()
    # "" is the overall server status; each service also reports its own.
    for service in ("", EXAMPLE_SERVICE):
        await health_servicer.set(service, health_pb2.HealthCheckResponse.SERVING)
    return server, bound
