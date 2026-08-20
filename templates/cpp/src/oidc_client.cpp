#include "oidc_client.hpp"

#include <httplib.h>
#include <nlohmann/json.hpp>

#include <array>
#include <utility>

namespace {

// Splits "https://host[:port]/path/to/thing" into ("https://host[:port]",
// "/path/to/thing") -- cpp-httplib's Client is bound to one host and takes
// just the path per-request, but discovery hands back full absolute URLs.
std::pair<std::string, std::string> split_url(const std::string& url) {
  auto scheme_end = url.find("://");
  if (scheme_end == std::string::npos) return {url, "/"};
  auto path_start = url.find('/', scheme_end + 3);
  if (path_start == std::string::npos) return {url, "/"};
  return {url.substr(0, path_start), url.substr(path_start)};
}

std::string base64url_decode(std::string input) {
  for (char& c : input) {
    if (c == '-') c = '+';
    if (c == '_') c = '/';
  }
  while (input.size() % 4 != 0) input.push_back('=');

  static constexpr std::string_view alphabet =
      "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  std::array<int, 256> lookup{};
  lookup.fill(-1);
  for (size_t i = 0; i < alphabet.size(); ++i) lookup[static_cast<unsigned char>(alphabet[i])] = static_cast<int>(i);

  std::string out;
  int bits = 0, accumulator = 0;
  for (unsigned char c : input) {
    if (c == '=') break;
    int value = lookup[c];
    if (value < 0) continue;
    accumulator = (accumulator << 6) | value;
    bits += 6;
    if (bits >= 8) {
      bits -= 8;
      out.push_back(static_cast<char>((accumulator >> bits) & 0xFF));
    }
  }
  return out;
}

// Decodes the id_token's payload claims WITHOUT verifying the JWT signature.
//
// This is a deliberate simplification, not an oversight: for the
// authorization-code flow with a confidential client (this template, per
// ADR-0017 -- "authorization code, not implicit"), the token exchange below
// is a direct server-to-server HTTPS call from this app to Authentik's own
// token endpoint. That exchange succeeding at all -- over TLS, using this
// app's own client secret -- is what actually proves the user authenticated;
// the browser never sees or could forge that step. Signature verification
// is still good defense-in-depth (confirms issuer/audience/expiry even if
// something upstream is misconfigured), but its absence here doesn't open
// the login flow to forgery the way skipping it would for tokens presented
// directly by a client (e.g. the implicit/SPA flow this template explicitly
// doesn't use).
std::optional<nlohmann::json> decode_jwt_claims_unverified(const std::string& jwt) {
  auto first_dot = jwt.find('.');
  if (first_dot == std::string::npos) return std::nullopt;
  auto second_dot = jwt.find('.', first_dot + 1);
  if (second_dot == std::string::npos) return std::nullopt;

  std::string payload = jwt.substr(first_dot + 1, second_dot - first_dot - 1);
  auto decoded = base64url_decode(payload);
  auto json = nlohmann::json::parse(decoded, nullptr, false);
  if (json.is_discarded()) return std::nullopt;
  return json;
}

}  // namespace

std::optional<OidcEndpoints> OidcClient::endpoints() {
  if (cached_endpoints_.has_value()) return cached_endpoints_;

  httplib::Client cli(config_.authentik_base_url);
  cli.set_follow_location(true);
  cli.set_connection_timeout(5);

  auto res = cli.Get("/application/o/" + config_.app_name + "/.well-known/openid-configuration");
  if (!res || res->status != 200) return std::nullopt;

  auto json = nlohmann::json::parse(res->body, nullptr, false);
  if (json.is_discarded()) return std::nullopt;
  if (!json.contains("authorization_endpoint") || !json.contains("token_endpoint")) return std::nullopt;

  cached_endpoints_ = OidcEndpoints{
      .authorization_endpoint = json.at("authorization_endpoint").get<std::string>(),
      .token_endpoint = json.at("token_endpoint").get<std::string>(),
  };
  return cached_endpoints_;
}

TokenResult OidcClient::exchange_code(const std::string& code, const std::string& redirect_uri) {
  auto eps = endpoints();
  if (!eps.has_value() || !config_.auth_configured()) return TokenResult{};

  auto [base, path] = split_url(eps->token_endpoint);
  httplib::Client cli(base);
  cli.set_connection_timeout(5);

  httplib::Params params{
      {"grant_type", "authorization_code"},
      {"code", code},
      {"redirect_uri", redirect_uri},
      {"client_id", *config_.authentik_client_id},
      {"client_secret", *config_.authentik_client_secret},
  };

  auto res = cli.Post(path, params);
  if (!res || res->status != 200) return TokenResult{};

  auto json = nlohmann::json::parse(res->body, nullptr, false);
  if (json.is_discarded() || !json.contains("id_token")) return TokenResult{};

  auto claims = decode_jwt_claims_unverified(json.at("id_token").get<std::string>());
  if (!claims.has_value()) return TokenResult{};

  TokenResult result;
  result.success = true;
  result.email = claims->value("email", claims->value("sub", ""));
  return result;
}
