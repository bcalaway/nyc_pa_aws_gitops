#pragma once

#include <optional>
#include <string>

#include "config.hpp"

struct OidcEndpoints {
  std::string authorization_endpoint;
  std::string token_endpoint;
};

struct TokenResult {
  bool success = false;
  std::string email;  // best-effort, decoded from the id_token's claims
};

// Talks to Authentik's OIDC discovery/token endpoints for the authorization
// code flow (ADR-0017 Pattern A). Endpoints are discovered at runtime from
// Authentik's own `.well-known/openid-configuration` rather than hardcoded,
// the same way Authlib/express-openid-connect do it under the hood -- so
// this template doesn't need to guess Authentik's exact path layout.
class OidcClient {
 public:
  explicit OidcClient(const Config& config) : config_(config) {}

  // Fetches and caches the discovery document on first call.
  std::optional<OidcEndpoints> endpoints();

  // Exchanges an authorization code for tokens against the token endpoint.
  // See oidc_client.cpp for why this doesn't cryptographically verify the
  // id_token's signature and why that's an acceptable simplification here.
  TokenResult exchange_code(const std::string& code, const std::string& redirect_uri);

 private:
  const Config& config_;
  std::optional<OidcEndpoints> cached_endpoints_;
};
