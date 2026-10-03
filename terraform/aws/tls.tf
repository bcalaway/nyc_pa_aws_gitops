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
# own read access to each app's secrets. One set of statements per app in
# apps/registry.yml (ADR-0028); the NUC relays below (hue-agent,
# mopeka-exporter, voice-worker) are listed by hand.
data "aws_iam_policy_document" "hub_app_deploy" {
  statement {
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # Image pulls: the app's own repositories plus its preview repository.
  # Extra repos cover NUC relays too -- hue-agent is NOT deployed by
  # app-deploy.yml at all; Ansible on this hub (ansible/roles/hue-agent)
  # pulls it with this role's credentials and docker save/scp/loads it onto
  # the NUC, which has no AWS credentials of its own.
  dynamic "statement" {
    for_each = local.app_names
    content {
      effect  = "Allow"
      actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:BatchCheckLayerAvailability"]
      resources = concat(
        [for r in local.app_repo_names[statement.value] : aws_ecr_repository.app[r].arn],
        local.apps[statement.value].preview ? [aws_ecr_repository.app_preview[statement.value].arn] : [],
      )
    }
  }

  # Secret injection at deploy time (see app-deploy.yml's header comment for
  # the SSM-path-to-env-var convention): the app's own /home-platform/<app>/
  # tree (for hue this also covers Ansible's read of the site bridge keys)...
  dynamic "statement" {
    for_each = local.app_names
    content {
      effect    = "Allow"
      actions   = ["ssm:GetParametersByPath"]
      resources = ["arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/${statement.value}/*"]
    }
  }

  # ...plus its database password and Authentik client, when it has them.
  dynamic "statement" {
    for_each = { for n in local.app_names : n => n if local.apps[n].database || local.apps[n].authentik }
    content {
      effect  = "Allow"
      actions = ["ssm:GetParameter"]
      resources = [for p in concat(
        local.apps[statement.key].database ? ["postgres/${statement.key}-password"] : [],
        local.apps[statement.key].authentik ? ["authentik/${statement.key}-client-id", "authentik/${statement.key}-client-secret"] : [],
      ) : "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/${p}"]
    }
  }

  # Milestone 15: mopeka-exporter is relayed to nuc5 by Ansible
  # (ansible/roles/mopeka-exporter), running on this hub, the same way
  # hue-agent is. It needs each ESPHome BLE proxy's native-API encryption
  # key (noise PSK) fetched here at deploy time and injected into the
  # rendered compose file's environment. One entry per proxy listed in
  # ansible/inventory/hosts.yml's mopeka_proxies.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/mopeka-proxy/api-encryption-key",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/mopeka-proxy/api-encryption-key-2",
    ]
  }

  # Milestone 18 phase 3 (ADR-0021): ansible/roles/voice-worker, run from
  # this hub, installs the coding worker on nuc4. It reads the agent's
  # scoped GitHub token and Claude Code OAuth token here (the NUC has no
  # AWS creds) plus the public half of home-mcp's SSH key for the
  # voiceworker forced command. The private half is granted separately in
  # hub_platform_deploy below, for CI deploys of the hub stack.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/github/coding-agent-token",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/claude/code-oauth-token",
      "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/voice-worker/ssh-public-key",
    ]
  }
}

resource "aws_iam_role_policy" "hub_app_deploy" {
  name   = "home-platform-hub-app-deploy"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_app_deploy.json
}

# Platform deploy from CI (.github/workflows/platform-deploy.yml): the
# hub-side scripts in scripts/hub/ build the hub stack's .env and refresh
# the Ansible NUC key here, with this role, so no secret passes through
# GitHub Actions. Same list as scripts/deploy-aws-stack.sh (which reads
# them with the operator's own credentials for manual deploys) -- keep the
# two in sync. Every value below already sits in the hub's compose .env or
# ~/.ssh, so this doesn't expose anything the hub doesn't already hold.
data "aws_iam_policy_document" "hub_platform_deploy" {
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter"]
    resources = [for p in concat([
      "grafana/smtp-password",
      "postgres/admin-password",
      "authentik/redis-password",
      "rachio/api-key",
      "authentik/db-password",
      "authentik/secret-key",
      "authentik/bootstrap-password",
      "authentik/grafana-client-id",
      "authentik/grafana-client-secret",
      "authentik/home-mcp-client-id",
      "authentik/home-mcp-client-secret",
      "voice-worker/ssh-private-key",
      "postgres/umami-password",
      "umami/app-secret",
      "umami/two-factor-encryption-key",
      "ansible/nuc-private-key",
      "github/voice-jobs-token",
      "github/security-read-token",
      "authentik/home-mcp-audit-token",
      ],
      # Each registry app's Authentik client (ADR-0028), for the hub stack's .env.
      flatten([for n in local.app_names : local.apps[n].authentik ? ["authentik/${n}-client-id", "authentik/${n}-client-secret"] : []]),
    ) : "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/${p}"]
  }

  # ADR-0024: deploy-hub-stack.sh generates the Authentik audit token on
  # the first deploy that needs it. Write access to this one parameter only.
  statement {
    effect    = "Allow"
    actions   = ["ssm:PutParameter"]
    resources = ["arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/authentik/home-mcp-audit-token"]
  }

  # ADR-0028: scripts/hub/onboard-app-dbs.sh reads each registry app's (and
  # platform database's) Postgres password and creates it on first
  # onboarding (never with --overwrite); deploy-hub-stack.sh reads the
  # platform ones into the stack's .env. Exactly these parameters.
  dynamic "statement" {
    for_each = length(concat(local.database_app_names, local.platform_database_names)) > 0 ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["ssm:GetParameter", "ssm:PutParameter"]
      resources = [for n in concat(local.database_app_names, local.platform_database_names) : "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/postgres/${n}-password"]
    }
  }

  # ADR-0027: deploy-hub-stack.sh generates Airflow's own secrets on the
  # first deploy that needs them (same pattern as the audit token above)
  # and reads them into the stack's .env. These three parameters only.
  statement {
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:PutParameter"]
    resources = [for p in ["fernet-key", "api-secret-key", "jwt-secret"] :
    "arn:aws:ssm:us-east-1:${var.aws_account_id}:parameter/home-platform/airflow/${p}"]
  }
}

resource "aws_iam_role_policy" "hub_platform_deploy" {
  name   = "home-platform-hub-platform-deploy"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_platform_deploy.json
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
# Per-PR preview environments (ADR-0023): one wildcard, scoped to the
# preview subdomain only -- production hosts keep their explicit records.
# Covers <app>-pr<n>.preview.billandjessie.com and auth.preview (the
# domain-level forward-auth outpost host).
resource "aws_route53_record" "preview_wildcard" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "*.preview.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

resource "aws_route53_record" "todo_app" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "todo-app.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

# Airflow UI (ADR-0027) -- behind Authentik forward-auth, like
# status.billandjessie.com (compose/aws/data.yml).
resource "aws_route53_record" "airflow" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "airflow.billandjessie.com"
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

# Umami (usage analytics, Milestone 16) -- not an app-platform.md onboarding
# (no ECR/OIDC/GitHub Actions role: it's a prebuilt public image added
# directly to compose/aws/docker-compose.yml, same category as
# Grafana/Uptime Kuma/Authentik, not a Claude-authored app repo).
resource "aws_route53_record" "analytics" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "analytics.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

# home-mcp (Milestone 18, ADR-0021) -- remote MCP server for voice Claude's
# custom connector. Public on purpose (Claude connects from Anthropic's
# cloud), but Traefik only admits Anthropic's egress range on this host.
resource "aws_route53_record" "mcp" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "mcp.billandjessie.com"
  type    = "A"
  ttl     = 300
  records = [aws_eip.hub.public_ip]
}

# Security visibility for home-mcp (Milestone 19, ADR-0024): read-only
# List/Describe/Get calls for its aws_posture tool. None of these APIs
# support resource-level scoping for reads, hence "*". Nothing here can
# change a resource, read data out of S3, or read a secret.
data "aws_iam_policy_document" "hub_security_read" {
  statement {
    effect = "Allow"
    actions = [
      "guardduty:ListDetectors",
      "guardduty:ListFindings",
      "guardduty:GetFindings",
      "access-analyzer:ListAnalyzers",
      "access-analyzer:ListFindings", # also authorizes ListFindingsV2
      "ec2:DescribeSecurityGroups",
      "cloudtrail:LookupEvents",
      "iam:ListUsers",
      "iam:ListAccessKeys",
      "iam:ListMFADevices",
      "iam:GetLoginProfile",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "hub_security_read" {
  name   = "home-platform-hub-security-read"
  role   = aws_iam_role.hub.id
  policy = data.aws_iam_policy_document.hub_security_read.json
}
