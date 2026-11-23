# Each consumer's reviewer team and its access to the repository.
#
# Every consumer's deploy Environment requires its reviewer team's approval
# (github-environments.tf): the consumer's reviewer_team, or by default
# github_environment_reviewer_team. GitHub drops a required reviewer that can't see
# the repository, and refuses an Environment with prevent_self_review and no
# reviewer left (422 "Required reviewers must have at least one reviewer to set
# prevent_self_review"). That stopped the first apply that added
# shared-terraform-registry (2026-10-20), until the team was granted access by
# hand. So the access is managed here, and each Environment waits for it.
#
# A repository setting, the same from every workspace, so only the workspace
# named by repository_settings_owner manages it, for every consumer of every
# workspace (github-actions-variables.tf, the same rule as the
# release-tags rulesets). An Environment in another account's workspace can't
# depend on it across workspaces: apply that workspace first when a consumer
# is new.
#
# GitHub's PUT is idempotent, so a grant made by hand with the same permission
# is adopted unchanged; the three that existed when this was added (maintain on
# shared-workload, shared-cicd-infrastructure and shared-terraform-registry)
# plan as creates that change nothing.
#
# Both GitHub Apps need the organization's "Members: read" permission: the
# team lookup below needs it, and so does reading a team's repository
# permission in every plan.

locals {
  # This account's consumers: each repository's reviewer team, its own
  # reviewer_team or the default. Its Environments require it
  # (github-environments.tf).
  reviewer_team_of = {
    for repo, consumer in local.consumers :
    repo => coalesce(consumer.reviewer_team, var.github_environment_reviewer_team)
  }

  # Every repository and its reviewer team across every account, keyed
  # <repo>/<team>. A repository in two accounts with two different teams
  # grants both.
  reviewer_team_grants = {
    for grant in distinct(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : {
          repository = repo
          team       = coalesce(consumer.reviewer_team, var.github_environment_reviewer_team)
        }
      ]
    ])) : "${grant.repository}/${grant.team}" => grant
  }

  # One lookup per team in use, the default included.
  reviewer_teams = toset(concat([var.github_environment_reviewer_team], [for grant in values(local.reviewer_team_grants) : grant.team]))
}

data "github_team" "reviewers" {
  for_each = local.reviewer_teams

  slug = each.key

  # The team itself only: no member or repository lists, which this
  # configuration never reads.
  summary_only = true
}

resource "github_team_repository" "reviewers" {
  for_each = local.manages_repository_settings ? local.reviewer_team_grants : {}

  team_id    = data.github_team.reviewers[each.value.team].id
  repository = each.value.repository
  permission = var.github_environment_reviewer_team_permission
}
