# One-time adoption of the repos that existed before this stack (ADR-0030).
# The first apply should import these with no changes; delete this file in
# any later PR once it has.

locals {
  existing_repos = ["todo-app", "hue"]
  existing_rulesets = {
    "todo-app" = 24259194 # "main-protection"
    "hue"      = 24265295 # "protect-main"
  }
}

import {
  for_each = toset(local.existing_repos)
  to       = github_repository.app[each.key]
  id       = each.key
}

import {
  for_each = toset(local.existing_repos)
  to       = github_repository_vulnerability_alerts.app[each.key]
  id       = each.key
}

import {
  for_each = toset(local.existing_repos)
  to       = github_repository_dependabot_security_updates.app[each.key]
  id       = each.key
}

import {
  for_each = local.existing_rulesets
  to       = github_repository_ruleset.main[each.key]
  id       = "${each.key}:${each.value}"
}

import {
  for_each = toset(local.existing_repos)
  to       = github_repository_environment.production[each.key]
  id       = "${each.key}:production"
}

import {
  to = github_repository_environment.preview["todo-app"]
  id = "todo-app:preview"
}

import {
  for_each = toset(local.existing_repos)
  to       = github_actions_repository_oidc_subject_claim_customization_template.app[each.key]
  id       = each.key
}
