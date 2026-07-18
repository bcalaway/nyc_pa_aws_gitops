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

resource "aws_iam_role" "dlm" {
  name               = "home-platform-dlm"
  assume_role_policy = data.aws_iam_policy_document.dlm_assume_role.json

  tags = { Name = "home-platform-dlm" }
}

resource "aws_iam_role_policy_attachment" "dlm" {
  role       = aws_iam_role.dlm.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSDataLifecycleManagerServiceRole"
}

resource "aws_dlm_lifecycle_policy" "hub_root_volume" {
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
