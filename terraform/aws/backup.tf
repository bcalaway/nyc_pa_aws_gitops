# Daily EBS snapshots of the hub's root volume (Milestone 11 -- ADR-0016's
# "EBS snapshots for the volume" leg of Postgres durability). This snapshots
# the whole root volume, not just the Docker volume backing Postgres, since
# EBS/DLM operates at the volume level -- a side effect is every other
# container's data (Grafana dashboards, Prometheus TSDB, etc.) gets the same
# coverage for free.
#
# Complements (not replaces) compose/aws/postgres-backup's pg_dumpall-to-S3
# job: this is fast point-in-time volume recovery, that's a logical,
# engine-independent dump usable even if the volume itself is unrecoverable.

data "aws_iam_policy_document" "dlm_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["dlm.amazonaws.com"]
    }
  }
}

# iam.tf's github_actions policy grants iam:CreateRole on this role via a
# literal ARN string (not aws_iam_role.dlm.arn) to avoid a circular
# dependency -- same fix as the ansible-deploy bucket in s3.tf. Breaking
# that cycle also removes any Terraform-graph ordering between the policy
# update and this role's creation, so without an explicit wait they can run
# in either order (or in parallel), racing IAM's eventual consistency: a
# PutRolePolicy that returns success doesn't mean it's enforced everywhere
# yet. This is the identical failure mode documented in s3.tf --
# time_sleep forces a real wait, not just an ordering of the API calls.
resource "time_sleep" "wait_for_github_actions_dlm_policy" {
  depends_on      = [aws_iam_role_policy.github_actions]
  create_duration = "15s"
}

resource "aws_iam_role" "dlm" {
  depends_on = [time_sleep.wait_for_github_actions_dlm_policy]

  name               = "home-platform-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role.json

  tags = { Name = "home-platform-dlm" }
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "hub_root_volume" {
  # Also waits on the same time_sleep as aws_iam_role.dlm above -- this
  # resource's own permissions (dlm:TagResource, iam:PassRole on the dlm
  # role) come from the same github_actions policy update, and hitting
  # AccessDenied here isn't gated by anything that forces a wait on its own
  # (no attribute of this resource references the policy), so without this
  # it can run immediately after the policy update returns, before IAM has
  # actually propagated it -- confirmed live twice (dlm:TagResource, then
  # iam:PassRole) before this explicit dependency was added.
  depends_on = [time_sleep.wait_for_github_actions_dlm_policy]

  description        = "Daily EBS snapshots of the home-platform hub root volume"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "daily"
    }

    schedule {
      name = "daily-snapshot"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["07:00"]
      }

      retain_rule {
        count = 7
      }

      tags_to_add = {
        SnapshotCreator = "DLM"
      }

      copy_tags = true
    }
  }
}
