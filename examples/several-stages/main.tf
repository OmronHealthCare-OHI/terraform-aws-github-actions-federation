terraform {
  required_version = ">= 1.12.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.30"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.2"
    }
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}

# Several stages in one account, a workspace per <stage>-<region>: the shape
# connect-one-workload has in its non-prod accounts. This is the qa-eu
# workspace. The account holds dev, qa and stg, so the roles carry the stage
# (<repo>-qa-read, <repo>-qa-deploy). dev-eu owns what exists once per account
# (the OIDC provider, the permission boundaries) and once per repository (the
# release-tag ruleset, reviewer access, repository-level variables); this
# workspace reads the account resources and leaves the repository settings to
# dev-eu. See the README's "Several workspaces in one account".

variable "stage" {
  description = "The workspace's stage, from <stage>-<region>."
  type        = string
  default     = "qa"
}

provider "aws" {
  region              = "eu-central-1"
  allowed_account_ids = ["123456789012"]
}

provider "github" {
  owner = "OmronHealthCare-OHI"
}

module "label" {
  source = "github.com/OmronHealthCare-OHI/terraform-null-label?ref=1.0.0"

  namespace = "omron"
  region    = "eu"
  stage     = var.stage
}

data "aws_caller_identity" "current" {}

module "github_actions_federation" {
  source = "../.."

  account_key   = "${var.stage}-eu"
  account_id    = data.aws_caller_identity.current.account_id
  label_context = module.label.context

  stage                    = var.stage
  manage_account_resources = var.stage == "dev"

  # Every workspace of the configuration sees every workspace's consumers, so
  # the settings owner can build the repository-level settings from all of
  # them.
  github_oidc_consumers = {
    for key in ["dev-eu", "qa-eu", "stg-eu"] : key => {
      "example-baseline" = { manages_account_baseline = true, services = [] }
      "example-service"  = { services = ["lambda", "logs"] }
    }
  }
  repository_settings_owner        = "dev-eu"
  github_environment_reviewer_team = "cloud-foundations-in-connect-one-app"
}
