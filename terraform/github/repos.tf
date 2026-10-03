locals {
  registry = yamldecode(file("${path.module}/../../apps/registry.yml"))

  # Registry order kept for readability; resources are keyed by name.
  apps = { for a in local.registry.apps : a.name => {
    preview = try(a.preview, false)
    # Repos created before this stack still use GitHub's default OIDC subject
    # (immutable IDs) and list github_repo_id in the registry; repos created
    # here get the classic subject (repo:bcalaway/<name>:...), which is all
    # their AWS roles trust (terraform/aws/ci-roles.tf, repo_subjects).
    legacy_oidc = try(a.github_repo_id, null) != null
    # The CI check a PR must pass: the template's caller job is `ci`.
    required_check        = try(a.required_check, "ci / Build, test, lint")
    required_check_app_id = try(a.required_check_app_id, null)
    ruleset_name          = try(a.ruleset_name, "protect-main")
  } }

  preview_apps = { for n, a in local.apps : n => a if a.preview }
}

# Bill, the required reviewer for every `production` environment.
data "github_user" "owner" {
  username = "bcalaway"
}

resource "github_repository" "app" {
  for_each = local.apps

  name       = each.key
  visibility = "public"

  # New repos start with a README commit so `main` exists before the ruleset
  # below; the template arrives in the repo's first PR (ADR-0030).
  auto_init = true

  has_issues      = true
  has_projects    = true
  has_wiki        = true
  has_discussions = false

  allow_merge_commit     = true
  allow_squash_merge     = true
  allow_rebase_merge     = true
  allow_auto_merge       = false
  allow_update_branch    = false
  delete_branch_on_merge = true

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
    secret_scanning_non_provider_patterns {
      status = "disabled"
    }
  }

  # Removing an app from the registry never deletes its repo or history.
  archive_on_destroy = true

  lifecycle {
    prevent_destroy = true
    # Set at creation only; the first PR brings the real content.
    ignore_changes = [auto_init]
  }
}

resource "github_repository_vulnerability_alerts" "app" {
  for_each = local.apps

  repository = github_repository.app[each.key].name
  enabled    = true
}

resource "github_repository_dependabot_security_updates" "app" {
  for_each   = local.apps
  depends_on = [github_repository_vulnerability_alerts.app]

  repository = github_repository.app[each.key].name
  enabled    = true
}

# main: changes only through a PR that passes CI; no force-push or deletion.
# Approvals aren't required (Bill is the only reviewer and merges his own).
resource "github_repository_ruleset" "main" {
  for_each = local.apps

  repository  = github_repository.app[each.key].name
  name        = each.value.ruleset_name
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    deletion         = true
    non_fast_forward = true

    pull_request {
      allowed_merge_methods             = ["merge", "squash", "rebase"]
      dismiss_stale_reviews_on_push     = false
      require_code_owner_review         = false
      require_last_push_approval        = false
      required_approving_review_count   = 0
      required_review_thread_resolution = false
    }

    required_status_checks {
      strict_required_status_checks_policy = false
      do_not_enforce_on_create             = false

      required_check {
        context        = each.value.required_check
        integration_id = each.value.required_check_app_id
      }
    }
  }
}

# Deploys (app-deploy.yml) wait here for Bill's approval (ADR-0025).
resource "github_repository_environment" "production" {
  for_each = local.apps

  repository          = github_repository.app[each.key].name
  environment         = "production"
  can_admins_bypass   = true
  prevent_self_review = false

  reviewers {
    users = [data.github_user.owner.id]
  }
}

# PR previews (ADR-0023): no approval, deploys run as soon as a PR builds.
resource "github_repository_environment" "preview" {
  for_each = local.preview_apps

  repository  = github_repository.app[each.key].name
  environment = "preview"
}

# OIDC subject format: classic for repos created here, GitHub's default left
# alone for the older ones (see legacy_oidc above).
resource "github_actions_repository_oidc_subject_claim_customization_template" "app" {
  for_each = local.apps

  repository         = github_repository.app[each.key].name
  use_default        = each.value.legacy_oidc
  include_claim_keys = each.value.legacy_oidc ? null : ["repo", "context"]
}
