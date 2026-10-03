data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "hub" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = var.ec2_key_name
  iam_instance_profile   = aws_iam_instance_profile.hub.name

  root_block_device {
    volume_size           = 200
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
    # Matched by the DLM lifecycle policy in backup.tf for daily snapshots.
    tags = { Name = "home-platform-hub-root", Backup = "daily" }
  }

  # Default hop limit of 1 blocks containers (one extra network hop via the
  # Docker bridge) from reaching IMDS to pick up the instance profile's
  # credentials -- needed by cost-exporter's boto3 client.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y wireguard-tools
    dnf install -y docker
    systemctl enable --now docker
    usermod -aG docker ec2-user
    # docker compose plugin
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -SL https://github.com/docker/compose/releases/latest/download/docker-compose-linux-x86_64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
  EOF

  tags = { Name = "home-platform-hub" }

  # The resize to t3.large (ADR-0026) changes instance_type, an in-place
  # stop/modify/start; the snapshot below must finish first.
  depends_on = [aws_ebs_snapshot.hub_pre_resize]

  lifecycle {
    ignore_changes = [ami, user_data]
    # The root volume (delete_on_termination) holds every Docker volume:
    # Postgres, Prometheus, Loki, Grafana, Uptime Kuma. Any plan that would
    # destroy or replace the hub fails instead of applying.
    prevent_destroy = true
  }
}

# One-off safety net for the t3.large resize (2026-10-03): a full snapshot of
# the hub's root volume, completed before the instance is stopped. Looked up
# by tag, not through aws_instance.hub, to avoid a dependency cycle. Taken
# while running, so crash-consistent (Postgres/Prometheus/Loki recover from
# their WALs). Remove this block (deleting the snapshot) once the resized hub
# has been fine for a week; the DLM daily snapshots (backup.tf) carry on.
data "aws_ebs_volume" "hub_root" {
  most_recent = true

  filter {
    name   = "tag:Name"
    values = ["home-platform-hub-root"]
  }

  filter {
    name   = "attachment.device"
    values = ["/dev/xvda"]
  }
}

resource "aws_ebs_snapshot" "hub_pre_resize" {
  volume_id   = data.aws_ebs_volume.hub_root.id
  description = "home-platform hub root before the t3.large resize (ADR-0026)"

  tags = { Name = "home-platform-hub-pre-resize" }

  timeouts {
    create = "60m"
  }
}

resource "aws_eip" "hub" {
  instance = aws_instance.hub.id
  domain   = "vpc"

  tags = { Name = "home-platform-hub" }
}
