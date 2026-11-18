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

# One account, one workspace: the shape shared-workload has. This instance
# owns the account's OIDC provider and permission boundaries
# (manage_account_resources defaults to true) and the consumers'
# repository-level settings.

provider "aws" {
  region              = "us-west-2"
  allowed_account_ids = ["123456789012"]
}

provider "github" {
  owner = "OmronHealthCare-OHI"
}

# The caller owns the label. The module needs a namespace from it.
module "label" {
  source = "github.com/OmronHealthCare-OHI/terraform-null-label?ref=1.0.0"

  namespace   = "omron"
  application = "shared"
  name        = "cicd"
  aws_region  = "us-west-2" # tag only; not part of the id
}

data "aws_caller_identity" "current" {}

# aws-organization's shared_permission_boundaries output in practice: the
# deploy, read and service classes. Without them the consumers' roles, and the
# roles they create, carry no boundary. The classes must cover every
# consumer's services (here lambda and logs).
variable "permission_boundaries" {
  description = "The permission-boundary classes, keyed by class name."
  type        = any
}

module "github_actions_federation" {
  source = "../.."

  account_key   = "cicd"
  account_id    = data.aws_caller_identity.current.account_id
  label_context = module.label.context

  github_oidc_consumers = {
    cicd = {
      # The repository whose deploy role applies this configuration.
      "example-baseline" = { manages_account_baseline = true, services = [] }
      "example-service"  = { services = ["lambda", "logs"] }
    }
  }
  repository_settings_owner        = "cicd"
  github_environment_reviewer_team = "cloud-foundations-in-connect-one-app"
  permission_boundaries            = var.permission_boundaries
}
