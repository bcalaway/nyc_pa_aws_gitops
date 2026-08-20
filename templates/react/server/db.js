import pg from "pg";
import { config } from "./config.js";

// No password configured means this app either hasn't been onboarded to
// Postgres yet or doesn't use it -- both are valid states, not an error,
// so callers get a clean "not connected" instead of a crash.
export async function checkConnection() {
  if (!config.postgresPassword) return false;

  const client = new pg.Client({
    host: config.postgresHost,
    port: 5432,
    user: config.appName,
    password: config.postgresPassword,
    database: config.appName,
  });

  try {
    await client.connect();
    await client.query("SELECT 1");
    return true;
  } catch {
    return false;
  } finally {
    await client.end().catch(() => {});
  }
}
