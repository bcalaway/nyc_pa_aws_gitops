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
#
# RUNTIME_MONITORING comes back from AWS with three agent-management
# sub-settings attached; declaring them (also off) keeps every later plan
# clean instead of showing a phantom change each time (seen on #29/#30).
resource "aws_guardduty_detector_feature" "off" {
  for_each = toset(["S3_DATA_EVENTS", "EBS_MALWARE_PROTECTION", "RUNTIME_MONITORING"])

  detector_id = aws_guardduty_detector.main.id
  name        = each.key
  status      = "DISABLED"

  dynamic "additional_configuration" {
    for_each = each.key == "RUNTIME_MONITORING" ? ["EKS_ADDON_MANAGEMENT", "ECS_FARGATE_AGENT_MANAGEMENT", "EC2_AGENT_MANAGEMENT"] : []
    content {
      name   = additional_configuration.value
      status = "DISABLED"
    }
  }
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

# The GitHub Actions OIDC roles are "accessible from outside the account" by
# design -- GitHub's OIDC provider is the external principal. Milestone 20
# (ADR-0025) narrowed each to specific subjects (main, production, PRs), so
# archive exactly those findings: same resources AND the GitHub federated
# principal. Any other external access to these roles still shows up in
# aws_posture and the weekly review.
resource "time_sleep" "wait_for_github_actions_archive_rule_policy" {
  depends_on      = [aws_iam_role_policy.github_actions]
  create_duration = "15s"
}

resource "aws_accessanalyzer_archive_rule" "github_oidc_roles" {
  depends_on = [time_sleep.wait_for_github_actions_archive_rule_policy]

  analyzer_name = aws_accessanalyzer_analyzer.account.analyzer_name
  rule_name     = "github-oidc-roles"

  filter {
    criteria = "resource"
    # eq is an ordered list in the provider, so this keeps the pre-registry
    # order exactly (platform roles, app roles, preview roles, each in
    # apps/registry.yml order). Adding an app updates this rule in place.
    eq = concat(
      [aws_iam_role.github_actions.arn, aws_iam_role.github_plan.arn],
      [for n in local.app_names : aws_iam_role.app_github_actions[n].arn],
      [for n in local.preview_app_names : aws_iam_role.app_preview[n].arn],
    )
  }

  filter {
    criteria = "principal.Federated"
    eq       = [aws_iam_openid_connect_provider.github.arn]
  }
}

# The weekly exposure check (compose/aws/host/exposure-check.py) nmaps the
# hub's own public IP and both sites' WAN IPs from the hub, which GuardDuty
# reports as Recon:EC2/Portscan (first seen 2026-10-04, docs/gotchas.md).
# Archive exactly that: this finding type, from the hub instance, against
# those three addresses. A scan of anything else still shows in aws_posture.
#
# The site IPs are residential and can drift (docs/platform-reference.md,
# "Site WAN egress"; the check itself reads them from WireGuard). When one
# changes, the finding simply comes back -- update it here then. Rambles'
# will change, or go away behind CGNAT, once Starlink failover lands.
locals {
  exposure_scan_site_ips = [
    "173.68.62.107",  # NYC (Verizon FiOS)
    "204.186.165.69", # Rambles (Blue Ridge Cable)
  ]
}

resource "time_sleep" "wait_for_github_actions_guardduty_filter_policy" {
  depends_on      = [aws_iam_role_policy.github_actions]
  create_duration = "15s"
}

resource "aws_guardduty_filter" "exposure_scan" {
  depends_on = [time_sleep.wait_for_github_actions_guardduty_filter_policy]

  detector_id = aws_guardduty_detector.main.id
  name        = "exposure-check-self-scan"
  # GuardDuty rejects many characters here (CreateFilter refused the first
  # version, with an apostrophe, 2026-10-04): keep it to letters, digits,
  # spaces, hyphens and periods.
  description = "Weekly exposure check from the hub scanning the hub and site public IPs. See exposure-check.py in compose aws host."
  action      = "ARCHIVE"
  rank        = 1

  finding_criteria {
    criterion {
      field  = "type"
      equals = ["Recon:EC2/Portscan"]
    }
    criterion {
      field  = "resource.instanceDetails.instanceId"
      equals = [aws_instance.hub.id]
    }
    criterion {
      field  = "service.action.networkConnectionAction.remoteIpDetails.ipAddressV4"
      equals = concat([aws_eip.hub.public_ip], local.exposure_scan_site_ips)
    }
  }

  tags = { Name = "home-platform" }
}
