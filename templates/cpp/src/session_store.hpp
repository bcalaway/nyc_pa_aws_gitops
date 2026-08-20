#pragma once

#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>

// Minimal in-memory session store -- a working example matching the other
// templates' session-cookie pattern (Starlette's SessionMiddleware / Express's
// express-session), not a production session store. A real app with multiple
// replicas would need a shared store (e.g. the platform's own Redis, see
// ADR-0017) instead of per-process memory.
struct Session {
  bool authenticated = false;
  std::string email;
};

class SessionStore {
 public:
  // Returns a new random session id, registered with an empty (unauthenticated)
  // session. Used for the OIDC state/nonce cookie issued before login completes.
  std::string create();

  void set_authenticated(const std::string& session_id, std::string email);

  [[nodiscard]] std::optional<Session> get(const std::string& session_id) const;

 private:
  mutable std::mutex mutex_;
  std::unordered_map<std::string, Session> sessions_;
};

// 256 bits of randomness from std::random_device (backed by the OS entropy
// source, e.g. getrandom()/urandom on Linux), hex-encoded -- used for session
// ids and the OAuth state/nonce values, where unpredictability matters
// (session hijacking, CSRF via a guessed/replayed state).
std::string generate_random_token();
