# ADR-0032: One Platform Release Behind One Approval; App Deploys Without Approval

Date: 2026-10-04
Status: Accepted (2026-10-04, Bill)

## Context

A merge to this repo could start three gated workflows at once: Terraform (AWS), Terraform (GitHub) and Platform deploy. Each waited for its own `production` approval, and they ran in whatever order Bill approved them. Order matters:

- A hub deploy that needs a new IAM grant has to run after the AWS apply (#115: the hub script ran first and silently saved `none` as Grafana's token; docs/gotchas.md).
- Onboarding an app (calendar-svc, #126) took three approvals in a set order, plus one more for the app's first CD.

App CDs also waited for approval on every merge, though the merge itself is Bill's review.

## Decision

1. **One workflow, `platform-release.yml`, for everything a merge to main deploys here.** A "What changed" job works out the scope; one job in the `production` environment then waits for one approval and runs, in order and only where needed: Terraform (AWS), Terraform (GitHub) and its CodeQL setup, app database onboarding, the hub stack, the NUCs. The first failure stops the rest. Its manual run takes a target (hub, nucs, both, app-dbs, terraform-aws, terraform-github, everything).
   - One job, not a workflow calling the others: GitHub asks for approval per job that targets `production`, so chained jobs would still prompt once each.
   - `terraform.yml` and `terraform-github.yml` keep the PR plans; their apply jobs are gone. `platform-deploy.yml` is gone.
   - The hub helper and the apply-and-summarize logic live in `.github/scripts/` (`run-on-hub.sh`, `terraform-apply.sh`), so each step still ends with the `result` annotation home-mcp's `last_deploys` reads.
   - Same concurrency group as before (`platform-deploy`), shared with voice jobs and the preview sweep.
2. **App deploys don't wait for approval.** Every registry app's `production` environment loses its required reviewer and gains a deployment branch policy: protected branches only. An app is live minutes after its PR merges.

RouterOS keeps its own gated workflow.

## Consequences

- One tap per platform merge, and the order is fixed: no more "approve Terraform first".
- A new app still needs its platform release before its own first deploy (two repos, two workflows). That happens once per app.
- A failed step means a re-run of the whole release job, which re-applies Terraform (a no-op if nothing changed) before retrying the hub. The manual targets allow a narrower re-run.
- The apps' AWS roles trust `environment:production` (ADR-0025). Without a reviewer, the branch policy is the control that keeps a workflow on another branch from getting that token. It must stay.
- App code reaches the hub on merge with no second look. The review is the PR; CI (build, test, lint) is still required on `main`.
- This supersedes the per-workflow approvals in ADR-0019 and ADR-0025 and the "approve Terraform first" advice in docs/gotchas.md.
