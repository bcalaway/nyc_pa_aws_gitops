terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # Used once, in s3.tf, to force a real wait after the github_actions
    # role's S3 permissions are granted before the ansible_deploy bucket is
    # created -- IAM policy changes are eventually consistent (the API call
    # returning success doesn't mean the permission is enforced everywhere
    # yet), and a plain depends_on only orders the API *calls*, not the
    # propagation delay between them. See the circular-dependency incident
    # this bucket's creation hit in git log/PR history.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.11"
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
