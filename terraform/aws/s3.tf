resource "aws_s3_bucket" "logs" {
  bucket = "home-platform-logs-${var.aws_account_id}"

  tags = { Name = "home-platform-logs" }
}

resource "aws_s3_bucket_versioning" "logs" {
  bucket = aws_s3_bucket.logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire-old-logs"
    status = "Enabled"
    filter {}

    transition {
      days          = 30
      storage_class = "STANDARD_IA"
    }

    expiration {
      days = 365
    }
  }
}

resource "aws_s3_bucket" "portal" {
  bucket = "home-platform-portal-${var.aws_account_id}"

  tags = { Name = "home-platform-portal" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "portal" {
  bucket = aws_s3_bucket.portal.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

# Staging area for the RouterOS/NUC CI pipelines (Milestone 9): GitHub
# Actions syncs ansible/ and routeros/ here, then the SSM-triggered command
# on the hub syncs back down from it -- avoids needing git or a deploy
# credential on the hub at all. Private, no public access, no website
# hosting (unlike portal) since nothing here is ever served.
#
# This bucket's creation failed twice in CI before this resource existed:
# first with a genuine circular dependency (the github_actions role's S3
# permissions referenced this bucket's .arn, so Terraform's graph required
# the bucket to exist before it could compute the policy that would let it
# be created -- fixed by using a literal ARN string instead), then with
# "not authorized to perform: s3:CreateBucket" again on the very next
# apply -- breaking the graph cycle removed all ordering between the
# policy update and the bucket creation, so Terraform ran them without any
# guaranteed sequencing, and IAM's eventual consistency (a PutRolePolicy
# call returning success doesn't mean the permission is enforced
# everywhere yet) meant the bucket creation could still lose the race.
# time_sleep forces a real wait after the policy API call completes, not
# just an ordering of the calls themselves.
resource "time_sleep" "wait_for_github_actions_s3_policy" {
  depends_on      = [aws_iam_role_policy.github_actions]
  create_duration = "15s"
}

resource "aws_s3_bucket" "ansible_deploy" {
  depends_on = [time_sleep.wait_for_github_actions_s3_policy]

  bucket = "home-platform-ansible-deploy-${var.aws_account_id}"

  tags = { Name = "home-platform-ansible-deploy" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "ansible_deploy" {
  bucket = aws_s3_bucket.ansible_deploy.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "ansible_deploy" {
  bucket                  = aws_s3_bucket.ansible_deploy.id
  block_public_acls       = true
  ignore_public_acls      = true
  block_public_policy     = true
  restrict_public_buckets = true
}
