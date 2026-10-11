# ECR pull-through cache for public images (Bill, 2026-10-10).
#
# Builds pull BuildKit (moby/buildkit) and Docker's official base images from AWS's public mirror, public.ecr.aws
# (docs/gotchas.md: moved off Docker Hub on 2026-10-09). Those pulls are anonymous, and GitHub's runners share IP
# addresses with everyone else's, so AWS throttles them ("toomanyrequests: Rate exceeded" at "Set up Docker Buildx";
# three failed CI/CD runs on 2026-10-10 alone). This rule mirrors public.ecr.aws into our own registry under
# ecr-public/, so a workflow logged in to ECR pulls
#
#   147856894209.dkr.ecr.us-east-1.amazonaws.com/ecr-public/vend/moby/buildkit:buildx-stable-1
#   147856894209.dkr.ecr.us-east-1.amazonaws.com/ecr-public/docker/library/python:3.12-slim
#
# authenticated, from our account: ECR fetches an image from upstream on its first pull, then serves it from the
# cache (and refreshes a tag from upstream at most once every 24 hours).
#
# Who pulls: app CI on pull requests through home-platform-github-pull (below; an app's ci.yml must grant
# id-token: write), and app CD and previews through their own roles (apps.tf, ci-roles.tf). The reusable workflows
# fall back to public.ecr.aws when they can't log in, so nothing breaks before an app opts in.

locals {
  ecr_cache_prefix   = "ecr-public"
  ecr_cache_repo_arn = "arn:aws:ecr:us-east-1:${var.aws_account_id}:repository/${local.ecr_cache_prefix}/*"
  # What a principal needs to pull through the cache: read the cached images, and on an image's first pull let ECR
  # create its repository (from the template below) and import it from upstream.
  ecr_cache_pull_actions = [
    "ecr:BatchCheckLayerAvailability", "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
    "ecr:BatchImportUpstreamImage", "ecr:CreateRepository",
  ]
}

resource "aws_ecr_pull_through_cache_rule" "ecr_public" {
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  ecr_repository_prefix = local.ecr_cache_prefix
  upstream_registry_url = "public.ecr.aws" # ECR Public needs no upstream credentials
}

# Settings for the repositories the cache creates (ecr-public/docker/library/python, ...): keep the last 5 images of
# each, so old base-image versions don't pile up.
resource "aws_ecr_repository_creation_template" "ecr_public" {
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  prefix               = local.ecr_cache_prefix
  description          = "Pull-through cache of public.ecr.aws (ecr-cache.tf)"
  applied_for          = ["PULL_THROUGH_CACHE"]
  image_tag_mutability = "MUTABLE" # the cache refreshes tags like 3.12-slim from upstream

  encryption_configuration {
    encryption_type = "AES256"
  }

  lifecycle_policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep the last 5 images"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------- CI pulls

# App CI runs on pull requests, where no app role is trusted (ci-roles.tf), so pulls go through this shared role:
# trusted for every registry app's pull requests and branches, allowed only to pull through the cache.
data "aws_iam_policy_document" "github_pull_assume" {
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

    # Any workflow in an app repo (or this repo's templates): pull requests, branches, environments. The role can
    # do nothing but pull cached public images.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = flatten([for subjects in values(local.repo_subjects) : [for s in subjects : "${s}:*"]])
    }
  }
}

resource "aws_iam_role" "github_pull" {
  depends_on = [time_sleep.wait_for_github_actions_m20_policy]

  name               = "home-platform-github-pull"
  assume_role_policy = data.aws_iam_policy_document.github_pull_assume.json

  tags = { Name = "home-platform-github-pull" }
}

data "aws_iam_policy_document" "github_pull_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"] # can't be resource-scoped
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = local.ecr_cache_pull_actions
    resources = [local.ecr_cache_repo_arn]
  }
}

resource "aws_iam_role_policy" "github_pull" {
  name   = "home-platform-github-pull"
  role   = aws_iam_role.github_pull.id
  policy = data.aws_iam_policy_document.github_pull_permissions.json
}
