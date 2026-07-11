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
  # Terraform state (S3 backend, native S3 locking via use_lockfile -- the
  # home-platform-terraform-locks DynamoDB table predates that and is no
  # longer read by this backend config, so no dynamodb: permissions needed).
  statement {
    effect  = "Allow"
    actions = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
    resources = [
      "arn:aws:s3:::home-platform-terraform-state-${var.aws_account_id}",
      "arn:aws:s3:::home-platform-terraform-state-${var.aws_account_id}/*",
    ]
  }

  # EC2/VPC — kept broad (resources=*). Unlike the statements below, EC2's
  # IAM model doesn't support resource-level scoping for most Describe*/List*
  # actions that Terraform relies on for every plan/refresh, so meaningfully
  # restricting this would require a much larger, harder-to-maintain
  # tag-condition policy for one t3.small instance and its VPC. Accepted
  # trade-off: EC2 access can't be used to escalate to full account admin
  # the way iam:* can, so this is lower-risk than the statement it replaces.
  statement {
    effect    = "Allow"
    actions   = ["ec2:*"]
    resources = ["*"]
  }

  # This project's two managed buckets (logs, portal) -- was s3:* on every
  # bucket in the account, now scoped to just these two plus their objects.
  statement {
    effect  = "Allow"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.logs.arn, "${aws_s3_bucket.logs.arn}/*",
      aws_s3_bucket.portal.arn, "${aws_s3_bucket.portal.arn}/*",
    ]
  }

  # Route53 — same scoping pattern as the hub role's policy in tls.tf.
  # CreateHostedZone/DeleteHostedZone can't be ARN-scoped (the zone doesn't
  # exist yet on create), but this account only has the one zone anyway.
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets", "route53:GetHostedZone", "route53:ListTagsForResource", "route53:ChangeTagsForResource"]
    resources = [aws_route53_zone.main.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["route53:CreateHostedZone", "route53:DeleteHostedZone", "route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }

  # CloudFront — CreateInvalidation is scoped to the actual distribution
  # (this is the action portal.yml runs on every deploy); distribution/OAC
  # create/list can't be ARN-scoped since those resources don't exist yet
  # at creation time, and this project only ever manages the one of each.
  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation", "cloudfront:ListInvalidations", "cloudfront:GetDistribution", "cloudfront:UpdateDistribution", "cloudfront:DeleteDistribution", "cloudfront:TagResource", "cloudfront:UntagResource", "cloudfront:ListTagsForResource"]
    resources = [aws_cloudfront_distribution.portal.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["cloudfront:CreateDistribution", "cloudfront:ListDistributions", "cloudfront:CreateOriginAccessControl", "cloudfront:GetOriginAccessControl", "cloudfront:UpdateOriginAccessControl", "cloudfront:DeleteOriginAccessControl", "cloudfront:ListOriginAccessControls"]
    resources = ["*"]
  }

  # ACM — same story as CloudFront: RequestCertificate can't be ARN-scoped.
  statement {
    effect    = "Allow"
    actions   = ["acm:DescribeCertificate", "acm:GetCertificate", "acm:DeleteCertificate", "acm:AddTagsToCertificate", "acm:RemoveTagsFromCertificate", "acm:ListTagsForCertificate"]
    resources = [aws_acm_certificate.portal.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["acm:RequestCertificate", "acm:ListCertificates"]
    resources = ["*"]
  }

  # SSM — scoped to this project's parameter path instead of every
  # parameter in the account. DescribeParameters is inherently a
  # search/list action (like s3:ListAllMyBuckets) and can't be path-scoped.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:PutParameter", "ssm:DeleteParameter", "ssm:AddTagsToResource", "ssm:ListTagsForResource", "ssm:RemoveTagsFromResource"]
    resources = ["arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:DescribeParameters"]
    resources = ["*"]
  }

  # IAM — this is the important one: was iam:* on every IAM resource in the
  # account (a privilege-escalation vector -- a role that can touch any IAM
  # entity can grant itself more access). Scoped to only the specific
  # role/instance-profile/OIDC-provider this Terraform config manages,
  # including itself (this role modifies its own inline policy on future
  # applies, so it needs permission on its own ARN).
  statement {
    effect = "Allow"
    actions = [
      "iam:GetRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:TagRole", "iam:UntagRole", "iam:ListRoleTags", "iam:ListInstanceProfilesForRole",
      "iam:GetRolePolicy", "iam:PutRolePolicy", "iam:DeleteRolePolicy", "iam:ListRolePolicies",
      "iam:ListAttachedRolePolicies", "iam:AttachRolePolicy", "iam:DetachRolePolicy",
    ]
    resources = [aws_iam_role.github_actions.arn, aws_iam_role.hub.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:GetInstanceProfile", "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = [aws_iam_instance_profile.hub.arn]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:GetOpenIDConnectProvider", "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider",
      "iam:UpdateOpenIDConnectProviderThumbprint", "iam:TagOpenIDConnectProvider", "iam:UntagOpenIDConnectProvider",
      "iam:AddClientIDToOpenIDConnectProvider", "iam:RemoveClientIDFromOpenIDConnectProvider",
    ]
    resources = [aws_iam_openid_connect_provider.github.arn]
  }

  # Needed to attach the hub role to its EC2 instance profile -- deliberately
  # NOT granted on the github_actions role's own ARN, which it never needs.
  statement {
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.hub.arn]
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name   = "home-platform-github-actions"
  role   = aws_iam_role.github_actions.id
  policy = data.aws_iam_policy_document.github_actions_permissions.json
}
