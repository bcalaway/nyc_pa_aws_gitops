#pragma once

#include <httplib.h>

#include "config.hpp"
#include "session_store.hpp"

// Registers all routes and the auth-gating middleware on an existing
// httplib::Server -- split out from run_http_server() so tests can bind an
// ephemeral port and drive the server with a real httplib::Client instead of
// needing a fixed port or a fake request/response harness.
void configure_routes(httplib::Server& svr, const Config& config, SessionStore& sessions);

// Blocking call -- builds a Server, configures it, and listens on
// config.http_port until the process exits.
void run_http_server(const Config& config, SessionStore& sessions);
