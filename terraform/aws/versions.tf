terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket       = "home-platform-terraform-state-147856894209"
    key          = "aws/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      Project    = "home-platform"
      ManagedBy  = "terraform"
      Repository = "nyc_pa_aws_gitops"
    }
  }
}
