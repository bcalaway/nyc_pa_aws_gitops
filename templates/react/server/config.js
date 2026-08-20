// APP_NAME must match this app's ECR repo / IAM role name / Postgres
// database name / Route53 subdomain -- one name ties the whole platform
// integration together, see docs/app-platform.md in nyc_pa_aws_gitops.
export const config = {
  appName: process.env.APP_NAME || "app",
  port: parseInt(process.env.PORT || "8000", 10),

  // Should come from SSM (/home-platform/<app>/session-secret) once deployed --
  // the default here is only for local dev/tests, never use it in production.
  sessionSecret: process.env.SESSION_SECRET || "dev-insecure-secret-change-me",

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
