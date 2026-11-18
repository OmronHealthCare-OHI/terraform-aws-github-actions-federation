# Named Terraform workspaces, declared per consumer (github_oidc_consumers'
# workspaces) and created here before their first plan (CLF-96).
#
# Why here: a repository's plan job runs first, as <repo>-read, through the
# read-only state role (CLF-88), and gha-terraform-backend only ever selects a
# workspace, never creates one. A named workspace exists only once its state
# object env:/<workspace>/<repo> does, so without this a new workspace's first
# plan fails at `workspace select` and no saved plan can ever be applied. The
# declaration sits beside the repository's roles and Environments, reviewed in
# the same place.
#
# How: shared-cicd-infrastructure's workspace provisioner (CLF-95), which only
# the baseline repository's deploy role may assume, with its own ohi:repository
# session tag. It may put env:/*/* and nothing else, and the state bucket
# refuses every put of it without If-None-Match, so it can create a missing
# state and never overwrite a live one. The AWS provider sends no
# If-None-Match on aws_s3_object, so the put is a CLI call
# (scripts/create-workspace-state.sh), which treats 412 PreconditionFailed as
# "already there".
#
# Create-only, here too: the resource runs its script once, at creation.
# Removing a workspace from the list destroys only the resource, never the
# state; decommissioning a workspace is a deliberate, separate step.
#
# Only through the pipeline: the provisioner trusts the baseline's deploy role
# alone, so a local apply (any other identity) cannot create a workspace.

locals {
  # Keyed <repo>:<workspace>; the value is the state key it creates.
  workspace_states = merge([
    for repo, consumer in local.consumers : {
      for workspace in consumer.workspaces :
      "${repo}:${workspace}" => { repository = repo, workspace = workspace, key = "env:/${workspace}/${repo}" }
    }
  ]...)

  # The provisioner and the bucket must both be known before anything can be
  # created. Until then the declaration is kept and the check below says so.
  workspaces_creatable = var.workspace_provisioner_role_arn != "" && var.state_bucket != "" && var.state_region != ""
}

# The grant to assume the provisioner, for the baseline repository's deploy
# role only: its trust admits that role alone, and no other repository creates
# another's workspace. Own policy, separately revocable. The baseline has a
# single deploy role (no environments; variables.tf), keyed by repository.
data "aws_iam_policy_document" "cicd_assume_workspace_provisioner" {
  count = var.workspace_provisioner_role_arn == "" ? 0 : 1

  statement {
    sid       = "assumeWorkspaceProvisionerWithRepositoryTag"
    effect    = "Allow"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [var.workspace_provisioner_role_arn]
  }
}

resource "aws_iam_role_policy" "cicd_deploy_assume_workspace_provisioner" {
  for_each = var.workspace_provisioner_role_arn == "" ? toset([]) : toset(local.baseline_repositories)

  name   = "assume-workspace-provisioner"
  role   = aws_iam_role.cicd_deploy[each.key].id
  policy = data.aws_iam_policy_document.cicd_assume_workspace_provisioner[0].json
}

resource "terraform_data" "workspace_state" {
  for_each = local.workspaces_creatable ? local.workspace_states : {}

  # The for_each key, <repo>:<workspace>, makes a renamed workspace a new
  # resource (and a new state), never a rewrite of the old one. input only
  # records the state key the record creates, for the plan and the tests.
  input = each.value.key

  # create_workspace_states (variables.tf) is a test switch: off, the record
  # is created but the AWS call is skipped. Turning it back on replaces every
  # record, so its creation runs, and a state skipped while it was off is
  # created then. 412 makes that harmless for states that already exist.
  triggers_replace = var.create_workspace_states

  provisioner "local-exec" {
    command = var.create_workspace_states ? "${path.module}/scripts/create-workspace-state.sh" : "true"

    environment = {
      PROVISIONER_ROLE_ARN = var.workspace_provisioner_role_arn
      REPOSITORY_TAG       = one(local.baseline_repositories)
      STATE_BUCKET         = var.state_bucket
      STATE_REGION         = var.state_region
      STATE_KEY            = each.value.key
    }
  }

  # The grant is new in the same apply as a first workspace; the script
  # retries the assume while IAM catches up.
  depends_on = [aws_iam_role_policy.cicd_deploy_assume_workspace_provisioner]
}

check "declared_workspaces_can_be_created" {
  assert {
    condition     = length(local.workspace_states) == 0 || local.workspaces_creatable
    error_message = "Workspaces are declared (${join(", ", keys(local.workspace_states))}) but not created: workspace_provisioner_role_arn, state_bucket and state_region must all be set. Their repositories' first plan fails at `workspace select` until then."
  }
}
