import { useEffect, useState } from "react";

// Working example, not a requirement -- replace with the real app UI.
// Demonstrates the two integration points every app on the platform needs:
// hitting its own backend's /health and /db-check (see server/index.js).
export default function App() {
  const [health, setHealth] = useState(null);
  const [dbConnected, setDbConnected] = useState(null);

  useEffect(() => {
    fetch("/health")
      .then((r) => r.json())
      .then((data) => setHealth(data.status))
      .catch(() => setHealth("unreachable"));

    fetch("/db-check")
      .then((r) => r.json())
      .then((data) => setDbConnected(data.connected))
      .catch(() => setDbConnected(false));
  }, []);

  return (
    <main>
      <h1>React App Template</h1>
      <p>Backend health: {health ?? "checking..."}</p>
      <p>Database connected: {dbConnected === null ? "checking..." : String(dbConnected)}</p>
      <p>
        <a href="/login">Log in</a>
      </p>
    </main>
  );
}
