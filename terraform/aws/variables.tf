variable "aws_account_id" {
  description = "AWS account ID"
  type        = string
  default     = "147856894209"
}

variable "github_org" {
  description = "GitHub organization or username"
  type        = string
  default     = "bcalaway"
}

variable "github_repo" {
  description = "GitHub repository name"
  type        = string
  default     = "nyc_pa_aws_gitops"
}

variable "ec2_instance_type" {
  description = "EC2 instance type for the hub"
  type        = string
  default     = "t3.medium"
}

variable "ec2_key_name" {
  description = "EC2 key pair name for SSH access"
  type        = string
  default     = "home-platform"
}
