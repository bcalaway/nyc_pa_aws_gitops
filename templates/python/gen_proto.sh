#!/bin/sh
# Generate Python gRPC code from proto/ into app/grpc_gen/ (not committed).
# The Dockerfile runs the same command; run this locally after editing a
# .proto. The -I mapping makes the generated stubs import each other as
# `app.grpc_gen.<name>_pb2`, so they work as a normal package.
set -e
cd "$(dirname "$0")"
python -m grpc_tools.protoc -Iapp/grpc_gen=proto \
  --python_out=. --pyi_out=. --grpc_python_out=. proto/*.proto
