#include <iostream>
#include <thread>

#include "config.hpp"
#include "grpc_service.hpp"
#include "http_server.hpp"
#include "session_store.hpp"

int main() {
  Config config = Config::from_env();
  SessionStore sessions;

  // gRPC (service-to-service, internal-only) and HTTP (browser-facing,
  // Traefik-routed) run as two servers in the same process/container --
  // see ADR-0020. HTTP runs on the main thread and blocks for the life of
  // the process; gRPC gets its own thread.
  std::thread grpc_thread([&config]() { run_grpc_server(config); });

  std::cout << config.app_name << ": HTTP on :" << config.http_port << ", gRPC on :" << config.grpc_port
            << std::endl;

  run_http_server(config, sessions);

  grpc_thread.join();
  return 0;
}
