#include "db.hpp"

#include <pqxx/pqxx>

bool check_connection(const Config& config) {
  if (!config.postgres_password.has_value()) return false;

  try {
    const std::string conninfo = "postgresql://" + config.app_name + ":" + *config.postgres_password +
                                  "@" + config.postgres_host + ":5432/" + config.app_name;
    pqxx::connection conn(conninfo);
    pqxx::nontransaction txn(conn);
    txn.exec("SELECT 1");
    return true;
  } catch (const std::exception&) {
    return false;
  }
}
