# GitHub Actions OIDC provider in this account.
#
# One per account, created by the repository that owns the account's baseline
# (decision 1 of the federation brief, 2026-09-30): every role in this account
# federates against the account-local provider, and no pipeline crosses accounts
# to log in. AWS has managed the trust for the GitHub issuer itself since 2023
# and no longer consults thumbprint_list, but the resource still requires a
# non-empty value, so it is read from the discovery endpoint as in
# Luscii/vitals-workload-infrastructure. ignore_changes keeps GitHub's leaf
# certificate rotations out of the plan.
#
# Only the configuration that owns the account's resources creates it
# (manage_account_resources); every other one reads it, at the fixed ARN a
# GitHub provider has in any account, and checks its audience.

module "github_oidc_label" {
  source = "github.com/OmronHealthCare-OHI/terraform-null-label?ref=1.0.0"

  context    = var.label_context
  attributes = ["github", "oidc"]
}

data "tls_certificate" "github" {
  count = var.manage_account_resources ? 1 : 0

  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  count = var.manage_account_resources ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github[0].certificates[0].sha1_fingerprint]

  tags = module.github_oidc_label.tags

  lifecycle {
    ignore_changes = [thumbprint_list]
  }
}

# A single instance before manage_account_resources: existing state moves
# without replacing the provider every role trusts.
moved {
  from = aws_iam_openid_connect_provider.github
  to   = aws_iam_openid_connect_provider.github[0]
}

# Created by the owner. Every role here trusts the sts.amazonaws.com audience
# only, so a provider without it would accept none of their tokens: an apply
# that succeeds and a first login that fails.
data "aws_iam_openid_connect_provider" "github" {
  count = var.manage_account_resources ? 0 : 1

  arn = local.oidc_provider_arn

  lifecycle {
    postcondition {
      condition     = contains(self.client_id_list, "sts.amazonaws.com")
      error_message = "The GitHub OIDC provider in account ${var.account_id} doesn't accept the sts.amazonaws.com audience (it has: ${join(", ", self.client_id_list)}), which every role here trusts. Add it on the provider's owner first."
    }
  }
}

locals {
  github_oidc_provider_arn = (
    var.manage_account_resources
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}
