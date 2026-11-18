# The GitHub Environment of every consumer in this account, the one its deploy
# role trusts (CLF-93): only main may deploy, and the reviewer team approves.
# Created by hand on 2026-10-01 and imported as they were on 2026-10-15; admins
# may still bypass the reviewers.
#
# Releases deploy (decided 2026-10-16, the OMRON/Luscii standard), but from
# main: deploy.yml runs only on main, dispatched with the release's tag, and
# applies that tag's code once it has checked the tag is on main. A workflow
# that runs on a tag is the tagged commit's own, which anyone who can write can
# make, so a tag is never what this Environment admits. The version tags
# themselves cannot be moved (github-repository-rulesets.tf).
#
# Whoever starts a deployment may not approve it (prevent_self_review, decided
# 2026-10-16), for a deploy dispatched by hand. A release, scheduled or
# published by hand, is dispatched by github-actions[bot], so any reviewer may
# approve it.
#
# One Environment per deploy role (github_oidc_consumers' environment
# defaults to the account key), so account workspaces never manage the same
# one. A repository with environments has one per stage; a stage may drop the
# reviewers (requires_approval = false: a test stage, deploying straight from
# main), never the main-only policy below. Without reviewers there is no
# approval to self-review, so prevent_self_review follows requires_approval.

resource "github_repository_environment" "consumer" {
  for_each = local.github_oidc_deploy_units

  # The repository's reviewer team must see it before it can be a required
  # reviewer (github-team-access.tf).
  depends_on = [github_team_repository.reviewers]

  repository          = each.value.repository
  environment         = each.value.environment
  can_admins_bypass   = true
  prevent_self_review = each.value.requires_approval

  dynamic "reviewers" {
    for_each = each.value.requires_approval ? [1] : []

    content {
      teams = [tonumber(data.github_team.reviewers[local.reviewer_team_of[each.value.repository]].id)]
    }
  }

  # Custom branch policies, not "protected branches": the one allowed branch
  # is named below, whatever the branch protection says.
  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "main" {
  for_each = local.github_oidc_deploy_units

  repository     = each.value.repository
  environment    = github_repository_environment.consumer[each.key].environment
  branch_pattern = "main"
}

# Terraform manages the one policy above and cannot see any other: a branch or
# tag policy added in GitHub would let that ref deploy while every plan showed
# no drift. So each plan reads the Environment's whole policy list and fails
# unless it is exactly the main branch policy. An extra policy is removed by
# hand; this only makes it visible.
#
# depends_on: for a new consumer the Environment does not exist yet at plan,
# so the read waits for the apply that creates it (and its policy). Nothing
# reads its result: it exists for its postconditions, which TFLint cannot see.
# tflint-ignore: terraform_unused_declarations
data "github_rest_api" "deployment_policies" {
  for_each = local.github_oidc_deploy_units

  # urlencode writes a space as "+", which a URL path reads as a literal plus;
  # a "+" in the name is already %2B by then, so only spaces become %20.
  endpoint = "repos/${var.github_organization}/${each.value.repository}/environments/${replace(urlencode(each.value.environment), "+", "%20")}/deployment-branch-policies"

  depends_on = [github_repository_environment_deployment_policy.main]

  lifecycle {
    postcondition {
      condition     = self.code == 200
      error_message = "GitHub answered ${self.code} for the deployment policies of ${var.github_organization}/${each.value.repository}'s ${each.value.environment} Environment: it must exist, and the token must reach it."
    }

    postcondition {
      condition = try(
        jsondecode(self.body).total_count == 1
        && jsondecode(self.body).branch_policies[0].name == "main"
        && jsondecode(self.body).branch_policies[0].type == "branch",
        false,
      )
      error_message = "${var.github_organization}/${each.value.repository}'s ${each.value.environment} Environment allows more than the main branch to deploy: ${join(", ", [for p in try(jsondecode(self.body).branch_policies, []) : "${p.type} ${p.name}"])}. Remove every policy but main in GitHub."
    }
  }
}
