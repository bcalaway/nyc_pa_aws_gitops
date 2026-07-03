resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_policy_document" "github_actions_assume" {
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
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_actions" {
  name               = "home-platform-github-actions"
  assume_role_policy = data.aws_iam_policy_document.github_actions_assume.json

  tags = { Name = "home-platform-github-actions" }
}

data "aws_iam_policy_document" "github_actions_permissions" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::home-platform-terraform-state-${var.aws_account_id}",
      "arn:aws:s3:::home-platform-terraform-state-${var.aws_account_id}/*",
    ]
  }

  statement {
    effect    = "Allow"
    actions   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"]
    resources = ["arn:aws:dynamodb:us-east-1:${var.aws_account_id}:table/home-platform-terraform-locks"]
  }

  statement {
    effect  = "Allow"
    actions = [
      "ec2:*", "vpc:*",
      "route53:*",
      "s3:*",
      "cloudfront:*",
      "acm:*",
      "ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter",
      "ssm:DeleteParameter", "ssm:DescribeParameters",
      "ssm:AddTagsToResource", "ssm:ListTagsForResource", "ssm:RemoveTagsFromResource",
      "iam:*",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "home-platform-github-actions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
