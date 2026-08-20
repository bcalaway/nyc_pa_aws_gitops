#pragma once

#include "config.hpp"

// No password configured means this app either hasn't been onboarded to
// Postgres yet or doesn't use it -- both are valid states, not an error,
// so callers get a clean "not connected" instead of a crash.
bool check_connection(const Config& config);
