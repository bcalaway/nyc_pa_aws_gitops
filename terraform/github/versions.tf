# GitHub repositories for registry apps (ADR-0030): one repo per app in
# apps/registry.yml, with the platform's standard settings.
#
# A separate stack and state from terraform/aws on purpose: the GitHub admin
# token exists only in this stack's apply (.github/workflows/terraform-github.yml,
# `production` environment), and AWS credentials here only reach the state
# bucket. A mistake in one can't touch the other.

terraform {
  required_version = ">= 1.10"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }

  backend "s3" {
    bucket       = "home-platform-terraform-state-147856894209"
    key          = "github/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
    encrypt      = true
  }
}

# Token from the GITHUB_TOKEN environment variable: a read-only fine-grained
# PAT for PR plans, an admin one for applies (ADR-0030). Both are kept in SSM
# (/home-platform/github/terraform-{read,admin}-token) and copied to Actions
# secrets; the workflow reads the secrets, no AWS role reads the SSM copies.
provider "github" {
  owner = "bcalaway"
}
