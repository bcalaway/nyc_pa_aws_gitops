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

    # Two formats, not one -- confirmed via CloudTrail 2026-07-26 that a
    # newly-created repo's OIDC sub claim defaults to GitHub's newer
    # immutable-ID format (repo:OWNER@OWNER_ID/REPO@REPO_ID:...), unlike
    # nyc_pa_aws_gitops's own github_actions role (iam.tf), created before
    # this became the default, which still gets plain repo:OWNER/REPO:....
    # The repo-level customization API to force the classic format
    # (PUT .../actions/oidc/customization/sub) needs repo Administration
    # write, which the gh CLI's fine-grained PAT in SSM doesn't have --
    # same class of limitation as it not being able to create repos at all
    # (see the todo-app repo creation gotcha). Trusting both formats here
    # is the simpler fix and survives either way if that default ever
    # changes again.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/todo-app:*",
        "repo:bcalaway@37939549/todo-app@1313063209:*",
      ]
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

# ---------------------------------------------------------------------------
# hue (Milestone 12) -- one IAM role (this section), two ECR repositories:
# `hue` (the hub component, deployed to the AWS hub via the normal
# app-build-push.yml/app-deploy.yml pipeline) and `hue-agent` (deployed to
# the NUCs via Ansible instead -- a different mechanism, see
# ansible/roles/hue-agent/ and docs/roadmap.md's Milestone 12). Both images
# are built and pushed by the same hue-github-actions role/repo's CI; a
# second IAM role isn't needed just because the *deploy* path differs.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "hue" {
  name = "hue"
  tags = { Name = "hue" }
}

resource "aws_ecr_repository" "hue_agent" {
  name = "hue-agent"
  tags = { Name = "hue-agent" }
}

data "aws_iam_policy_document" "hue_github_actions_assume" {
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

    # Same dual-format trust as todo_app above -- confirmed via
    # `gh api repos/bcalaway/hue` that this newly-created repo also
    # presents the newer immutable-ID sub claim, not the plain one.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/hue:*",
        "repo:bcalaway@37939549/hue@1340907446:*",
      ]
    }
  }
}

resource "aws_iam_role" "hue_github_actions" {
  name               = "hue-github-actions"
  assume_role_policy = data.aws_iam_policy_document.hue_github_actions_assume.json

  tags = { Name = "hue-github-actions" }
}

data "aws_iam_policy_document" "hue_github_actions_permissions" {
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
    resources = [aws_ecr_repository.hue.arn, aws_ecr_repository.hue_agent.arn]
  }

  # No Postgres credential here -- Milestone 12's MVP has no database (pure
  # live pass-through from the agent, nothing stored yet). The
  # /home-platform/hue/* wildcard also covers the two site Hue bridge API
  # keys (SSM), which this role can therefore read even though only the
  # NUC-side agent (a different deploy path entirely) actually uses them --
  # accepted as low-risk rather than splitting them into a separate SSM
  # namespace for one household app.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/hue/*",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/hue-client-id",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/hue-client-secret",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["arn:aws:s3:::home-platform-ansible-deploy-${var.aws_account_id}/apps/hue/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = ["arn:aws:s3:::home-platform-ansible-deploy-${var.aws_account_id}"]
  }

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

resource "aws_iam_role_policy" "hue_github_actions" {
  name   = "hue-github-actions"
  role   = aws_iam_role.hue_github_actions.id
  policy = data.aws_iam_policy_document.hue_github_actions_permissions.json
}
