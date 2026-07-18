resource "aws_security_group" "ec2" {
  name        = "home-platform-ec2"
  description = "Home platform hub EC2"
  vpc_id      = aws_vpc.main.id

  # WireGuard
  ingress {
    description = "WireGuard"
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # SSH — restricted to WireGuard tunnel and site subnets
  ingress {
    description = "SSH from site subnets"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  }

  # HTTP (public) — nginx redirects to HTTPS
  ingress {
    description = "HTTP redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Grafana HTTPS (public)
  ingress {
    description = "Grafana HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Uptime Kuma — NOT public. Public access is https://status.billandjessie.com
  # via nginx on 443 (below); this raw port was open to 0.0.0.0/0 with no TLS,
  # bypassing that path entirely (security review finding, 2026-07-11).
  # Restricted to the WireGuard subnet for direct debugging, matching how
  # Prometheus/Loki are scoped -- same as Grafana, whose own port 3000 was
  # never opened here at all.
  ingress {
    description = "Uptime Kuma (internal only, use status.billandjessie.com for public access)"
    from_port   = 3001
    to_port     = 3001
    protocol    = "tcp"
    cidr_blocks = ["10.0.3.0/24"]
  }

  # Prometheus scrape from WireGuard peers
  ingress {
    description = "Prometheus scrape"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = ["10.0.3.0/24"]
  }

  # Loki from WireGuard peers
  ingress {
    description = "Loki"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = ["10.0.3.0/24"]
  }

  # Postgres — client access (e.g. pgAdmin) from WireGuard peers only,
  # same scoping as Prometheus/Loki above
  ingress {
    description = "Postgres"
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = ["10.0.3.0/24"]
  }

  # Redis — client access (e.g. RedisInsight) from WireGuard peers only,
  # same scoping as Postgres above
  ingress {
    description = "Redis"
    from_port   = 6379
    to_port     = 6379
    protocol    = "tcp"
    cidr_blocks = ["10.0.3.0/24"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "home-platform-ec2" }
}
