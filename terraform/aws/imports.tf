# One-time imports for SSM parameters that were created manually before
# Terraform knew about them. These are safe to leave in place — Terraform
# skips the import if the resource is already in state.

import {
  to = aws_ssm_parameter.router_nyc_admin_password
  id = "/home-platform/router/nyc-admin-password"
}

import {
  to = aws_ssm_parameter.github_api_token
  id = "/home-platform/github/api-token"
}
