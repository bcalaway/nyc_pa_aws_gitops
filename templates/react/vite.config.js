import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Backend (server/) is plain Node, run directly by `node` -- Vite only
// ever builds the frontend (src/) into dist/, which server/index.js then
// serves statically. See README.md for the two-process split.
export default defineConfig({
  plugins: [react()],
  server: {
    // Dev-only: forwards backend routes to `npm run dev:server` (:8000) so
    // `npm run dev`'s hot-reloading frontend can still call the real API
    // instead of needing its own mocks. Not used in production -- there,
    // server/index.js serves the built frontend itself, no proxy involved.
    proxy: {
      "/health": "http://localhost:8000",
      "/db-check": "http://localhost:8000",
      "/login": "http://localhost:8000",
      "/auth/callback": "http://localhost:8000",
      "/api": "http://localhost:8000",
    },
  },
  test: {
    environment: "node",
    globals: true,
    setupFiles: ["./tests/setup.js"],
  },
});
