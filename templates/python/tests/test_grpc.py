import asyncio

import grpc
from grpc_health.v1 import health_pb2, health_pb2_grpc

from app.grpc_gen import example_service_pb2, example_service_pb2_grpc
from app.grpc_server import EXAMPLE_SERVICE, start_grpc_server


async def _call(fn):
    # Port 0: the OS picks a free port, so tests never collide with 9090.
    server, port = await start_grpc_server(0)
    try:
        async with grpc.aio.insecure_channel(f"localhost:{port}") as channel:
            return await fn(channel)
    finally:
        await server.stop(grace=None)


def test_health_reports_serving():
    async def check(channel):
        stub = health_pb2_grpc.HealthStub(channel)
        overall = await stub.Check(health_pb2.HealthCheckRequest(service=""))
        example = await stub.Check(health_pb2.HealthCheckRequest(service=EXAMPLE_SERVICE))
        return overall.status, example.status

    serving = health_pb2.HealthCheckResponse.SERVING
    assert asyncio.run(_call(check)) == (serving, serving)


def test_ping():
    async def ping(channel):
        stub = example_service_pb2_grpc.ExampleServiceStub(channel)
        return await stub.Ping(example_service_pb2.PingRequest(message="hello"))

    assert asyncio.run(_call(ping)).message == "pong: hello"
