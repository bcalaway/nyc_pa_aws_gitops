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

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

resource "aws_eip" "hub" {
  instance = aws_instance.hub.id
  domain   = "vpc"

  tags = { Name = "home-platform-hub" }
}
