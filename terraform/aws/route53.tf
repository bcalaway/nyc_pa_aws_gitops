resource "aws_route53_zone" "main" {
  name = "billandjessie.com"

  tags = { Name = "billandjessie.com" }
}

output "route53_name_servers" {
  description = "NS records to set at Network Solutions registrar"
  value       = aws_route53_zone.main.name_servers
}
