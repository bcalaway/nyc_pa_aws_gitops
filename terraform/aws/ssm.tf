resource "aws_ssm_parameter" "wireguard_server_private_key" {
  name  = "/home-platform/wireguard/server-private-key"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "wireguard-server-private-key" }
}

resource "aws_ssm_parameter" "wireguard_nyc_public_key" {
  name  = "/home-platform/wireguard/nyc-public-key"
  type  = "String"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "wireguard-nyc-public-key" }
}

resource "aws_ssm_parameter" "wireguard_rambles_public_key" {
  name  = "/home-platform/wireguard/rambles-public-key"
  type  = "String"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "wireguard-rambles-public-key" }
}

resource "aws_ssm_parameter" "grafana_smtp_password" {
  name  = "/home-platform/grafana/smtp-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "grafana-smtp-password" }
}

resource "aws_ssm_parameter" "router_nyc_admin_password" {
  name  = "/home-platform/router/nyc-admin-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "router-nyc-admin-password" }
}

resource "aws_ssm_parameter" "router_rambles_admin_password" {
  name  = "/home-platform/router/rambles-admin-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "router-rambles-admin-password" }
}
