# Account-level security monitoring (Milestone 19, ADR-0024). home-mcp's
# aws_posture tool reads both through the hub role's read-only
# hub_security_read policy (tls.tf).

# GuardDuty: threat detection from CloudTrail management events, VPC flow
# logs and DNS logs (crypto-mining, credential misuse, port probing, calls
# from known-bad IPs). Paid per volume analyzed; for one EC2 instance and
# light API use that's expected to be a few dollars a month -- check the
# cost-exporter dashboard after the first month. The optional protection
# plans (S3 data events, EKS, malware scanning, RDS, Lambda, runtime) are
# left off: there's nothing here for most of them, and they cost extra.
resource "aws_guardduty_detector" "main" {
  depends_on = [time_sleep.wait_for_github_actions_security_policy]

  enable                       = true
  finding_publishing_frequency = "SIX_HOURS"

  tags = { Name = "home-platform" }
}

# Pinned off explicitly rather than trusting whatever a new detector
# defaults to: these are the plans that bill for this account's resources
# (S3 data events on the buckets, EBS malware scans, runtime agents).
resource "aws_guardduty_detector_feature" "off" {
  for_each = toset(["S3_DATA_EVENTS", "EBS_MALWARE_PROTECTION", "RUNTIME_MONITORING"])

  detector_id = aws_guardduty_detector.main.id
  name        = each.key
  status      = "DISABLED"
}

# The CI role's permission to create these (iam.tf) lands in the same
# apply; IAM is eventually consistent, so wait before using it (same
# pattern and reason as backup.tf's DLM resources).
resource "time_sleep" "wait_for_github_actions_security_policy" {
  depends_on      = [aws_iam_role_policy.github_actions]
  create_duration = "15s"
}

# IAM Access Analyzer (account zone of trust): flags any S3 bucket, IAM
# role, KMS key, etc. that's shared outside this account. Free.
resource "aws_accessanalyzer_analyzer" "account" {
  depends_on = [time_sleep.wait_for_github_actions_security_policy]

  analyzer_name = "home-platform"
  type          = "ACCOUNT"

  tags = { Name = "home-platform" }
}
