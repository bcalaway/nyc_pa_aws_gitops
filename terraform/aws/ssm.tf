# SSM parameters are no longer managed by Terraform (Milestone 20, ADR-0025).
#
# These 21 parameters were created here with value = "PLACEHOLDER" and
# ignore_changes = [value]: Terraform only made the empty slot and Bill set
# the real value by hand. But every refresh still copied the *real* value
# into Terraform state, so anything able to read state -- including a PR's
# plan job -- could read every router, switch, NAS and WireGuard secret.
#
# The `removed` blocks below drop them from state WITHOUT deleting them in
# AWS (destroy = false): the parameters, values and paths are unchanged, and
# docs/ssm-parameters.md stays the catalog. New parameters are created with
# `aws ssm put-parameter`, like every other secret on the platform.
#
# Old state *versions* in the state bucket still hold the values; the plan
# role can't read object versions (no s3:GetObjectVersion).

# /home-platform/wireguard/server-private-key
removed {
  from = aws_ssm_parameter.wireguard_server_private_key
  lifecycle {
    destroy = false
  }
}

# /home-platform/wireguard/nyc-public-key
removed {
  from = aws_ssm_parameter.wireguard_nyc_public_key
  lifecycle {
    destroy = false
  }
}

# /home-platform/wireguard/rambles-public-key
removed {
  from = aws_ssm_parameter.wireguard_rambles_public_key
  lifecycle {
    destroy = false
  }
}

# /home-platform/grafana/admin-password
removed {
  from = aws_ssm_parameter.grafana_admin_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/uptime-kuma/admin-password
removed {
  from = aws_ssm_parameter.uptime_kuma_admin_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/grafana/smtp-password
removed {
  from = aws_ssm_parameter.grafana_smtp_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/github/api-token
removed {
  from = aws_ssm_parameter.github_api_token
  lifecycle {
    destroy = false
  }
}

# /home-platform/router/nyc-admin-password
removed {
  from = aws_ssm_parameter.router_nyc_admin_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/router/rambles-admin-password
removed {
  from = aws_ssm_parameter.router_rambles_admin_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/switch/nyc-sw-desk-username
removed {
  from = aws_ssm_parameter.switch_nyc_sw_desk_username
  lifecycle {
    destroy = false
  }
}

# /home-platform/switch/nyc-sw-desk-password
removed {
  from = aws_ssm_parameter.switch_nyc_sw_desk_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/switch/nyc-sw-main-username
removed {
  from = aws_ssm_parameter.switch_nyc_sw_main_username
  lifecycle {
    destroy = false
  }
}

# /home-platform/switch/nyc-sw-main-password
removed {
  from = aws_ssm_parameter.switch_nyc_sw_main_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/switch/nyc-sw10g-username
removed {
  from = aws_ssm_parameter.switch_nyc_sw10g_username
  lifecycle {
    destroy = false
  }
}

# /home-platform/switch/nyc-sw10g-password
removed {
  from = aws_ssm_parameter.switch_nyc_sw10g_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/nas/nyc-nas2-username
removed {
  from = aws_ssm_parameter.nas_nyc_nas2_username
  lifecycle {
    destroy = false
  }
}

# /home-platform/nas/nyc-nas2-password
removed {
  from = aws_ssm_parameter.nas_nyc_nas2_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/nuc/rambles-nuc5-username
removed {
  from = aws_ssm_parameter.nuc_rambles_nuc5_username
  lifecycle {
    destroy = false
  }
}

# /home-platform/nuc/rambles-nuc5-password
removed {
  from = aws_ssm_parameter.nuc_rambles_nuc5_password
  lifecycle {
    destroy = false
  }
}

# /home-platform/ansible/nuc-private-key
removed {
  from = aws_ssm_parameter.ansible_nuc_private_key
  lifecycle {
    destroy = false
  }
}

# /home-platform/ansible/nuc-public-key
removed {
  from = aws_ssm_parameter.ansible_nuc_public_key
  lifecycle {
    destroy = false
  }
}
