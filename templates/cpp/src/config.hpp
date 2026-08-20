#pragma once

#include <optional>
#include <string>

// APP_NAME must match this app's ECR repo / IAM role name / Postgres
// database name / Route53 subdomain -- one name ties the whole platform
// integration together, see docs/app-platform.md in nyc_pa_aws_gitops.
struct Config {
  std::string app_name;
  int http_port;
  int grpc_port;

  // Should come from SSM (/home-platform/<app>/session-secret) once deployed --
  // the default here is only for local dev/tests, never use it in production.
  std::string session_secret;

  // Postgres (ADR-0016). POSTGRES_PASSWORD arrives via the platform's
  // deploy-time .env convention -- unset locally means db-dependent
  // features degrade gracefully instead of crashing (see src/db.cpp).
  std::string postgres_host;
  std::optional<std::string> postgres_password;

  // Authentik OIDC (ADR-0017, Pattern A). Both unset means auth stays off
  // entirely (app runs fully open) -- lets this template run standalone
  // before an app is actually onboarded to Authentik.
  std::string authentik_base_url;
  std::optional<std::string> authentik_client_id;
  std::optional<std::string> authentik_client_secret;

  [[nodiscard]] bool auth_configured() const {
    return authentik_client_id.has_value() && authentik_client_secret.has_value();
  }

  static Config from_env();
};
