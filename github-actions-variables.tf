# The GitHub Actions variables of every consumer in this account, managed here
# instead of set by hand (CLF-93, the variables part). github_actions_settings
# is built once, below, and feeds both the output and these resources, so the
# two cannot disagree.
#
# The Environments themselves are in github-environments.tf. A local apply uses
# GITHUB_TOKEN from `gh auth token`; the pipeline mints an App installation
# token from the App's key secret, which also holds its client ID (the
# workflows' half of CLF-93).

locals {
  # Per account: each account's read role gets its own variable, so a
  # repository that deploys into several accounts has one per account.
  read_role_variable_name = "${upper(replace(local.account_key, "-", "_"))}_READ_ROLE_ARN"

  github_actions_settings = {
    for repo in keys(local.consumers) :
    repo => {
      # Per Environment (one per deploy role: more than one for a repository
      # with environments), its variables.
      #
      # A repository that manages GitHub also gets a variable holding the ARN of
      # the secret its job reads the GitHub App key from: the apply App's in the
      # Environment, the plan App's at repository level, beside the role that
      # may read it. The secret also holds the App's client ID, which the job
      # mints its token with. GH_, not GITHUB_: GitHub reserves that prefix and
      # refuses to set such a variable.
      #
      # TF_STATE_* feed gha-terraform-backend. TF_STATE_ROLE_ARN is set twice
      # on purpose: at repository level the read-only state role, which every
      # job outside an Environment gets (PR plans, deploy plan jobs, as
      # <repo>-read); in the Environment the read/write one, which GitHub
      # prefers in the jobs that run there (the apply, as <repo>-deploy). The
      # state roles' trust admits only those callers, so a value in the wrong
      # scope fails at assume-role. The repository-level TF_STATE_* are the
      # same from every workspace, so only one workspace manages them
      # (repository_settings_owner, below).
      environments = {
        for key, unit in local.github_oidc_deploy_units :
        unit.environment => merge(
          { DEPLOY_ROLE_ARN = aws_iam_role.cicd_deploy[key].arn },
          contains(local.github_app_key_repositories, repo) ? { GH_APP_KEY_SECRET_ARN = var.github_app_key_arns.apply_secret_arn } : {},
          local.tf_state_published ? { TF_STATE_ROLE_ARN = var.state_role_arn } : {},
        ) if unit.repository == repo
      }
      repository_variables = merge(
        { (local.read_role_variable_name) = aws_iam_role.cicd_read[repo].arn },
        local.shared_repository_variables[repo],
      )
    }
  }

  # The repository-level variables whose value is the same from every account
  # workspace (the plan App key's secret ARN, the TF_STATE_* of the state
  # backend), for every consumer of every account: a repository that deploys
  # only into another account needs them just the same.
  all_consumer_repositories = distinct(flatten([for account, consumers in var.github_oidc_consumers : keys(consumers)]))
  github_managing_repositories = distinct(flatten([
    for account, consumers in var.github_oidc_consumers : [for repo, consumer in consumers : repo if consumer.manages_github]
  ]))
  shared_repository_variables = {
    for repo in local.all_consumer_repositories : repo => merge(
      var.github_app_key_arns != null && contains(local.github_managing_repositories, repo) ? { GH_APP_PLAN_KEY_SECRET_ARN = var.github_app_key_arns.plan_secret_arn } : {},
      local.tf_state_published ? {
        TF_STATE_BUCKET   = var.state_bucket
        TF_STATE_REGION   = var.state_region
        TF_STATE_ROLE_ARN = var.read_state_role_arn
      } : {},
    )
  }

  # Two workspaces managing the same variable would overwrite each other on
  # every apply. So the shared variables above, like the rest of the
  # repository-level settings (the tag ruleset, the reviewer team's access),
  # are managed only by the workspace named by repository_settings_owner, for
  # every consumer of every workspace; each workspace manages its own
  # read-role variable for its own consumers, whose name github_oidc_consumers
  # keeps unique per workspace. Environment variables are per workspace too:
  # each repository's Environment differs between workspaces (also enforced
  # in github_oidc_consumers).
  manages_repository_settings = local.account_key == var.repository_settings_owner

  # Keyed by the IDs the provider imports by: <repo>:<name> and
  # <repo>:<environment>:<name>.
  github_repository_variables = merge(
    {
      for repo in keys(local.consumers) :
      "${repo}:${local.read_role_variable_name}" => { repository = repo, name = local.read_role_variable_name, value = aws_iam_role.cicd_read[repo].arn }
    },
    local.manages_repository_settings ? merge([
      for repo, variables in local.shared_repository_variables : {
        for name, value in variables :
        "${repo}:${name}" => { repository = repo, name = name, value = value }
      }
    ]...) : {},
  )

  github_environment_variables = merge(flatten([
    for repo, settings in local.github_actions_settings : [
      for environment, variables in settings.environments : {
        for name, value in variables :
        "${repo}:${environment}:${name}" => { repository = repo, environment = environment, name = name, value = value }
      }
    ]
  ])...)
}

resource "github_actions_variable" "consumer" {
  for_each = local.github_repository_variables

  repository    = each.value.repository
  variable_name = each.value.name
  value         = each.value.value
}

resource "github_actions_environment_variable" "consumer" {
  for_each = local.github_environment_variables

  # A new consumer's Environment must exist before its variables can be set.
  depends_on = [github_repository_environment.consumer]

  repository    = each.value.repository
  environment   = each.value.environment
  variable_name = each.value.name
  value         = each.value.value
}
