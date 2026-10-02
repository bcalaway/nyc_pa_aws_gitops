# ADR-0025: Split GitHub Actions AWS Roles; Fixed Hub Documents; SSM Secrets Out of Terraform State (Milestone 20)

Date: 2026-10-02
Status: Accepted (2026-10-02, Bill chose the "full fix")

## Context

IAM Access Analyzer (ADR-0024's `aws_posture`) flagged the three GitHub OIDC roles. Looking closer:

- **Trust was per repo, not per job.** Each role trusted `repo:<owner>/<repo>:*`, so any branch or pull request (Dependabot's included) got the full deploy role. The platform role can change EC2, IAM, S3 and Route 53.
- **The platform role could read every secret.** Terraform managed 21 `/home-platform/*` SSM parameters (created as placeholders with `ignore_changes`), so refresh stored their **real values in the state file**. Anything that could read state could read the WireGuard hub key, router and switch passwords, the GitHub token and the Ansible SSH key. So could anything holding the platform role, which also had `ssm:GetParameter` on `/home-platform/*`.
- **App roles were root on the hub.** `todo-app-github-actions` and `hue-github-actions` could `ssm:SendCommand` with `AWS-RunShellScript` on the hub. That runs any command as root, so the hub role's secrets and every other app were in reach. Previews (ADR-0023) ran from pull requests with these same roles.
- **Previews trusted the runner.** The preview Compose file was sanitized on the GitHub runner, and the hub ran whatever was staged.

Only Bill, Dependabot and Claude's session can push branches to these repos, so this was hardening, not an open hole. But one leaked token or malicious dependency in a PR job would have been enough.

## Decision

**Roles by job, not by repo** (`terraform/aws/iam.tf`, `apps.tf`, `ci-roles.tf`):

| Role | Trusted subjects | Can |
|---|---|---|
| `home-platform-github-actions` | platform `environment:production`, `ref:refs/heads/main` | Terraform apply, platform/RouterOS/voice deploys, portal, scheduled jobs. **No SSM parameter access** |
| `home-platform-github-plan` | platform `pull_request` | read the state object, describe/get/list. No writes, no secrets, no lock (`plan -lock=false`) |
| `<app>-github-actions` | app `ref:refs/heads/main`, `environment:production` | push its own ECR repo, stage under `apps/<app>/`, run **only** `<app>-deploy` |
| `todo-app-github-preview` | todo-app `pull_request`, `environment:preview` | push `todo-app-preview` only, stage under `apps/todo-app/previews/`, run only `todo-app-preview-up` / `-down` |

App trusts list both subject formats (`repo:bcalaway/<app>` and the immutable-ID form). All `sub` conditions are `StringEquals`.

**Fixed SSM Command documents replace `AWS-RunShellScript`** for the apps. Each document embeds a script from `scripts/hub/` base64-encoded, so Terraform owns exactly what runs as root. A caller can pass only declared parameters, each with an `allowedPattern`:

- `<app>-deploy` — `app-deploy.sh` (no parameters; the app name is fixed per document)
- `todo-app-preview-up` — `preview-up.sh` + `preview-compose.py`; `pr` (`^[0-9]{1,6}$`), `tag` (`^pr-[0-9]{1,6}-[0-9a-f]{12}$`)
- `todo-app-preview-down` — `preview-down.sh`; `pr`

Workflows call them through `scripts/hub/run-document.sh`. The platform role keeps `AWS-RunShellScript` (platform deploys and RouterOS run behind `production` approval; voice jobs are validated against `voice-jobs/`).

**The hub re-checks previews.** `preview-compose.py` is now an allowlist of Compose keys (no `privileged`, `volumes`, `ports`, `network_mode`, `devices`, `cap_add`, ...). `preview-up.sh` re-runs it on the hub with `--strict`, which also requires the routed service to run exactly the image built for that PR. Preview images live in their own ECR repository (`todo-app-preview`, expires after 14 days), so a PR can never overwrite a production tag.

**SSM parameters leave Terraform.** `ssm.tf` is now 21 `removed { lifecycle { destroy = false } }` blocks. The parameters are untouched and are managed by hand like every other `/home-platform/*` parameter (`docs/ssm-parameters.md`).

**Access Analyzer**: an archive rule (`security.tf`) archives findings on the five OIDC roles **whose principal is the GitHub OIDC provider**. Any other external access to them still shows in `aws_posture`.

## Rollout

Three PRs, each safe on its own:

1. **#61 (AWS):** new roles, documents and ECR repo; state removals; the platform role keeps `pull_request` trust so PR plans keep working.
2. **#62 (workflows):** PR plans use the plan role; app deploys and previews use the documents.
3. **This PR (lockdown):** remove `AWS-RunShellScript` and direct SSM reads from the app roles, narrow app trust, drop `pull_request` from the platform role, add the archive rule.

## Consequences

- A pull request in any repo can no longer change AWS or read a secret. The worst a malicious PR can do is run a preview, which is already contained (ADR-0023), now with its image pinned.
- Merged code still runs on the hub with the hub role. That's what deploying is; it goes through Bill's `production` approval.
- The 21 parameters are no longer created by Terraform. A rebuilt account would need them created by hand (they always needed real values put by hand anyway).
- **Old state versions still hold the secret values.** The state bucket is versioned. Noncurrent versions from before #61 contain them, readable by anyone with `s3:GetObjectVersion` on the bucket (today, only account admins). Expire or delete them, or rotate the secrets over time.
- Terraform PR plans can't take the state lock. Two plans can overlap harmlessly; applies still lock.
- A second previewed app needs its own `<app>-github-preview` role and `<app>-preview` repository: add it to `local.preview_apps` and repeat the role block in `ci-roles.tf`.
- Changing a hub script that is bundled into a document (`app-deploy.sh`, `preview-*.sh`, `preview-compose.py`) is a Terraform change. `terraform.yml` triggers on those paths.
