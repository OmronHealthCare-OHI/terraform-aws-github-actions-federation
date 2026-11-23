terraform {
  # 1.12.0 is the oldest release the test suite passes on: before it, a test
  # condition over a mocked aws_iam_policy_document's statements is unknown at
  # plan, so the boundary-deny run fails on 1.10 and 1.11 and every later run
  # in the file is skipped. A floor the tests don't pass on is a claim nobody
  # checks. The other floors in play are lower: cross-variable validation
  # (1.9), optional() object attributes (1.3) and the OMRON null-label (1.3).
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
    # Reads each consumer's OIDC subject prefix (github-oidc-subjects.tf) and
    # manages its deploy Environment (github-environments.tf) and GitHub
    # Actions variables (github-actions-variables.tf). Not a hashicorp
    # provider, so every module that uses it names the source.
    github = {
      source  = "integrations/github"
      version = "~> 6.13"
    }
  }
}
