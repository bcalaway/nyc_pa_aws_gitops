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

resource "aws_ssm_parameter" "grafana_admin_password" {
  name  = "/home-platform/grafana/admin-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "grafana-admin-password" }
}

resource "aws_ssm_parameter" "uptime_kuma_admin_password" {
  name  = "/home-platform/uptime-kuma/admin-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "uptime-kuma-admin-password" }
}

resource "aws_ssm_parameter" "grafana_smtp_password" {
  name  = "/home-platform/grafana/smtp-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "grafana-smtp-password" }
}

resource "aws_ssm_parameter" "github_api_token" {
  name  = "/home-platform/github/api-token"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "github-api-token" }
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

resource "aws_ssm_parameter" "switch_nyc_sw_desk_username" {
  name  = "/home-platform/switch/nyc-sw-desk-username"
  type  = "String"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "switch-nyc-sw-desk-username" }
}

resource "aws_ssm_parameter" "switch_nyc_sw_desk_password" {
  name  = "/home-platform/switch/nyc-sw-desk-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "switch-nyc-sw-desk-password" }
}

resource "aws_ssm_parameter" "switch_nyc_sw_main_username" {
  name  = "/home-platform/switch/nyc-sw-main-username"
  type  = "String"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "switch-nyc-sw-main-username" }
}

resource "aws_ssm_parameter" "switch_nyc_sw_main_password" {
  name  = "/home-platform/switch/nyc-sw-main-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "switch-nyc-sw-main-password" }
}

resource "aws_ssm_parameter" "switch_nyc_sw10g_username" {
  name  = "/home-platform/switch/nyc-sw10g-username"
  type  = "String"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "switch-nyc-sw10g-username" }
}

resource "aws_ssm_parameter" "switch_nyc_sw10g_password" {
  name  = "/home-platform/switch/nyc-sw10g-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "switch-nyc-sw10g-password" }
}

resource "aws_ssm_parameter" "nas_nyc_nas2_username" {
  name  = "/home-platform/nas/nyc-nas2-username"
  type  = "String"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "nas-nyc-nas2-username" }
}

resource "aws_ssm_parameter" "nas_nyc_nas2_password" {
  name  = "/home-platform/nas/nyc-nas2-password"
  type  = "SecureString"
  value = "PLACEHOLDER"

  lifecycle { ignore_changes = [value] }

  tags = { Name = "nas-nyc-nas2-password" }
}
