#include "session_store.hpp"

#include <iomanip>
#include <random>
#include <sstream>

std::string generate_random_token() {
  std::random_device rd;
  std::uniform_int_distribution<uint32_t> dist(0, 0xFFFFFFFF);

  std::ostringstream out;
  out << std::hex << std::setfill('0');
  for (int i = 0; i < 8; ++i) {
    out << std::setw(8) << dist(rd);
  }
  return out.str();
}

std::string SessionStore::create() {
  std::string id = generate_random_token();
  std::lock_guard<std::mutex> lock(mutex_);
  sessions_[id] = Session{};
  return id;
}

void SessionStore::set_authenticated(const std::string& session_id, std::string email) {
  std::lock_guard<std::mutex> lock(mutex_);
  auto& session = sessions_[session_id];
  session.authenticated = true;
  session.email = std::move(email);
}

std::optional<Session> SessionStore::get(const std::string& session_id) const {
  std::lock_guard<std::mutex> lock(mutex_);
  auto it = sessions_.find(session_id);
  if (it == sessions_.end()) return std::nullopt;
  return it->second;
}
