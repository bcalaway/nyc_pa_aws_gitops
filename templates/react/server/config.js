import crypto from "node:crypto";

// APP_NAME must match this app's ECR repo / IAM role name / Postgres
// database name / Route53 subdomain -- one name ties the whole platform
// integration together, see docs/app-platform.md in nyc_pa_aws_gitops.
export const config = {
  appName: process.env.APP_NAME || "app",
  // The hostname browsers use, for OIDC redirects: <app>.billandjessie.com
  // unless deploy/docker-compose.yml sets PUBLIC_HOST (mkt-ui is served at
  // mkt.billandjessie.com).
  publicHost: process.env.PUBLIC_HOST || `${process.env.APP_NAME || "app"}.billandjessie.com`,
  port: parseInt(process.env.PORT || "8000", 10),

  // Signs the login session cookie. SESSION_SECRET (SSM
  // /home-platform/<app>/session-secret) wins if set; otherwise it's derived
  // from the Authentik client secret, which only this app and Authentik
  // hold, so no extra parameter is needed. The dev
  // default is used only when login is off (local runs and tests).
  sessionSecret: sessionSecret(),

  // Postgres (ADR-0016). POSTGRES_PASSWORD arrives via the platform's
  // deploy-time .env convention -- unset locally means db-dependent
  // features degrade gracefully instead of crashing (see server/db.js).
  postgresHost: process.env.POSTGRES_HOST || "postgres",
  postgresPassword: process.env.POSTGRES_PASSWORD || null,

  // Authentik OIDC (ADR-0017, Pattern A). Both unset means auth stays off
  // entirely (app runs fully open) -- lets this template run standalone
  // before an app is actually onboarded to Authentik.
  authentikBaseUrl: process.env.AUTHENTIK_BASE_URL || "https://auth.billandjessie.com",
  authentikClientId: process.env.AUTHENTIK_CLIENT_ID || null,
  authentikClientSecret: process.env.AUTHENTIK_CLIENT_SECRET || null,
};

function sessionSecret() {
  if (process.env.SESSION_SECRET) return process.env.SESSION_SECRET;
  if (process.env.AUTHENTIK_CLIENT_SECRET) {
    return crypto.createHmac("sha256", process.env.AUTHENTIK_CLIENT_SECRET).update("session cookie").digest("hex");
  }
  return "dev-insecure-secret-change-me";
}
