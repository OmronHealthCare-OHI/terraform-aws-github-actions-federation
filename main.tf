# The GitHub Actions federation of one AWS account: the OIDC provider, a read
# and a deploy role per consuming repository, and the GitHub side of each
# (Environments, Actions variables, the release-tag ruleset, reviewer access),
# plus the create-only Terraform workspaces the consumers declare.
#
# The calling configuration selects the account (account_key, account_id) and
# owns the providers: the aws provider must already run in that account, and
# the github provider in github_organization. Nothing here reads the
# workspace.

locals {
  account_key = var.account_key

  # The repositories that deploy into THIS account, out of the per-account map.
  consumers = lookup(var.github_oidc_consumers, local.account_key, {})

  # The stage in the pipeline role names, only where stages share an account
  # (var.stage): <repo><stage_infix>-read, <repo><stage_infix>-deploy.
  stage_infix           = var.stage == null ? "" : "-${var.stage}"
  baseline_repositories = [for repo, consumer in local.consumers : repo if consumer.manages_account_baseline]

  # The state backend is published only once all four are known: a partial
  # set would hand a job a bucket without a role, or a read-only role
  # without the read/write one that its apply needs.
  tf_state_published = alltrue([
    var.state_bucket != "",
    var.state_region != "",
    var.state_role_arn != "",
    var.read_state_role_arn != "",
  ])
}
