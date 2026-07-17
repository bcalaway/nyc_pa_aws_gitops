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
resource "aws_s3_bucket" "ansible_deploy" {
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
