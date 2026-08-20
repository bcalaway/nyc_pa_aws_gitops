#include "grpc_service.hpp"

#include <grpcpp/grpcpp.h>
#include <grpcpp/health_check_service_interface.h>

grpc::Status ExampleServiceImpl::Ping(grpc::ServerContext* /*context*/, const app_template::PingRequest* request,
                                       app_template::PingResponse* response) {
  response->set_message("pong: " + request->message());
  return grpc::Status::OK;
}

void run_grpc_server(const Config& config) {
  // Registers the standard grpc.health.v1.Health service (ADR-0020) so a
  // caller doesn't need this app's HTTP /health route just to check gRPC
  // liveness.
  grpc::EnableDefaultHealthCheckService(true);

  ExampleServiceImpl service;
  std::string address = "0.0.0.0:" + std::to_string(config.grpc_port);

  grpc::ServerBuilder builder;
  builder.AddListeningPort(address, grpc::InsecureServerCredentials());
  builder.RegisterService(&service);

  std::unique_ptr<grpc::Server> server(builder.BuildAndStart());
  server->Wait();
}
