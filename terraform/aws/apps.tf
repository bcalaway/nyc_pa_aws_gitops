# Per-app platform resources (ADR-0019). Each app gets its own ECR
# repository and its own narrowly-scoped IAM role/OIDC trust condition --
# never access added to the platform's own github_actions role (iam.tf).
# One block per app below; the TODO app is first.

# ---------------------------------------------------------------------------
# todo-app
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "todo_app" {
  name = "todo-app"
  # Mutable (the default) is required, not just tolerated -- ADR-0019's CD
  # step tags every push with both <git-sha> and `latest`, and `latest` has
  # to be overwritable on each push.
  tags = { Name = "todo-app" }
}

data "aws_iam_policy_document" "todo_app_github_actions_assume" {
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

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/todo-app:*"]
    }
  }
}

resource "aws_iam_role" "todo_app_github_actions" {
  name               = "todo-app-github-actions"
  assume_role_policy = data.aws_iam_policy_document.todo_app_github_actions_assume.json

  tags = { Name = "todo-app-github-actions" }
}

data "aws_iam_policy_document" "todo_app_github_actions_permissions" {
  # ECR auth -- GetAuthorizationToken doesn't support resource-level scoping
  # (same class of API as ssm:DescribeParameters/dlm:TagResource elsewhere
  # in this repo); every other ECR action below is scoped to this app's own
  # repository only.
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
    resources = [aws_ecr_repository.todo_app.arn]
  }

  # SSM read, scoped to exactly this app's own secrets -- its general
  # namespace plus the specific cross-service credentials it owns (its
  # Postgres role's password, its Authentik OIDC client id/secret). Not a
  # wildcard on postgres/* or authentik/*, which would also expose every
  # other app's/service's credentials under those same prefixes. Literal
  # ARN strings, not resource references -- none of these parameters exist
  # yet (todo-app's DB and Authentik client are provisioned later, per
  # docs/app-platform.md's onboarding checklist), same pattern already used
  # for the ansible-deploy bucket and the DLM role in iam.tf.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/todo-app/*",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/postgres/todo-app-password",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/todo-app-client-id",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/todo-app-client-secret",
    ]
  }

  # Deploy staging -- reuses the existing ansible-deploy bucket (s3.tf)
  # under an apps/todo-app/ prefix instead of standing up a second bucket
  # for the same "stage an artifact, hub pulls it down" purpose the
  # RouterOS/NUC pipeline already established. The hub's own instance role
  # already has read access to the whole bucket (tls.tf's
  # hub_ansible_deploy_read), so only this write grant is new; scoped to
  # just this app's own prefix, not the ansible/routeros paths other
  # pipelines use in the same bucket.
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::home-platform-ansible-deploy-${var.aws_account_id}/apps/todo-app/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::home-platform-ansible-deploy-${var.aws_account_id}"]
  }

  # Deploy triggering -- same SSM Run Command pattern as the RouterOS
  # workflow (iam.tf's github_actions role): DescribeInstances can't be
  # resource-scoped (EC2's Describe* actions don't support it), SendCommand
  # is scoped to the hub instance specifically, and the Get/List actions
  # below can't be resource-scoped either (identified by command-id, not a
  # taggable/ARN-able resource -- same limitation noted in iam.tf).
  statement {
    effect    = "Allow"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:aws:ssm:us-east-1::document/AWS-RunShellScript"]
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

resource "aws_iam_role_policy" "todo_app_github_actions" {
  name   = "todo-app-github-actions"
  role   = aws_iam_role.todo_app_github_actions.id
  policy = data.aws_iam_policy_document.todo_app_github_actions_permissions.json
}
