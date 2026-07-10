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
