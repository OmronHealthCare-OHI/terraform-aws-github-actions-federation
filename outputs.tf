output "github_oidc_provider_arn" {
  description = "ARN of the GitHub Actions OIDC provider in this account, created here or, without manage_account_resources, read."
  value       = local.github_oidc_provider_arn
}

output "read_role_arn" {
  description = "ARN of each repository's <repo>-read role, keyed by repository. The plan role of the pull-request pipeline: it reads state through the read-only state role and writes nothing (the deploy pipeline plans with its deploy role). Goes in a repository-level GitHub Actions variable."
  value       = { for repo, role in aws_iam_role.cicd_read : repo => role.arn }
}

output "deploy_role_arn" {
  description = "ARN of each deploy role, keyed by deploy unit: the repository for its <repo>-deploy role, <repo>:<environment> for each <repo>-<environment>-deploy role of a repository with environments. Goes in DEPLOY_ROLE_ARN inside that role's GitHub Environment, never at repository level."
  value       = { for key, role in aws_iam_role.cicd_deploy : key => role.arn }
}

output "workspaces" {
  description = "The named Terraform workspaces declared for each repository in this account (github_oidc_consumers' workspaces), keyed by repository; an empty list means the default workspace only. Each is created once, empty and create-only, as env:/<workspace>/<repo> (workspaces.tf). A repository's own matrix must stay within this list: gha-terraform-backend selects a workspace, it never creates one."
  value       = { for repo, consumer in local.consumers : repo => consumer.workspaces }
}

output "github_app_installation_repositories" {
  description = "Every repository the two GitHub Apps must be installed on: each consumer in every account, because the plan reads each one's OIDC subject prefix and manages its Environment and variables with the Apps' tokens. The PR plan job compares this list with the plan App's installation and fails on any difference, missing or extra (CLF-93); the installation itself is changed by hand."
  value       = sort(local.all_consumer_repositories)
}

output "github_actions_settings" {
  description = "What each consuming repository has in GitHub, all managed by this configuration (CLF-93): each GitHub Environment a deploy role trusts (allow only main, require reviewers unless a stage turns them off; github-environments.tf) with its variables, keyed by Environment name under environments, and the repository-level ones (github-actions-variables.tf). Per repository: DEPLOY_ROLE_ARN in each Environment and <ACCOUNT>_READ_ROLE_ARN at repository level; for a manages_github repository, the ARNs of the GitHub App key secrets, which also hold each App's client ID (the apply key's in the Environment, the plan key's at repository level); once the state backend is known (state_bucket, state_region and both state role ARNs), gha-terraform-backend's TF_STATE_BUCKET, TF_STATE_REGION and TF_STATE_ROLE_ARN (the read-only state role) at repository level, and TF_STATE_ROLE_ARN (the read/write one) in the Environment."
  value       = local.github_actions_settings
}

output "permission_boundary_arns" {
  description = "ARN of each permission-boundary class's policy in this account, keyed by class name (permission-boundaries.tf). The same name and path in every account of the same label namespace and application: /boundaries/<namespace>-<application>-<class> (omron-shared-deploy, …). Created here or, without manage_account_resources, read. Empty when no classes are given."
  value       = local.class_boundary_arns
}
