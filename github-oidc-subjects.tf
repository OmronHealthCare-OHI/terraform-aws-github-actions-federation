# The OIDC subject GitHub puts in each consumer's tokens, read from GitHub
# instead of built from the repository's name.
#
# A role's trust compares the token's sub claim with a pattern, and that claim
# does not always start with repo:<org>/<repo>. Repositories created after
# 2026-07-15 get GitHub's immutable subject by default, with the owner's and
# the repository's numeric IDs: repo:<org>@<owner-id>/<repo>@<repo-id>. Older
# ones keep the name-only form unless they opt in, and a rename or transfer
# switches them. The IDs are what makes the immutable form safer: a deleted or
# renamed organization or repository can be registered again under the same
# name by anyone, but never with the same ID.
#
# GitHub publishes the prefix it uses per repository
# (actions/oidc/customization/sub, sub_claim_prefix), so the trusts here take
# it from there: adding a consumer still takes only its name, both forms work,
# and a repository that switches shows up as a trust change in the next plan.
#
# The lookup needs a GitHub token: GITHUB_TOKEN, from `gh auth token` for a
# local run, or from the GitHub App's installation token in the pipeline (the
# App must be installed on every consumer, which managing their GitHub settings
# needs anyway).
data "github_rest_api" "oidc_subject" {
  for_each = local.consumers

  endpoint = "repos/${var.github_organization}/${each.key}/actions/oidc/customization/sub"

  lifecycle {
    # A missing repository comes back as a 404 body, not as an error.
    postcondition {
      condition     = self.code == 200
      error_message = "GitHub answered ${self.code} for ${var.github_organization}/${each.key}'s OIDC subject: the repository must exist, and the token must reach it (installed GitHub App, or a token with access)."
    }

    # A custom template replaces the default sub claim with chosen claim
    # keys, so it no longer starts with a repository prefix.
    postcondition {
      condition     = try(jsondecode(self.body).use_default, false) == true
      error_message = "${var.github_organization}/${each.key} uses a custom OIDC subject template; the trusts here assume GitHub's default subject (with or without immutable IDs)."
    }

    # The prefix must name this repository in this organization, with or
    # without IDs, so a wrong answer can never widen a trust.
    postcondition {
      condition     = replace(try(jsondecode(self.body).sub_claim_prefix, ""), "/@[0-9]+/", "") == "repo:${var.github_organization}/${each.key}"
      error_message = "GitHub's OIDC subject prefix for ${var.github_organization}/${each.key} is \"${try(jsondecode(self.body).sub_claim_prefix, "")}\": not repo:${var.github_organization}[@<id>]/${each.key}[@<id>]."
    }
  }
}

locals {
  # repo:<org>[@<owner-id>]/<repo>[@<repo-id>], per consumer.
  github_oidc_subject_prefix = {
    for repo, subject in data.github_rest_api.oidc_subject :
    repo => jsondecode(subject.body).sub_claim_prefix
  }
}
