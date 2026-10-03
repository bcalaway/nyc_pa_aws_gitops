# Per-app platform resources (ADR-0019), generated from the apps registry
# (ADR-0028, apps/registry.yml). Each app gets its own ECR repository and its
# own narrowly-scoped IAM role/OIDC trust condition -- never access added to
# the platform's own github_actions role (iam.tf). Adding an app is a
# registry entry, not a copied block here.
#
# Elsewhere driven by the same locals:
#   ci-roles.tf  <app>-deploy documents, preview documents/roles/repos
#   tls.tf       the hub role's per-app ECR-pull and SSM-read grants
#   iam.tf       the CI role's per-app IAM/ECR/SSM-document ARNs
#   security.tf  the Access Analyzer archive rule for the OIDC roles

locals {
  registry = yamldecode(file("${path.module}/../../apps/registry.yml"))

  # name => normalized entry, in registry order where order matters (see
  # app_names). Missing optional fields default here, so nothing below has
  # to guess.
  app_names = [for a in local.registry.apps : a.name]
  apps = { for a in local.registry.apps : a.name => {
    # Only repos created before terraform/github have one (ADR-0030).
    github_repo_id  = try(tostring(a.github_repo_id), "")
    database        = try(a.database, false)
    authentik       = try(a.authentik, false)
    preview         = try(a.preview, false)
    extra_ecr_repos = try(a.extra_ecr_repos, [])
    airflow         = try(a.airflow, false)
  } }

  preview_app_names  = [for n in local.app_names : n if local.apps[n].preview]
  database_app_names = [for n in local.app_names : n if local.apps[n].database]
  # Apps whose pipelines run on the shared Airflow (ADR-0031).
  airflow_app_names = [for n in local.app_names : n if local.apps[n].airflow]
  # Shared platform services' databases (registry platform_databases).
  platform_database_names = [for d in try(local.registry.platform_databases, []) : d.name]

  # Every production ECR repository: each app's own, plus its extras.
  app_ecr_repos = { for r in flatten([
    for n in local.app_names : concat([n], local.apps[n].extra_ecr_repos)
  ]) : r => r }

  # The repositories each app's CI pushes to (and the hub pulls from).
  app_repo_names = { for n in local.app_names : n => concat([n], local.apps[n].extra_ecr_repos) }

  # GitHub's numeric owner ID for bcalaway, for the immutable-ID OIDC subject.
  github_owner_id = "37939549"
}

# ---------------------------------------------------------------------------
# ECR repositories
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "app" {
  for_each = local.app_ecr_repos

  name = each.key
  # The CI role grants itself CreateRepository on this ARN in the same apply
  # (iam.tf); wait for that to propagate (ci-roles.tf).
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]
  # Mutable (the default) is required, not just tolerated -- ADR-0019's CD
  # step tags every push with both <git-sha> and `latest`, and `latest` has
  # to be overwritable on each push.
  tags = { Name = each.key }
}

# Preview images (ADR-0023) are tagged pr-<n>-<sha> and never `latest`;
# they expire 14 days after push. Production tags (<sha>, latest) are
# untouched: the rule only selects the pr- prefix. (Previews now push to
# <app>-preview instead -- ci-roles.tf -- so this only sweeps old pr- tags.)
resource "aws_ecr_lifecycle_policy" "app_pr_images" {
  for_each = toset(local.preview_app_names)

  repository = aws_ecr_repository.app[each.key].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire PR preview images after 14 days"
      selection = {
        tagStatus     = "tagged"
        tagPrefixList = ["pr-"]
        countType     = "sinceImagePushed"
        countUnit     = "days"
        countNumber   = 14
      }
      action = { type = "expire" }
    }]
  })
  # This role grants itself ecr:PutLifecyclePolicy in the same apply.
  depends_on = [aws_iam_role_policy.github_actions]
}

# ---------------------------------------------------------------------------
# <app>-github-actions: build-push on main, deploy in `production`
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "app_github_actions_assume" {
  for_each = local.apps

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type = "Federated"
      # Reuses the single GitHub OIDC provider already registered in this
      # account (iam.tf) -- one provider per account, trusted by many roles
      # each scoped to their own repo condition below.
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Two subject formats (local.repo_subjects, ci-roles.tf) -- confirmed via
    # CloudTrail 2026-07-26 that a newly-created repo's OIDC sub claim
    # defaults to GitHub's newer immutable-ID format
    # (repo:OWNER@OWNER_ID/REPO@REPO_ID:...), unlike nyc_pa_aws_gitops's own
    # github_actions role (iam.tf), which still gets plain repo:OWNER/REPO:....
    # Setting a classic-format customization doesn't change it (mkt-data,
    # 2026-10-03), so app roles trust the immutable form via the registry's
    # github_repo_id, plus the classic form. Milestone 20 (ADR-0025): build-push runs on `main`, deploy
    # in the approval-gated `production` environment. Pull requests
    # (previews) use <app>-github-preview instead (ci-roles.tf).
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([for s in local.repo_subjects[each.key] : [
        "${s}:ref:refs/heads/main",
        "${s}:environment:production",
      ]])
    }
  }
}

resource "aws_iam_role" "app_github_actions" {
  for_each = local.apps

  name               = "${each.key}-github-actions"
  assume_role_policy = data.aws_iam_policy_document.app_github_actions_assume[each.key].json
  # Same as the ECR repos: the CI role's iam:CreateRole grant on this ARN
  # lands in the same apply (ci-roles.tf's time_sleep).
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  tags = { Name = "${each.key}-github-actions" }

  lifecycle {
    precondition {
      condition     = can(regex("^[a-z][a-z0-9-]{1,30}[a-z0-9]$", each.key))
      error_message = "apps/registry.yml: app name \"${each.key}\" must be lowercase letters, digits and hyphens (3-32 chars)."
    }
    precondition {
      condition     = can(regex("^[0-9]*$", each.value.github_repo_id))
      error_message = "apps/registry.yml: ${each.key}'s github_repo_id, when set, must be the numeric repo ID."
    }
  }
}

data "aws_iam_policy_document" "app_github_actions_permissions" {
  for_each = local.apps

  # ECR auth -- GetAuthorizationToken doesn't support resource-level scoping
  # (same class of API as ssm:DescribeParameters/dlm:TagResource elsewhere
  # in this repo); every other ECR action below is scoped to this app's own
  # repositories only.
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
      "ecr:PutImage", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload",
      "ecr:DescribeRepositories", "ecr:ListImages",
    ]
    resources = [for r in local.app_repo_names[each.key] : aws_ecr_repository.app[r].arn]
  }

  # No SSM parameter access (Milestone 20, ADR-0025): the hub reads this
  # app's secrets itself when the <app>-deploy document runs, with its own
  # role (tls.tf's hub_app_deploy).
  #
  # Deploy staging -- reuses the ansible-deploy bucket (s3.tf) under an
  # apps/<app>/ prefix, the same "stage an artifact, hub pulls it down"
  # pattern as the RouterOS/NUC pipeline. The hub's instance role already
  # reads the whole bucket (tls.tf's hub_ansible_deploy_read); this write
  # grant is scoped to the app's own prefix only.
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::home-platform-ansible-deploy-${var.aws_account_id}/apps/${each.key}/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::home-platform-ansible-deploy-${var.aws_account_id}"]
  }

  # Deploy triggering -- SSM Run Command on the hub: DescribeInstances can't
  # be resource-scoped (EC2's Describe* actions don't support it), SendCommand
  # needs both the hub instance (here) and a document -- only this app's own
  # <app>-deploy document (the _documents policy below) -- and the Get/List
  # actions can't be resource-scoped either (identified by command-id).
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = [aws_instance.hub.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations", "ssm:ListCommands"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "app_github_actions_documents" {
  for_each = local.apps

  name   = "${each.key}-github-actions-documents"
  role   = aws_iam_role.app_github_actions[each.key].id
  policy = data.aws_iam_policy_document.app_deploy_document[each.key].json
}

resource "aws_iam_role_policy" "app_github_actions" {
  for_each = local.apps

  name   = "${each.key}-github-actions"
  role   = aws_iam_role.app_github_actions[each.key].id
  policy = data.aws_iam_policy_document.app_github_actions_permissions[each.key].json
}

# ---------------------------------------------------------------------------
# Migration from the hand-written per-app blocks (ADR-0028). State moves
# only -- nothing is destroyed or recreated. Safe to delete once applied.
# ---------------------------------------------------------------------------

moved {
  from = aws_ecr_repository.todo_app
  to   = aws_ecr_repository.app["todo-app"]
}

moved {
  from = aws_ecr_repository.hue
  to   = aws_ecr_repository.app["hue"]
}

moved {
  from = aws_ecr_repository.hue_agent
  to   = aws_ecr_repository.app["hue-agent"]
}

moved {
  from = aws_ecr_lifecycle_policy.todo_app_previews
  to   = aws_ecr_lifecycle_policy.app_pr_images["todo-app"]
}

moved {
  from = aws_iam_role.todo_app_github_actions
  to   = aws_iam_role.app_github_actions["todo-app"]
}

moved {
  from = aws_iam_role.hue_github_actions
  to   = aws_iam_role.app_github_actions["hue"]
}

moved {
  from = aws_iam_role_policy.todo_app_github_actions
  to   = aws_iam_role_policy.app_github_actions["todo-app"]
}

moved {
  from = aws_iam_role_policy.hue_github_actions
  to   = aws_iam_role_policy.app_github_actions["hue"]
}

moved {
  from = aws_iam_role_policy.todo_app_github_actions_documents
  to   = aws_iam_role_policy.app_github_actions_documents["todo-app"]
}

moved {
  from = aws_iam_role_policy.hue_github_actions_documents
  to   = aws_iam_role_policy.app_github_actions_documents["hue"]
}
