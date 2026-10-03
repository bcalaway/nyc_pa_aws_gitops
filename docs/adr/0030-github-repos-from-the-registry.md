# ADR-0030: GitHub Repositories Come From the Apps Registry

Date: 2026-10-03
Status: Accepted (2026-10-03, Bill: "make it easier" to create the many mkt-* repos)

## Context

The market data platform adds five to seven repos (ADR-0028). Each needs the same GitHub settings the existing app repos got by hand: a ruleset on `main` (PRs only, CI must pass, no force-push or deletion), a `production` environment with Bill as required reviewer (ADR-0025), a `preview` environment for apps with previews (ADR-0023), Dependabot security updates, secret scanning with push protection, CodeQL default setup, and an OIDC subject format the app's AWS roles trust. Claude's own GitHub token can't create repos, so each new repo also needed Bill.

ADR-0028 already made the registry drive every per-app AWS resource. The GitHub side was the remaining manual part, and the `github_repo_id` field existed only because new repos default to GitHub's immutable-ID OIDC subject.

## Options Considered

**Option A: A GitHub template repository** — copies files, not settings (rulesets, environments, security features).

**Option B: A setup script run per repo** — imperative; settings drift afterwards and nothing shows it.

**Option C: A GitHub organization** — org-wide rulesets, secrets and Actions policy, and GitHub Apps that can create repos. A much larger move (renamed repos, re-pointed OIDC trust, new billing scope) than the problem needs.

**Option D: Terraform's GitHub provider, driven by the registry (chosen)**

## Decision

A new Terraform stack, `terraform/github/`, reads `apps/registry.yml` and manages, per app: the repository and its merge/feature settings, the `main` ruleset, `production` (and `preview`) environments, vulnerability alerts and Dependabot security updates, secret scanning with push protection, and the OIDC subject claim format. The apply workflow also turns on CodeQL default setup, which the provider can't manage.

- **Separate stack and state** (`github/terraform.tfstate`, same bucket) and a separate workflow (`terraform-github.yml`). The GitHub admin token never exists in an AWS apply and AWS credentials here only reach the state object. It is also a first slice of ADR-0029's state split.
- **Tokens**: two fine-grained PATs scoped to all of Bill's repos, made once by Bill. An admin one (Administration, Environments, Actions write) as a `production` environment secret, so only applies he approves can use it. A read-only one as a repository secret for PR plans. Dependabot PRs get neither (GitHub withholds secrets), so a provider bump's plan needs a re-run from a normal PR.
- **New repos** are created with a README commit so `main` exists before the ruleset. The starter template arrives in the repo's first PR, a normal reviewed change that also fills in the app name, rather than as Terraform-managed files (one commit per file, fighting the ruleset).
- **OIDC subject**: new repos are set to the classic format (`repo:bcalaway/<name>:...`), which is all their AWS roles trust, so `github_repo_id` is no longer needed. todo-app and hue keep GitHub's default and their `github_repo_id`, so adopting them changes nothing.
  - **Superseded 2026-10-03 (mkt-data):** the `("repo", "context")` customization doesn't produce the classic subject. GitHub still sent `repo:bcalaway@37939549/mkt-data@1403692772:ref:refs/heads/...`, and mkt-data's first CD run was refused at "Configure AWS credentials". Every app now keeps GitHub's default subject and records `github_repo_id` in the registry, added in a follow-up PR once the GitHub apply has created the repo.
- **Adoption**: todo-app and hue were imported (`imports.tf`, removed once applied) with their current settings. The first plan (PR #86): 13 imports and 3 in-place updates. Two are on the repositories and only look like changes: the read-only plan token can't see merge settings (GitHub shows them to write-capable tokens), so they read as off; they're on, and the apply sends the same values. The third is real and deliberate: **todo-app's `production` environment had no required reviewer**, unlike hue's and contrary to ADR-0025, so its deploys went out on merge. Bill chose to gate it (2026-10-03). The platform repo itself stays manual: a stack that can rewrite its own repo's ruleset or `production` reviewer could lock out the workflow that fixes it.
- **Safety**: `prevent_destroy` and `archive_on_destroy` on repositories; removing an app from the registry never deletes a repo.

## Consequences

- A new app is one registry entry: both stacks plan its resources on the PR, and two approvals create everything. No `gh repo create`, no clicking through settings.
- Settings drift on managed repos shows up in the next plan.
- One setting isn't modelled by the provider: the ruleset's "require extra approval for unattributed changes" (on in all three existing rulesets). It survives as long as Terraform never rewrites a ruleset; a ruleset change in Terraform may turn it off.
- Merge settings (allowed merge methods, delete-branch-on-merge, merge commit titles) are set when a repo is created but not compared afterwards (`ignore_changes`): GitHub hides them from the read-only plan token, which made every PR plan show a phantom change. Drift in those few settings isn't detected. Likewise `secret_scanning_non_provider_patterns` is left at GitHub's default (disabled) because the provider doesn't read it back.
- Two long-lived PATs to rotate. Their expiry is GitHub's (fine-grained PATs expire); when one lapses, the plan or apply fails with an auth error naming it.
