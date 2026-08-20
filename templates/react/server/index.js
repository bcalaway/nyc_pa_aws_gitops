import path from "node:path";
import { pathToFileURL } from "node:url";
import express from "express";
import { auth } from "express-openid-connect";
import { config } from "./config.js";
import { checkConnection } from "./db.js";

const DIST_DIR = path.join(import.meta.dirname, "..", "dist");

// Registered only when real credentials are present (post-onboarding, see
// docs/app-platform.md's Auth section in nyc_pa_aws_gitops) -- the issuer
// matches Authentik's per-application OIDC endpoint,
// https://auth.billandjessie.com/application/o/<app-slug>/.well-known/openid-configuration.
export const authConfigured = Boolean(config.authentikClientId && config.authentikClientSecret);

// Routes reachable without an authenticated session -- everything else
// (including the built frontend and its own API calls) is gated below.
const PUBLIC_PATHS = new Set(["/health", "/login", "/auth/callback"]);

export function createApp() {
  const app = express();

  app.get("/health", (req, res) => res.json({ status: "ok" }));

  if (authConfigured) {
    app.use(
      auth({
        authRequired: false,
        auth0Logout: false,
        idpLogout: true,
        baseURL: `https://${config.appName}.billandjessie.com`,
        clientID: config.authentikClientId,
        clientSecret: config.authentikClientSecret,
        issuerBaseURL: `${config.authentikBaseUrl}/application/o/${config.appName}`,
        secret: config.sessionSecret,
        routes: {
          callback: "/auth/callback",
        },
        authorizationParams: {
          response_type: "code",
          scope: "openid profile email",
        },
      }),
    );

    // Only enforced once real Authentik credentials are configured --
    // pre-onboarding (no client id/secret in SSM yet), the app stays open
    // rather than locking itself out before auth is even wired up.
    app.use((req, res, next) => {
      if (PUBLIC_PATHS.has(req.path) || req.oidc.isAuthenticated()) {
        return next();
      }
      if (req.path.startsWith("/api/")) {
        return res.status(401).json({ error: "authentication required" });
      }
      return res.redirect("/login");
    });
  } else {
    app.get("/login", (req, res) => res.status(501).json({ error: "auth not configured" }));
  }

  app.get("/db-check", async (req, res) => {
    res.json({ connected: await checkConnection() });
  });

  app.use(express.static(DIST_DIR));
  // SPA fallback -- any route not handled above (client-side routing, or
  // just "/") gets the built frontend's index.html.
  app.get("*", (req, res) => {
    res.sendFile(path.join(DIST_DIR, "index.html"));
  });

  return app;
}

// Cross-platform "run as main module" check -- comparing import.meta.url
// against a hand-built file:// string breaks on Windows, where argv[1] uses
// backslashes and no leading slash (e.g. C:\app\server\index.js), so it
// never matches the real file:///C:/app/server/index.js URL and listen()
// silently never runs. pathToFileURL normalizes both platforms correctly.
if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  createApp().listen(config.port, () => {
    console.log(`${config.appName} listening on :${config.port}`);
  });
}
