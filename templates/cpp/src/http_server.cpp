#include "http_server.hpp"

#include <nlohmann/json.hpp>

#include <array>
#include <iomanip>
#include <sstream>
#include <unordered_set>

#include "db.hpp"
#include "oidc_client.hpp"

namespace {

// Routes reachable without an authenticated session -- everything else is
// gated by the pre-routing handler installed below.
const std::unordered_set<std::string> kPublicPaths = {"/health", "/login", "/auth/callback"};

std::string url_encode(const std::string& value) {
  std::ostringstream out;
  out << std::hex << std::uppercase;
  for (unsigned char c : value) {
    if (std::isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~') {
      out << c;
    } else {
      out << '%' << std::setw(2) << std::setfill('0') << static_cast<int>(c);
    }
  }
  return out.str();
}

std::string get_cookie(const httplib::Request& req, const std::string& name) {
  if (!req.has_header("Cookie")) return "";
  std::string cookie_header = req.get_header_value("Cookie");
  std::string needle = name + "=";
  size_t pos = cookie_header.find(needle);
  if (pos == std::string::npos) return "";
  size_t start = pos + needle.size();
  size_t end = cookie_header.find(';', start);
  return cookie_header.substr(start, end == std::string::npos ? std::string::npos : end - start);
}

std::string redirect_uri_for(const Config& config) {
  return "https://" + config.app_name + ".billandjessie.com/auth/callback";
}

}  // namespace

void configure_routes(httplib::Server& svr, const Config& config, SessionStore& sessions) {
  auto oidc = std::make_shared<OidcClient>(config);

  svr.Get("/health", [](const httplib::Request&, httplib::Response& res) {
    res.set_content(nlohmann::json{{"status", "ok"}}.dump(), "application/json");
  });

  svr.Get("/", [&config](const httplib::Request&, httplib::Response& res) {
    res.set_content(nlohmann::json{{"app", config.app_name}, {"status", "running"}}.dump(), "application/json");
  });

  svr.Get("/db-check", [&config](const httplib::Request&, httplib::Response& res) {
    res.set_content(nlohmann::json{{"connected", check_connection(config)}}.dump(), "application/json");
  });

  svr.Get("/login", [&config, &sessions, oidc](const httplib::Request&, httplib::Response& res) {
    if (!config.auth_configured()) {
      res.status = 501;
      res.set_content(nlohmann::json{{"error", "auth not configured"}}.dump(), "application/json");
      return;
    }

    auto eps = oidc->endpoints();
    if (!eps.has_value()) {
      res.status = 502;
      res.set_content(nlohmann::json{{"error", "oidc discovery failed"}}.dump(), "application/json");
      return;
    }

    // The session id doubles as the OAuth `state` value: /auth/callback only
    // accepts a state it finds a matching session for, which is standard
    // state-parameter CSRF protection without needing separate storage.
    std::string session_id = sessions.create();
    std::string nonce = generate_random_token();

    std::string url = eps->authorization_endpoint +
                       "?response_type=code"
                       "&client_id=" + url_encode(*config.authentik_client_id) +
                       "&redirect_uri=" + url_encode(redirect_uri_for(config)) +
                       "&scope=" + url_encode("openid profile email") +
                       "&state=" + session_id +
                       "&nonce=" + nonce;

    res.set_header("Set-Cookie", "session_id=" + session_id + "; HttpOnly; Secure; Path=/; SameSite=Lax");
    res.set_redirect(url);
  });

  svr.Get("/auth/callback", [&config, &sessions, oidc](const httplib::Request& req, httplib::Response& res) {
    if (!config.auth_configured()) {
      res.status = 501;
      res.set_content(nlohmann::json{{"error", "auth not configured"}}.dump(), "application/json");
      return;
    }

    std::string code = req.get_param_value("code");
    std::string state = req.get_param_value("state");
    std::string cookie_session = get_cookie(req, "session_id");

    if (code.empty() || state.empty() || cookie_session.empty() || state != cookie_session ||
        !sessions.get(cookie_session).has_value()) {
      res.status = 400;
      res.set_content(nlohmann::json{{"error", "invalid or missing state"}}.dump(), "application/json");
      return;
    }

    auto result = oidc->exchange_code(code, redirect_uri_for(config));
    if (!result.success) {
      res.status = 502;
      res.set_content(nlohmann::json{{"error", "token exchange failed"}}.dump(), "application/json");
      return;
    }

    sessions.set_authenticated(cookie_session, result.email);
    res.set_redirect("/");
  });

  // Only enforced once real Authentik credentials are configured --
  // pre-onboarding (no client id/secret in SSM yet), the app stays open
  // rather than locking itself out before auth is even wired up.
  svr.set_pre_routing_handler([&config, &sessions](const httplib::Request& req, httplib::Response& res) {
    if (!config.auth_configured() || kPublicPaths.contains(req.path)) {
      return httplib::Server::HandlerResponse::Unhandled;
    }

    std::string cookie_session = get_cookie(req, "session_id");
    auto session = cookie_session.empty() ? std::nullopt : sessions.get(cookie_session);
    if (session.has_value() && session->authenticated) {
      return httplib::Server::HandlerResponse::Unhandled;
    }

    if (req.path.starts_with("/api/")) {
      res.status = 401;
      res.set_content(nlohmann::json{{"error", "authentication required"}}.dump(), "application/json");
    } else {
      res.set_redirect("/login");
    }
    return httplib::Server::HandlerResponse::Handled;
  });
}

void run_http_server(const Config& config, SessionStore& sessions) {
  httplib::Server svr;
  configure_routes(svr, config, sessions);
  svr.listen("0.0.0.0", config.http_port);
}
