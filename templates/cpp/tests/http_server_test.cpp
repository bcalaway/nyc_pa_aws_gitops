#include <gtest/gtest.h>
#include <httplib.h>
#include <nlohmann/json.hpp>

#include <chrono>
#include <thread>

#include "config.hpp"
#include "http_server.hpp"
#include "session_store.hpp"

namespace {

// Binds to an OS-assigned ephemeral port and drives the server with a real
// httplib::Client -- cpp-httplib has no in-process TestClient equivalent to
// FastAPI's/Express's, so exercising real routes means a real bound socket.
class HttpServerTest : public ::testing::Test {
 protected:
  void SetUp() override {
    config_ = Config::from_env();  // no auth/db configured in the test env
    port_ = svr_.bind_to_any_port("127.0.0.1");
    configure_routes(svr_, config_, sessions_);
    server_thread_ = std::thread([this]() { svr_.listen_after_bind(); });
    while (!svr_.is_running()) {
      std::this_thread::sleep_for(std::chrono::milliseconds(5));
    }
  }

  void TearDown() override {
    svr_.stop();
    server_thread_.join();
  }

  httplib::Client client() { return httplib::Client("127.0.0.1", port_); }

  Config config_;
  SessionStore sessions_;
  httplib::Server svr_;
  int port_ = 0;
  std::thread server_thread_;
};

TEST_F(HttpServerTest, Health) {
  auto res = client().Get("/health");
  ASSERT_TRUE(res);
  EXPECT_EQ(res->status, 200);
  EXPECT_EQ(nlohmann::json::parse(res->body).at("status"), "ok");
}

TEST_F(HttpServerTest, Root) {
  auto res = client().Get("/");
  ASSERT_TRUE(res);
  EXPECT_EQ(res->status, 200);
  EXPECT_EQ(nlohmann::json::parse(res->body).at("status"), "running");
}

TEST_F(HttpServerTest, DbCheckWithoutConfiguredDb) {
  // No POSTGRES_PASSWORD in the test environment -- confirms the app
  // degrades gracefully instead of crashing when Postgres isn't wired up.
  auto res = client().Get("/db-check");
  ASSERT_TRUE(res);
  EXPECT_EQ(res->status, 200);
  EXPECT_EQ(nlohmann::json::parse(res->body).at("connected"), false);
}

TEST_F(HttpServerTest, LoginWithoutConfiguredAuth) {
  // No AUTHENTIK_CLIENT_ID/SECRET in the test environment -- confirms the
  // auth route responds cleanly instead of crashing when Authentik isn't
  // wired up yet.
  auto res = client().Get("/login");
  ASSERT_TRUE(res);
  EXPECT_EQ(res->status, 501);
}

}  // namespace
