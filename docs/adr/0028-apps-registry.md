# ADR-0028: A Single Apps Registry Drives Per-App Platform Resources

Date: 2026-10-03
Status: Accepted (2026-10-03)

## Context

Onboarding an app (ADR-0019, ADR-0023, ADR-0025) touches several places by hand:

- an ECR repository, OIDC role, `<app>-deploy` SSM document and S3 staging prefix, as a copied block in `terraform/aws/apps.tf` / `ci-roles.tf`
- for previews, `local.preview_apps`, a second role and a `<app>-preview` ECR repo
- a Postgres database and role, created with manual SQL against the live instance (`docs/app-platform.md`, Database), and its password in SSM
- optionally Authentik client credentials in SSM

Two apps exist today (todo-app, hue). The market data platform alone adds five to seven repos (mkt-data, secmaster-svc, quote-svc, mkt-api, mkt-ui, later mkt-analytics and analytics-svc). Copying blocks and running SQL by hand for each is slow and error-prone.

## Options Considered

**Option A: Keep copying blocks**
- No new mechanism; already understood
- Scales poorly, and drift between copies is likely

**Option B: A registry file plus Terraform `for_each`, and automated database onboarding (chosen)**
- One place lists every app and what it needs; Terraform creates the AWS side from it
- Database onboarding becomes an idempotent script run by the platform deploy, not manual SQL

**Option C: A separate "platform-apps" repo or service catalog**
- More moving parts than the problem needs

## Decision

Add `apps/registry.yml` to this repo:

```yaml
apps:
  - name: todo-app
    github_repo_id: 1313063209
    database: true
    authentik: true
    preview: true
  - name: mkt-data
    github_repo_id: <id>
    database: true
    preview: false
```

*Implementation note (2026-10-03):* a list rather than the map first sketched here, because the Access Analyzer archive rule's role list is order-sensitive and a map would reorder it alphabetically; `github_repo_id` was added for GitHub's immutable-ID OIDC subject. Field reference is in the file's header. `grpc` waits for the Python template's gRPC work.

- **Terraform** reads it with `yamldecode()` and creates the ECR repo, OIDC role, deploy document and staging prefix per app via `for_each`, plus the preview resources where `preview: true`. Existing hand-written blocks move into this form with `moved {}` blocks, so nothing is destroyed or recreated.
- **Database onboarding**: a hub script (run by `platform-deploy.yml`, behind `production` approval) creates any missing database and role, sets ownership (including the Postgres 15+ `public` schema step), generates the password into `/home-platform/postgres/<app>-password` if absent, and verifies with a real `CREATE TABLE`/`DROP TABLE`. It never drops anything.
- **Docs**: the onboarding checklist in `docs/app-platform.md` becomes "add a registry entry, merge, approve".

## Consequences

- Adding an app becomes a small PR to this repo.
- The migration of todo-app and hue must be a no-op plan; verify with `terraform plan` showing only moves.
- The hub script gains the ability to create roles and write SSM parameters, so it runs only in the approved platform deploy, never from an app role (ADR-0025).
- Removing an app stays a deliberate manual step.
