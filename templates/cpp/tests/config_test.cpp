#include <gtest/gtest.h>

#include "config.hpp"

TEST(ConfigTest, DefaultsWhenNoEnvVarsSet) {
  // The test environment intentionally has none of these set -- confirms
  // the template runs standalone before an app is onboarded to Postgres or
  // Authentik, same as the Python/React templates' equivalent tests.
  Config config = Config::from_env();

  EXPECT_EQ(config.app_name, "app");
  EXPECT_EQ(config.http_port, 8000);
  EXPECT_EQ(config.grpc_port, 9090);
  EXPECT_FALSE(config.postgres_password.has_value());
  EXPECT_FALSE(config.auth_configured());
}
