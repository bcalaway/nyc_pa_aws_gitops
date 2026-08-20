#pragma once

#include "config.hpp"
#include "example_service.grpc.pb.h"

// Working example, not a requirement -- replace with the real service.
class ExampleServiceImpl final : public app_template::ExampleService::Service {
 public:
  grpc::Status Ping(grpc::ServerContext* context, const app_template::PingRequest* request,
                     app_template::PingResponse* response) override;
};

// Blocking call -- builds and runs the gRPC server on config.grpc_port.
// Insecure/plaintext per ADR-0020: internal-only on the shared
// `home-platform` Docker network, same trust boundary as Postgres/Redis --
// see docs/app-platform.md's "Service-to-service communication" section in
// nyc_pa_aws_gitops.
void run_grpc_server(const Config& config);
