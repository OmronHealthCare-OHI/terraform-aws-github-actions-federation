# Per-repository GitHub Actions read roles: <repo>-read at /cicd/gha/
# (<repo>-<stage>-read with a stage, main.tf).
#
# Companion to the deploy roles in github-oidc-role-deploy.tf. Trusted by ANY
# OIDC token from the repository (<prefix>:* under StringLike, where <prefix>
# is GitHub's subject prefix for it, github-oidc-subjects.tf), so a
# pull request's plan job can assume it. Read-only is therefore the ceiling of
# what a PR can do: a workflow the PR itself rewrites still cannot change
# anything.
#
# Permissions: the IAM read baseline, Get*/List*/Describe* on the repository's
# services, and sts:AssumeRole on shared-cicd-infrastructure's READ-ONLY state
# role, so the plan can read state (with -lock=false: that role takes no
# lock). Never the read/write state role, whose trust refuses <repo>-read
# roles anyway (CLF-88). An explicit deny on
# secretsmanager:GetSecretValue closes the one read that is an exfiltration
# (with one exception: the plan GitHub App's key, for manages_github
# repositories, github-app-keys-access.tf), and an explicit deny on the
# permission-boundary policies restates the rule that only this repository
# touches those.
#
# Its permission boundary is the read class (CLF-54; permission-boundaries.tf),
# not the deploy class as in the reference: a pull request can assume this role
# by rewriting its own workflow, so its ceiling is read-only too, not only its
# policy.

locals {
  github_oidc_read_subject = {
    for repo in keys(local.consumers) :
    repo => "${local.github_oidc_subject_prefix[repo]}:*"
  }
}

data "aws_iam_policy_document" "cicd_read_assume_role" {
  for_each = local.consumers

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike: the wildcard admits every sub shape GitHub emits (branch, tag,
    # pull_request, environment:*) while the repository's prefix (with or
    # without its immutable IDs) stays anchored, so another repository's token
    # never matches.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_oidc_read_subject[each.key]]
    }
  }
}

resource "aws_iam_role" "cicd_read" {
  for_each = local.consumers

  name               = "${each.key}${local.stage_infix}-read"
  path               = "/${var.cicd_roles_path}/${var.github_oidc_path}/"
  description        = "GitHub Actions read role for ${var.github_organization}/${each.key}: PR plans."
  assume_role_policy = data.aws_iam_policy_document.cicd_read_assume_role[each.key].json

  # The read class (permission-boundaries.tf): read-only by construction,
  # whatever a branch's code asks for. None while no classes are given.
  permissions_boundary = local.boundaries_enabled ? local.class_boundary_arns["read"] : null

  tags = { Name = "${each.key}${local.stage_infix}-read", (local.repository_tag_key) = each.key }
}

# IAM read on every principal: terraform plan refreshes the roles and policies
# this account holds, and read-only IAM is not an escalation path.
data "aws_iam_policy_document" "cicd_read_iam_baseline" {
  #checkov:skip=CKV_AWS_356: IAM read on * is required for terraform plan to refresh adjacent principals; not an escalation path.

  statement {
    sid    = "iamRead"
    effect = "Allow"
    actions = [
      "iam:Get*",
      "iam:List*",
      "iam:GenerateServiceLastAccessedDetails",
      "iam:GenerateCredentialReport",
      "iam:SimulateCustomPolicy",
      "iam:SimulatePrincipalPolicy",
    ]
    resources = ["*"]
  }
}

data "aws_iam_policy_document" "cicd_read_permissions" {
  for_each = local.consumers

  #checkov:skip=CKV_AWS_356: Resource ARNs churn across plans; * is intentional for read-only describes on the enumerated services.

  source_policy_documents = [data.aws_iam_policy_document.cicd_read_iam_baseline.json]

  # Whatever the deploy role can apply, this role can plan: the same service
  # list, read verbs only. A verb a service does not have grants nothing.
  dynamic "statement" {
    for_each = length(each.value.services) > 0 ? [1] : []

    content {
      sid    = "serviceRead"
      effect = "Allow"
      actions = flatten([
        for svc in each.value.services : [
          "${svc}:Get*",
          "${svc}:List*",
          "${svc}:Describe*",
        ]
      ])
      resources = ["*"]
    }
  }

  # The trust policy admits any workflow in the repository, so the read a PR
  # must never get is a secret's value. Deny beats every Allow above, however
  # the services list evolves.
  #
  # One exception, for a repository that manages GitHub (manages_github) once
  # the keys exist: the plan GitHub App's key, and only that secret. That key
  # mints a read-only GitHub token, which is what a PR's plan needs to refresh
  # GitHub resources (github-app-keys-access.tf). NotResource names the full
  # secret ARN, so any other secret, the apply App's key included, stays
  # denied.
  dynamic "statement" {
    for_each = contains(local.github_app_key_repositories, each.key) ? [] : [1]

    content {
      sid       = "denySecretRetrieval"
      effect    = "Deny"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = ["*"]
    }
  }

  dynamic "statement" {
    for_each = contains(local.github_app_key_repositories, each.key) ? [1] : []

    content {
      sid           = "denySecretRetrievalButThePlanGithubAppKey"
      effect        = "Deny"
      actions       = ["secretsmanager:GetSecretValue"]
      not_resources = [var.github_app_key_arns.plan_secret_arn]
    }
  }

  # Likewise a table's contents: dynamodb:Get* above admits GetItem, and
  # GetShardIterator with GetRecords, which read every item a stream carries.
  # A plan needs none of these (a table refreshes through Describe*, List* and
  # GetResourcePolicy), so every read role is denied all of DynamoDB's data
  # reads, whether or not it lists dynamodb today. Managing items with
  # aws_dynamodb_table_item would need GetItem: then lift it for that
  # repository only, the way the plan App's key is lifted above.
  statement {
    sid    = "denyTableDataReads"
    effect = "Deny"
    actions = [
      "dynamodb:BatchGetItem",
      "dynamodb:GetItem",
      "dynamodb:GetRecords",
      "dynamodb:GetShardIterator",
      "dynamodb:PartiQLSelect",
      "dynamodb:Query",
      "dynamodb:Scan",
    ]
    resources = ["*"]
  }

  # Permission boundaries are created, changed and deleted by this repository
  # alone (github-oidc-role-deploy.tf). A read role grants no write anyway; the
  # deny keeps the rule true whatever the grants above become.
  dynamic "statement" {
    for_each = each.value.manages_account_baseline ? [] : [1]

    content {
      sid       = "denyPermissionBoundaryChanges"
      effect    = "Deny"
      actions   = concat(local.iam_policy_write_actions, local.iam_role_boundary_actions)
      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "cicd_read_permissions" {
  for_each = local.consumers

  name   = "${each.key}-read-permissions"
  role   = aws_iam_role.cicd_read[each.key].id
  policy = data.aws_iam_policy_document.cicd_read_permissions[each.key].json
}

# State: shared-cicd-infrastructure has two state roles (CLF-88).
#
#   read/write  for <repo>-deploy (github-oidc-role-deploy.tf): reads every
#               state and writes only the state of the repository named by the
#               session tag (key = <repo>; per workspace env:/<workspace>/<repo>).
#               Only jobs bound to a GitHub Environment use it: from main
#               only, approved unless a stage sets requires_approval = false.
#   read-only   for <repo>-read, here: reads every state, writes nothing, takes
#               no lock. Every job outside the Environment plans through it
#               with -lock=false: pull-request plans, and the deploy plan job
#               whose saved plan the apply then applies through the read/write
#               role (the backend names a profile, not a role, so the plan
#               carries no role). A pull request can assume the read role by
#               rewriting its own workflow, so it must never reach a role that
#               writes state.
#
# Both trusts require the session tag to equal the caller's own
# ohi:repository tag, so sts:TagSession beside sts:AssumeRole:
# gha-terraform-backend assumes the state role with
# ohi:repository = <repo> as the session tag.
# Each in its own policy, so revoking state access for one role never touches
# the other. Absent while the matching ARN is empty, which is only the case
# before shared-cicd-infrastructure has applied that role.
data "aws_iam_policy_document" "cicd_assume_state" {
  count = var.state_role_arn == "" ? 0 : 1

  statement {
    sid       = "assumeStateRoleWithRepositoryTag"
    effect    = "Allow"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [var.state_role_arn]
  }
}

data "aws_iam_policy_document" "cicd_assume_read_state" {
  count = var.read_state_role_arn == "" ? 0 : 1

  statement {
    sid       = "assumeReadOnlyStateRoleWithRepositoryTag"
    effect    = "Allow"
    actions   = ["sts:AssumeRole", "sts:TagSession"]
    resources = [var.read_state_role_arn]
  }
}

resource "aws_iam_role_policy" "cicd_read_assume_state_access" {
  for_each = var.read_state_role_arn == "" ? {} : local.consumers

  name   = "assume-state"
  role   = aws_iam_role.cicd_read[each.key].id
  policy = data.aws_iam_policy_document.cicd_assume_read_state[0].json
}
