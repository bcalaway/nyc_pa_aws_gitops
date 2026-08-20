#include "config.hpp"

#include <cstdlib>

namespace {

std::string env_or(const char* name, std::string default_value) {
  const char* value = std::getenv(name);
  return value != nullptr ? std::string(value) : std::move(default_value);
}

std::optional<std::string> env_opt(const char* name) {
  const char* value = std::getenv(name);
  if (value == nullptr) return std::nullopt;
  return std::string(value);
}

int env_int_or(const char* name, int default_value) {
  const char* value = std::getenv(name);
  if (value == nullptr) return default_value;
  try {
    return std::stoi(value);
  } catch (...) {
    return default_value;
  }
}

}  // namespace

Config Config::from_env() {
  return Config{
      .app_name = env_or("APP_NAME", "app"),
      .http_port = env_int_or("HTTP_PORT", 8000),
      .grpc_port = env_int_or("GRPC_PORT", 9090),
      .session_secret = env_or("SESSION_SECRET", "dev-insecure-secret-change-me"),
      .postgres_host = env_or("POSTGRES_HOST", "postgres"),
      .postgres_password = env_opt("POSTGRES_PASSWORD"),
      .authentik_base_url = env_or("AUTHENTIK_BASE_URL", "https://auth.billandjessie.com"),
      .authentik_client_id = env_opt("AUTHENTIK_CLIENT_ID"),
      .authentik_client_secret = env_opt("AUTHENTIK_CLIENT_SECRET"),
  };
}
