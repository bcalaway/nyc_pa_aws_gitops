output "hub_elastic_ip" {
  description = "Elastic IP of the EC2 hub"
  value       = aws_eip.hub.public_ip
}

output "hub_instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.hub.id
}

output "github_actions_role_arn" {
  description = "IAM role ARN for GitHub Actions OIDC"
  value       = aws_iam_role.github_actions.arn
}

output "logs_bucket" {
  description = "S3 bucket for logs and backups"
  value       = aws_s3_bucket.logs.bucket
}

output "portal_bucket" {
  description = "S3 bucket for portal static site"
  value       = aws_s3_bucket.portal.bucket
}

output "portal_cloudfront_distribution_id" {
  description = "CloudFront distribution ID for the portal (used for cache invalidation)"
  value       = aws_cloudfront_distribution.portal.id
}

output "portal_cloudfront_domain" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.portal.domain_name
}
