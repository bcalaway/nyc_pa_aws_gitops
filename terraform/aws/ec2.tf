data "aws_ami" "rocky9" {
  most_recent = true
  owners      = ["679593333241"] # Rocky Linux official

  filter {
    name   = "name"
    values = ["Rocky-9-EC2-Base-9.*x86_64*"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "hub" {
  ami                    = data.aws_ami.rocky9.id
  instance_type          = var.ec2_instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  key_name               = var.ec2_key_name

  root_block_device {
    volume_size           = 40
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = <<-EOF
    #!/bin/bash
    dnf update -y
    dnf install -y wireguard-tools docker docker-compose-plugin
    systemctl enable --now docker
  EOF

  tags = { Name = "home-platform-hub" }
}

resource "aws_eip" "hub" {
  instance = aws_instance.hub.id
  domain   = "vpc"

  tags = { Name = "home-platform-hub" }
}
