# EC2 instance role for certbot-dns-route53 (ADR-0008): DNS-01 challenge
# requires write access to the hosted zone, no inbound ports needed.

data "aws_iam_policy_document" "hub_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "hub" {
  name               = "home-platform-hub"
  assume_role_policy = data.aws_iam_policy_document.hub_assume_role.json

  tags = { Name = "home-platform-hub" }
}

data "aws_iam_policy_document" "hub_route53" {
  statement {
    effect    = "Allow"
    actions   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
    resources = [aws_route53_zone.main.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["route53:GetChange"]
    resources = ["arn:aws:route53:::change/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["route53:ListHostedZones", "route53:ListHostedZonesByName"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "hub_route53" {
  name   = "home-platform-hub-route53"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_route53.json
}

data "aws_iam_policy_document" "hub_cost_explorer" {
  statement {
    effect = "Allow"
    # Cost Explorer's API doesn't support resource-level permissions.
    actions   = ["ce:GetCostAndUsage", "ce:GetCostForecast"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "hub_cost_explorer" {
  name   = "home-platform-hub-cost-explorer"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_cost_explorer.json
}

# Lets the SSM Agent (present on the AL2023 AMI by default, not previously
# authorized to register) receive commands from ssm:SendCommand -- see
# terraform/aws/iam.tf's github_actions role, added for the RouterOS
# workflow (Milestone 9). Takes a few minutes after apply for the instance
# to show "Online" in Systems Manager.
resource "aws_iam_role_policy_attachment" "hub_ssm_core" {
  role       = aws_iam_role.hub.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Lets apply-config.py (run as ec2-user via the ansible/roles/routeros
# role, invoked either manually or through the SSM-triggered CI workflow)
# fetch the router admin password and WireGuard private key from SSM using
# the hub's own instance credentials (IMDS) -- separate from the GitHub
# Actions OIDC role, whose job stops at telling the hub to run the
# playbook. See routeros/apply-config.py and ansible/roles/routeros.
data "aws_iam_policy_document" "hub_ssm_router_secrets" {
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/router/*",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/wireguard/*",
    ]
  }
}

resource "aws_iam_role_policy" "hub_ssm_router_secrets" {
  name   = "home-platform-hub-ssm-router-secrets"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_ssm_router_secrets.json
}

# Read-only access to the ansible-deploy bucket (terraform/aws/s3.tf) --
# the RouterOS/NUC CI workflows sync ansible/ and routeros/ there, and app
# CD workflows (.github/workflows/app-deploy.yml, ADR-0019) stage their
# Compose fragments under apps/<app>/ in the same bucket. The
# SSM-triggered command on the hub syncs back down from it in both cases.
data "aws_iam_policy_document" "hub_ansible_deploy_read" {
  statement {
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [aws_s3_bucket.ansible_deploy.arn, "${aws_s3_bucket.ansible_deploy.arn}/*"]
  }
}

resource "aws_iam_role_policy" "hub_ansible_deploy_read" {
  name   = "home-platform-hub-ansible-deploy-read"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_ansible_deploy_read.json
}

# App deploy support (ADR-0019, apps.tf) -- the hub-side deploy script
# (.github/workflows/app-deploy.yml) runs as this role, not the GitHub
# Actions workflow's own role, so it needs its own ECR pull access and its
# own read access to each app's secrets. Grows by one block of statements
# per app, same pattern as the SSM router-secrets statement above.
data "aws_iam_policy_document" "hub_app_deploy" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.todo_app.arn]
  }

  # Secret injection at deploy time (see app-deploy.yml's header comment
  # for the full SSM-path-to-env-var convention) -- scoped to exactly the
  # same parameter set todo-app's own GitHub Actions role can read
  # (apps.tf), since both roles need it for the same reason: this app's
  # own credentials, nothing broader.
  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/todo-app/*"]
  }

  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/postgres/todo-app-password",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/todo-app-client-id",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/todo-app-client-secret",
    ]
  }

  # hue (Milestone 12) -- the hub component (deployed here via the normal
  # SSM-SendCommand path) and the agent, which is NOT deployed by
  # app-deploy.yml at all -- it's relayed to the NUCs by Ansible
  # (ansible/roles/hue-agent), running on this same hub, using this same
  # role's credentials to `docker pull` from hue-agent's ECR repo and then
  # `docker save`/scp/`docker load` the image onto the NUC (which has no
  # AWS credentials of its own). ssm:GetParametersByPath below already
  # covers Ansible's need to read the site Hue bridge API keys.
  statement {
    effect    = "Allow"
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
    resources = [aws_ecr_repository.hue.arn, aws_ecr_repository.hue_agent.arn]
  }

  statement {
    effect    = "Allow"
    actions   = ["ssm:GetParametersByPath"]
    resources = ["arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/hue/*"]
  }

  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/hue-client-id",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/hue-client-secret",
    ]
  }
}

resource "aws_iam_role_policy" "hub_app_deploy" {
  name   = "home-platform-hub-app-deploy"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_app_deploy.json
}

# Lets postgres-backup (compose/aws/postgres-backup) upload pg_dumpall
# backups via the hub's own instance credentials (IMDS) -- same pattern as
# hub_ansible_deploy_read above, no static AWS keys in the container.
# Scoped to the postgres-backups/ prefix, not the whole logs bucket.
data "aws_iam_policy_document" "hub_postgres_backup_write" {
  statement {
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/postgres-backups/*"]
  }

  statement {
    effect    = "Allow"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.logs.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["postgres-backups/*"]
    }
  }
}

resource "aws_iam_role_policy" "hub_postgres_backup_write" {
  name   = "home-platform-hub-postgres-backup-write"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_postgres_backup_write.json
}

resource "aws_iam_instance_profile" "hub" {
  name = "home-platform-hub"
  role = aws_iam_role.hub.name
}

resource "aws_route53_record" "grafana" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "grafana.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

resource "aws_route53_record" "status" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "status.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

resource "aws_route53_record" "auth" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "auth.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

# First app onboarded per ADR-0019/docs/app-platform.md -- one more record
# per app going forward, no wildcard (see that doc's Ingress and DNS
# section for why).
resource "aws_route53_record" "todo_app" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "todo-app.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

resource "aws_route53_record" "hue" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "hue.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}
