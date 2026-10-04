# Milestone 20 (ADR-0025): who in GitHub Actions can do what in AWS.
#
#   home-platform-github-actions  production deploys + main (iam.tf)   can change AWS
#   home-platform-github-plan     platform-repo pull requests          read-only, PR plans
#   <app>-github-actions          app main + production deploys        build, push, run <app>-deploy
#   <app>-github-preview          app pull requests + `preview`        preview images, run preview docs
#
# Which apps get which is apps/registry.yml (ADR-0028, locals in apps.tf).
#
# The hub runs app work only through fixed SSM documents below: the script
# lives here (from scripts/hub/), and a workflow can pass only the few
# validated parameters each document declares. Replaces AWS-RunShellScript,
# which let any holder of an app role run anything as root on the hub.

locals {
  deploy_bucket = aws_s3_bucket.ansible_deploy.bucket
  ci_apps       = local.app_names
  preview_apps  = local.preview_app_names
  # App repos' OIDC subject is GitHub's immutable-ID form
  # (repo:bcalaway@<owner id>/<name>@<repo id>:...), trusted once the app's
  # github_repo_id is in the registry. A ("repo", "context") customization
  # does NOT turn it back into the classic form: tried for mkt-data
  # (ADR-0030, PR #93) and its first CD run was refused. The classic form
  # stays trusted too; the platform repo itself still sends it.
  repo_subjects = merge(
    { for n, a in local.apps : n => concat(
      ["repo:${var.github_org}/${n}"],
      a.github_repo_id != "" ? ["repo:${var.github_org}@${local.github_owner_id}/${n}@${a.github_repo_id}"] : [],
    ) },
    { "nyc_pa_aws_gitops" = ["repo:${var.github_org}/${var.github_repo}"] },
  )

  # One SSM Command document: write the bundled scripts to a private temp
  # dir, run the entry script with the arguments, clean up, keep the exit
  # code. Scripts travel base64-encoded so nothing in them can be mistaken
  # for an SSM {{ parameter }}.
  hub_scripts = {
    "app-deploy.sh"        = filebase64("${path.module}/../../scripts/hub/app-deploy.sh")
    "app-dags.py"          = filebase64("${path.module}/../../scripts/hub/app-dags.py")
    "compose-mem-check.py" = filebase64("${path.module}/../../scripts/hub/compose-mem-check.py")
    "preview-up.sh"        = filebase64("${path.module}/../../scripts/hub/preview-up.sh")
    "preview-compose.py"   = filebase64("${path.module}/../../scripts/hub/preview-compose.py")
    "preview-down.sh"      = filebase64("${path.module}/../../scripts/hub/preview-down.sh")
    "capture-export.sh"    = filebase64("${path.module}/../../scripts/hub/capture-export.sh")
  }
}

# Time for the CI role's new permissions (iam.tf) to propagate before it
# creates the resources below -- same pattern as backup.tf / security.tf.
# The triggers re-run the wait whenever the registry's app or ECR repo list
# changes: the CI role grants itself per-app ARNs (iam.tf) in the same apply
# that creates the new app's ECR repo and roles, and a time_sleep only waits
# when it is (re)created. Without them, adding mkt-data (PR #93) raced the
# grant and failed with AccessDenied on ecr:CreateRepository until a re-run.
resource "time_sleep" "wait_for_github_actions_m20_policy" {
  depends_on      = [aws_iam_role_policy.github_actions]
  create_duration = "15s"
  triggers = {
    apps      = join(",", local.app_names)
    ecr_repos = join(",", sort(keys(local.app_ecr_repos)))
    previews  = join(",", local.preview_app_names)
  }
}

# ---------------------------------------------------------------- documents

resource "aws_ssm_document" "app_deploy" {
  for_each   = toset(local.ci_apps)
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name            = "${each.key}-deploy"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Deploy ${each.key} on the hub from its staged Compose file (scripts/hub/app-deploy.sh)"
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "deploy"
      inputs = {
        timeoutSeconds = "900"
        runCommand = [
          "d=$(mktemp -d) && chmod 700 \"$d\"",
          "echo ${local.hub_scripts["app-deploy.sh"]} | base64 -d > \"$d/app-deploy.sh\"",
          "echo ${local.hub_scripts["compose-mem-check.py"]} | base64 -d > \"$d/compose-mem-check.py\"",
          "echo ${local.hub_scripts["app-dags.py"]} | base64 -d > \"$d/app-dags.py\"",
          "bash \"$d/app-deploy.sh\" ${local.deploy_bucket} ${each.key}; rc=$?",
          "rm -rf \"$d\"; exit $rc",
        ]
      }
    }]
  })

  tags = { Name = "${each.key}-deploy" }
}

resource "aws_ssm_document" "preview_up" {
  for_each   = toset(local.preview_apps)
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name            = "${each.key}-preview-up"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Bring up one ${each.key} PR preview; re-checks the staged Compose file on the hub (ADR-0023, ADR-0025)"
    parameters = {
      pr  = { type = "String", description = "Pull request number", allowedPattern = "^[0-9]{1,6}$" }
      tag = { type = "String", description = "Preview image tag", allowedPattern = "^pr-[0-9]{1,6}-[0-9a-f]{12}$" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "previewUp"
      inputs = {
        timeoutSeconds = "1200"
        runCommand = [
          "d=$(mktemp -d) && chmod 700 \"$d\"",
          "echo ${local.hub_scripts["preview-up.sh"]} | base64 -d > \"$d/preview-up.sh\"",
          "echo ${local.hub_scripts["preview-compose.py"]} | base64 -d > \"$d/preview-compose.py\"",
          "bash \"$d/preview-up.sh\" ${local.deploy_bucket} ${each.key} ${each.key} '{{ pr }}' '{{ tag }}'; rc=$?",
          "rm -rf \"$d\"; exit $rc",
        ]
      }
    }]
  })

  tags = { Name = "${each.key}-preview-up" }
}

resource "aws_ssm_document" "preview_down" {
  for_each   = toset(local.preview_apps)
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name            = "${each.key}-preview-down"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Remove one ${each.key} PR preview (scripts/hub/preview-down.sh)"
    parameters = {
      pr = { type = "String", description = "Pull request number", allowedPattern = "^[0-9]{1,6}$" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "previewDown"
      inputs = {
        timeoutSeconds = "600"
        runCommand = [
          "d=$(mktemp -d) && chmod 700 \"$d\"",
          "echo ${local.hub_scripts["preview-down.sh"]} | base64 -d > \"$d/preview-down.sh\"",
          "bash \"$d/preview-down.sh\" ${each.key} '{{ pr }}'; rc=$?",
          "rm -rf \"$d\"; exit $rc",
        ]
      }
    }]
  })

  tags = { Name = "${each.key}-preview-down" }
}

# Export one raw capture to the deploy bucket (scripts/hub/capture-export.sh),
# for apps with `capture_export: true`. The app's own workflow starts it from
# `main` (no approval: it only reads), downloads the result and commits it to
# a capture/<id> branch, so Claude can fetch captures with git (2026-10-04).
resource "aws_ssm_document" "capture_export" {
  for_each   = toset(local.capture_export_app_names)
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name            = "${each.key}-capture-export"
  document_type   = "Command"
  document_format = "JSON"
  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Copy one ${each.key} raw capture to s3://${local.deploy_bucket}/apps/${each.key}/exports/ (scripts/hub/capture-export.sh)"
    parameters = {
      captureId = { type = "String", description = "Capture id", allowedPattern = "^[0-9]{1,9}$" }
    }
    mainSteps = [{
      action = "aws:runShellScript"
      name   = "captureExport"
      inputs = {
        timeoutSeconds = "300"
        runCommand = [
          "d=$(mktemp -d) && chmod 700 \"$d\"",
          "echo ${local.hub_scripts["capture-export.sh"]} | base64 -d > \"$d/capture-export.sh\"",
          "bash \"$d/capture-export.sh\" ${local.deploy_bucket} ${each.key} '{{ captureId }}'; rc=$?",
          "rm -rf \"$d\"; exit $rc",
        ]
      }
    }]
  })

  tags = { Name = "${each.key}-capture-export" }
}

# Permission for each app's deploy role to run its own deploy document, and
# its capture-export document if it has one.
data "aws_iam_policy_document" "app_deploy_document" {
  for_each = toset(local.ci_apps)

  statement {
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = concat(
      [aws_ssm_document.app_deploy[each.key].arn, aws_instance.hub.arn],
      contains(local.capture_export_app_names, each.key) ? [aws_ssm_document.capture_export[each.key].arn] : [],
    )
  }
}

# ---------------------------------------------------------------- previews

# Preview images get their own repository, so a role usable from a pull
# request can never overwrite a production image tag.
resource "aws_ecr_repository" "app_preview" {
  for_each   = toset(local.preview_apps)
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name = "${each.key}-preview"
  tags = { Name = "${each.key}-preview" }
}

resource "aws_ecr_lifecycle_policy" "app_preview" {
  for_each = toset(local.preview_apps)

  repository = aws_ecr_repository.app_preview[each.key].name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Expire preview images after 14 days"
      selection = {
        tagStatus   = "any"
        countType   = "sinceImagePushed"
        countUnit   = "days"
        countNumber = 14
      }
      action = { type = "expire" }
    }]
  })
}

data "aws_iam_policy_document" "app_preview_assume" {
  for_each = toset(local.preview_apps)

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # app-preview.yml's build/down jobs run as plain pull_request; its
    # deploy job runs in the `preview` environment.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values = flatten([for s in local.repo_subjects[each.key] : [
        "${s}:pull_request",
        "${s}:environment:preview",
      ]])
    }
  }
}

resource "aws_iam_role" "app_preview" {
  for_each   = toset(local.preview_apps)
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name               = "${each.key}-github-preview"
  assume_role_policy = data.aws_iam_policy_document.app_preview_assume[each.key].json

  tags = { Name = "${each.key}-github-preview" }
}

data "aws_iam_policy_document" "app_preview_permissions" {
  for_each = toset(local.preview_apps)

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
    ]
    resources = [aws_ecr_repository.app_preview[each.key].arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.ansible_deploy.arn}/apps/${each.key}/previews/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    effect  = "Allow"
    actions = ["ssm:SendCommand"]
    resources = [
      aws_ssm_document.preview_up[each.key].arn,
      aws_ssm_document.preview_down[each.key].arn,
      aws_instance.hub.arn,
    ]
  }

  # Reading back a command's result; these actions can't be resource-scoped.
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "app_preview" {
  for_each = toset(local.preview_apps)

  name   = "${each.key}-github-preview"
  role   = aws_iam_role.app_preview[each.key].id
  policy = data.aws_iam_policy_document.app_preview_permissions[each.key].json
}

# Migration from the hand-written todo-app preview blocks (ADR-0028).
moved {
  from = aws_ecr_repository.todo_app_preview
  to   = aws_ecr_repository.app_preview["todo-app"]
}

moved {
  from = aws_ecr_lifecycle_policy.todo_app_preview
  to   = aws_ecr_lifecycle_policy.app_preview["todo-app"]
}

moved {
  from = aws_iam_role.todo_app_preview
  to   = aws_iam_role.app_preview["todo-app"]
}

moved {
  from = aws_iam_role_policy.todo_app_preview
  to   = aws_iam_role_policy.app_preview["todo-app"]
}

# ---------------------------------------------------------------- PR plans

data "aws_iam_policy_document" "github_plan_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:pull_request"]
    }
  }
}

resource "aws_iam_role" "github_plan" {
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name               = "home-platform-github-plan"
  assume_role_policy = data.aws_iam_policy_document.github_plan_assume.json

  tags = { Name = "home-platform-github-plan" }
}

# Exactly what `terraform plan -lock=false` needs to refresh this config:
# describe/get/list on the resource types in terraform/aws, and the state
# object itself. No writes anywhere, no object reads beyond the state file,
# no SSM parameters, no KMS.
data "aws_iam_policy_document" "github_plan_permissions" {
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject"]
    resources = [
      "arn:aws:s3:::home-platform-terraform-state-${var.aws_account_id}/aws/terraform.tfstate",
      # terraform/github's state (ADR-0030), for its PR plans.
      "arn:aws:s3:::home-platform-terraform-state-${var.aws_account_id}/github/terraform.tfstate",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket", "s3:GetBucket*", "s3:GetEncryptionConfiguration", "s3:GetLifecycleConfiguration",
      "s3:GetAccelerateConfiguration", "s3:GetReplicationConfiguration", "s3:GetObjectLockConfiguration",
      "s3:GetIntelligentTieringConfiguration", "s3:GetAnalyticsConfiguration", "s3:GetInventoryConfiguration",
      "s3:GetMetricsConfiguration",
    ]
    resources = [
      "arn:aws:s3:::home-platform-terraform-state-${var.aws_account_id}",
      aws_s3_bucket.ansible_deploy.arn,
      "arn:aws:s3:::home-platform-logs-${var.aws_account_id}",
      "arn:aws:s3:::home-platform-portal-${var.aws_account_id}",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "iam:Get*", "iam:List*",
      "route53:Get*", "route53:List*",
      "cloudfront:Get*", "cloudfront:List*",
      "acm:DescribeCertificate", "acm:GetCertificate", "acm:ListTagsForCertificate",
      "ecr:DescribeRepositories", "ecr:GetLifecyclePolicy", "ecr:GetRepositoryPolicy", "ecr:ListTagsForResource",
      "dlm:Get*", "dlm:ListTagsForResource",
      "guardduty:Get*", "guardduty:List*",
      "access-analyzer:Get*", "access-analyzer:List*",
      "ssm:DescribeDocument", "ssm:GetDocument", "ssm:DescribeDocumentPermission", "ssm:ListTagsForResource",
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_plan" {
  name   = "home-platform-github-plan"
  role   = aws_iam_role.github_plan.id
  policy = data.aws_iam_policy_document.github_plan_permissions.json
}
