# Per-repository GitHub Actions deploy roles: <repo>-deploy at /cicd/gha/.
#
# One role per consumer, trusted by exactly one OIDC subject:
# <prefix>:environment:<environment>, under StringEquals, where <prefix> is
# GitHub's subject prefix for the repository (github-oidc-subjects.tf). Only a job
# bound to that GitHub Environment gets the token, and the Environment allows
# only main and requires reviewers, so every apply passes a human gate that a
# pull request cannot rewrite. Deliberately unlike the Luscii reference, which
# also lets pull_request tokens assume the deploy role on its test stage.
#
# A consumer that lists environments (one per stage) gets one role per entry
# instead, <repo>-<environment>-deploy, each trusting only its own
# Environment. Every role below is keyed by its deploy unit: the repository
# name for a single-Environment consumer, so existing roles keep their
# addresses, and <repo>:<environment> for the others. The units share the
# repository's services and IAM path: separate gates and audit trails, not
# isolation within the account.
#
# Permissions, per the reference's "repository as the integrity gate" stance:
#   - the IAM read baseline and creating service-linked roles, for everyone;
#   - <svc>:* on the repository's enumerated services, broad within the account;
#   - IAM writes on the repository's own path only, /services/<repo>/;
#   - an explicit deny on the role's own ARN, so it cannot widen itself;
#   - an explicit deny on the permission-boundary policies at /boundaries/ and
#     on attaching or removing a boundary: only this repository manages
#     boundaries, every other repository in the account is denied it outright;
#   - sts:AssumeRole and sts:TagSession on shared-cicd-infrastructure's state
#     role, in its own policy (github-oidc-role-read.tf, shared by both roles).
#
# The repository that applies THIS configuration (manages_account_baseline) is
# the exception: its deploy role also manages the OIDC provider, the roles at
# /cicd/gha/ and the permission-boundary policies, and it is not denied
# changing itself, because maintaining these roles is its job. Its gate is the
# Environment's reviewers.
#
# Permission boundaries (CLF-54; permission-boundaries.tf), once the classes
# are given: every consumer's deploy role carries the deploy class and the
# baseline repository's its own <repo>-baseline boundary. iam:CreateRole on
# /services/<repo>/ requires the service class, so every role a consumer
# creates is born bounded; on /cicd/gha/ it requires the deploy or read class,
# and attaching a boundary there accepts only those two.

locals {
  # The repository a pipeline role speaks for, on both its roles. The backend
  # passes it as the session tag when assuming shared-cicd-infrastructure's
  # state role, whose trust requires the two to be equal, and which then writes
  # only the repository's own state objects (key = <repo>). Only this
  # repository can set it: a consumer's deploy role may create and tag roles
  # under /services/<repo>/ only, so a role it
  # makes may carry any tag but never sits at /cicd/gha/, and it cannot tag the
  # roles here at all.
  repository_tag_key = "ohi:repository"

  # One entry per deploy role: the repository and the Environment it applies
  # through, the role's name, and whether that Environment requires the
  # reviewer team (github-environments.tf).
  github_oidc_deploy_units = merge([
    for repo, consumer in local.consumers : (
      consumer.environments == null
      ? {
        (repo) = {
          repository        = repo
          environment       = coalesce(consumer.environment, local.account_key)
          role_name         = "${repo}${local.stage_infix}-deploy"
          requires_approval = true
        }
      }
      : {
        for environment, settings in consumer.environments :
        "${repo}:${environment}" => {
          repository        = repo
          environment       = environment
          role_name         = "${repo}${local.stage_infix}-${environment}-deploy"
          requires_approval = settings.requires_approval
        }
      }
    )
  ]...)

  # An Environment name holds no ":" and no "%" (variables.tf), so it appears
  # in the sub claim exactly as configured. GitHub would write a ":" as %3A
  # and leave "%" alone, which let production:v2 and production%3Av2 share one
  # subject; both are rejected instead of encoded.
  github_oidc_deploy_subject = {
    for key, unit in local.github_oidc_deploy_units :
    key => "${local.github_oidc_subject_prefix[unit.repository]}:environment:${unit.environment}"
  }

  # Split per resource type so no statement grants an action on a resource it
  # can never apply to (a policy action on a role ARN is dead policy at best).
  iam_role_write_actions = [
    "iam:DeleteRole",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:UpdateAssumeRolePolicy",
    "iam:AttachRolePolicy",
    "iam:DetachRolePolicy",
    "iam:PutRolePolicy",
    "iam:DeleteRolePolicy",
    "iam:TagRole",
    "iam:UntagRole",
  ]

  iam_policy_write_actions = [
    "iam:CreatePolicy",
    "iam:DeletePolicy",
    "iam:CreatePolicyVersion",
    "iam:DeletePolicyVersion",
    "iam:SetDefaultPolicyVersion",
    "iam:TagPolicy",
    "iam:UntagPolicy",
  ]

  iam_instance_profile_write_actions = [
    "iam:CreateInstanceProfile",
    "iam:DeleteInstanceProfile",
    "iam:AddRoleToInstanceProfile",
    "iam:RemoveRoleFromInstanceProfile",
    "iam:TagInstanceProfile",
    "iam:UntagInstanceProfile",
  ]

  # Attaching, replacing or removing a permission boundary on a role. Denied to
  # every repository but this one: a consumer's child roles get their boundary
  # at creation and keep it.
  iam_role_boundary_actions = [
    "iam:PutRolePermissionsBoundary",
    "iam:DeleteRolePermissionsBoundary",
  ]

  iam_self_modify_actions = [
    "iam:UpdateAssumeRolePolicy",
    "iam:AttachRolePolicy",
    "iam:DetachRolePolicy",
    "iam:PutRolePolicy",
    "iam:DeleteRolePolicy",
    "iam:DeleteRole",
    "iam:UpdateRole",
    "iam:UpdateRoleDescription",
    "iam:TagRole",
    "iam:UntagRole",
  ]

  iam_oidc_provider_write_actions = [
    "iam:CreateOpenIDConnectProvider",
    "iam:DeleteOpenIDConnectProvider",
    "iam:UpdateOpenIDConnectProviderThumbprint",
    "iam:AddClientIDToOpenIDConnectProvider",
    "iam:RemoveClientIDFromOpenIDConnectProvider",
    "iam:TagOpenIDConnectProvider",
    "iam:UntagOpenIDConnectProvider",
  ]

  # The caller identity's account, as the calling configuration reads it
  # (account_id): the account the aws provider actually runs in.
  account_arn_prefix    = "arn:aws:iam::${var.account_id}"
  cicd_roles_arn        = "${local.account_arn_prefix}:role/${var.cicd_roles_path}/${var.github_oidc_path}/*"
  oidc_provider_arn     = "${local.account_arn_prefix}:oidc-provider/token.actions.githubusercontent.com"
  boundary_policies_arn = "${local.account_arn_prefix}:policy/boundaries/*"
}

# ---------------------------------------------------------------------------
# Trust policy, per consumer
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cicd_deploy_assume_role" {
  for_each = local.github_oidc_deploy_units

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

    # The one subject, exactly. GitHub emits environment:<name> as a literal
    # sub for jobs bound to an Environment; nothing else in the repository
    # (branches, tags, pull_request) matches.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = [local.github_oidc_deploy_subject[each.key]]
    }
  }
}

resource "aws_iam_role" "cicd_deploy" {
  for_each = local.github_oidc_deploy_units

  name               = each.value.role_name
  path               = "/${var.cicd_roles_path}/${var.github_oidc_path}/"
  description        = "GitHub Actions deploy role for ${var.github_organization}/${each.value.repository}: applies through the ${each.value.environment} Environment."
  assume_role_policy = data.aws_iam_policy_document.cicd_deploy_assume_role[each.key].json

  # The deploy class, or for the baseline repository its own boundary
  # (permission-boundaries.tf). None while no classes are given.
  permissions_boundary = (
    !local.boundaries_enabled ? null
    : local.consumers[each.value.repository].manages_account_baseline ? local.baseline_boundary_policy_arn
    : local.class_boundary_arns["deploy"]
  )

  tags = { Name = each.value.role_name, (local.repository_tag_key) = each.value.repository }
}

# ---------------------------------------------------------------------------
# Shared IAM baseline, the same for every consumer
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cicd_deploy_iam_baseline" {
  #checkov:skip=CKV_AWS_109: Service-linked-role creation cannot be resource-scoped (AWS-defined paths); everything else here is read-only.
  #checkov:skip=CKV_AWS_111: Service-linked-role creation has no resource scoping by AWS design.
  #checkov:skip=CKV_AWS_356: IAM read on * is required for terraform plan and apply to refresh adjacent principals; not an escalation path.

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

  # Service-linked roles live at fixed AWS-managed paths that no path scope
  # matches, so creating one can only be granted on *. A service creates its
  # own on first use, and creating one harms nobody. Deleting is not granted:
  # a service-linked role is account-wide, so one repository could otherwise
  # remove a role another repository's service depends on.
  statement {
    sid       = "iamCreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }
}

# ---------------------------------------------------------------------------
# Per-consumer permissions
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "cicd_deploy_permissions" {
  for_each = local.github_oidc_deploy_units

  #checkov:skip=CKV_AWS_107: Credential-exposure actions are not granted; IAM writes are path-scoped, and CreateRole requires the service boundary.
  #checkov:skip=CKV_AWS_108: Data-exfiltration scope is the account and the enumerated services, capped by the deploy boundary.
  #checkov:skip=CKV_AWS_109: Permissions-management actions are scoped to this repository's own IAM path; the role cannot modify itself or other consumers' roles.
  #checkov:skip=CKV_AWS_111: Broad write access within the account on the enumerated services is the reference's deliberate stance; the controls are the path scoping, the reviewed Environment and the deploy boundary.
  #checkov:skip=CKV_AWS_356: Resource ARNs churn across plans; * on the enumerated services is the explicit design.

  source_policy_documents = [data.aws_iam_policy_document.cicd_deploy_iam_baseline.json]

  # Broad within the account on the repository's services. Resources are *
  # because Terraform churns ARNs (rename, replace-on-tag), and the repository
  # gate plus the boundary are the integrity controls.
  dynamic "statement" {
    for_each = length(local.consumers[each.value.repository].services) > 0 ? [1] : []

    content {
      sid       = "serviceWrite"
      effect    = "Allow"
      actions   = [for svc in local.consumers[each.value.repository].services : "${svc}:*"]
      resources = ["*"]
    }
  }

  # IAM writes on this repository's own path only. Human roles, other
  # consumers' roles and the pipeline roles at /cicd/gha/ are out of reach, and
  # iam:CreateUser is absent: a pipeline never mints a principal that outlives
  # a session.
  statement {
    sid       = "iamManageOwnedRoles"
    effect    = "Allow"
    actions   = local.iam_role_write_actions
    resources = ["${local.account_arn_prefix}:role/services/${each.value.repository}/*"]
  }

  statement {
    sid       = "iamPassOwnedRoles"
    effect    = "Allow"
    actions   = ["iam:PassRole"]
    resources = ["${local.account_arn_prefix}:role/services/${each.value.repository}/*"]
  }

  statement {
    sid       = "iamManageOwnedPolicies"
    effect    = "Allow"
    actions   = local.iam_policy_write_actions
    resources = ["${local.account_arn_prefix}:policy/services/${each.value.repository}/*"]
  }

  statement {
    sid       = "iamManageOwnedInstanceProfiles"
    effect    = "Allow"
    actions   = local.iam_instance_profile_write_actions
    resources = ["${local.account_arn_prefix}:instance-profile/services/${each.value.repository}/*"]
  }

  # iam:CreateRole in its own statement, because the iam:PermissionsBoundary
  # condition belongs to this action alone: every role born under
  # /services/<repo>/ carries the service class, whatever the repository
  # attaches to it afterwards. It can't take the boundary off again: attaching
  # and removing boundaries is denied below, and by every class.
  statement {
    sid       = "iamCreateOwnedRole"
    effect    = "Allow"
    actions   = ["iam:CreateRole"]
    resources = ["${local.account_arn_prefix}:role/services/${each.value.repository}/*"]

    dynamic "condition" {
      for_each = local.boundaries_enabled ? [1] : []

      content {
        test     = "StringEquals"
        variable = "iam:PermissionsBoundary"
        values   = [local.class_boundary_arns["service"]]
      }
    }
  }

  # The baseline repository only: the GitHub OIDC provider, the pipeline roles
  # at /cicd/gha/ and the permission-boundary policies at /boundaries/ are the
  # resources this configuration manages, and nobody else's.
  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [1] : []

    content {
      sid       = "iamManageGithubOidcProvider"
      effect    = "Allow"
      actions   = local.iam_oidc_provider_write_actions
      resources = [local.oidc_provider_arn]
    }
  }

  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [1] : []

    content {
      sid       = "iamManageCicdRoles"
      effect    = "Allow"
      actions   = local.iam_role_write_actions
      resources = [local.cicd_roles_arn]
    }
  }

  # A pipeline role can only be created bounded, by the deploy or the read
  # class. Not by the baseline's own boundary: that role is created and
  # bounded by an account admin.
  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [1] : []

    content {
      sid       = "iamCreateCicdRole"
      effect    = "Allow"
      actions   = ["iam:CreateRole"]
      resources = [local.cicd_roles_arn]

      dynamic "condition" {
        for_each = local.boundaries_enabled ? [1] : []

        content {
          test     = "StringEquals"
          variable = "iam:PermissionsBoundary"
          values   = [local.class_boundary_arns["deploy"], local.class_boundary_arns["read"]]
        }
      }
    }
  }

  # The exception that makes the rule: this repository creates, changes and
  # deletes the permission-boundary policies, and attaches or replaces the
  # boundary on the roles it manages.
  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [1] : []

    content {
      sid       = "iamManagePermissionBoundaryPolicies"
      effect    = "Allow"
      actions   = local.iam_policy_write_actions
      resources = [local.boundary_policies_arn]
    }
  }

  # Attaching accepts only the deploy and read classes, as creating does:
  # never users, service or the baseline's own boundary, on any pipeline role.
  # Replacing is the only change: removing a boundary
  # (iam:DeleteRolePermissionsBoundary) is granted to no pipeline role, and
  # the baseline's own boundary denies it on every role at /cicd/gha/. Deleting
  # a role doesn't need it: DeleteRole takes a role with its boundary still
  # attached. So turning the boundaries off again is an account admin's
  # recorded local apply.
  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [1] : []

    content {
      sid       = "iamSetPermissionBoundaryOnCicdRoles"
      effect    = "Allow"
      actions   = ["iam:PutRolePermissionsBoundary"]
      resources = [local.cicd_roles_arn]

      dynamic "condition" {
        for_each = local.boundaries_enabled ? [1] : []

        content {
          test     = "StringEquals"
          variable = "iam:PermissionsBoundary"
          values   = [local.class_boundary_arns["deploy"], local.class_boundary_arns["read"]]
        }
      }
    }
  }

  # Every other repository: no creating, changing or deleting a boundary
  # policy, and no attaching, replacing or removing a boundary on any role.
  # Deny beats every Allow above, so the path scopes could never be widened
  # into this by accident, and the deny holds before the boundaries exist.
  #
  # Two statements, scoped differently: the policy writes on the boundary
  # policies only (policy/boundaries/*), so the repository's own policies under
  # /services/<repo>/ (iamManageOwnedPolicies) stay writable; a deny on "*"
  # would cancel that Allow. The boundary attach/remove actions on every role,
  # since no repository but this one may set a boundary anywhere.
  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [] : [1]

    content {
      sid       = "denyPermissionBoundaryPolicyChanges"
      effect    = "Deny"
      actions   = local.iam_policy_write_actions
      resources = [local.boundary_policies_arn]
    }
  }

  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [] : [1]

    content {
      sid       = "denyPermissionBoundaryAttachment"
      effect    = "Deny"
      actions   = local.iam_role_boundary_actions
      resources = ["*"]
    }
  }

  # Deny changes to the role's own ARN. Its path is outside the Allows above
  # already; the deny holds even if a path or name ever came to overlap. Not
  # for the baseline repository, whose job is exactly to maintain these roles:
  # it is admin-equivalent by design, and its gate is the Environment's
  # reviewers (permission-boundaries.tf, "What the boundary is for").
  dynamic "statement" {
    for_each = local.consumers[each.value.repository].manages_account_baseline ? [] : [1]

    content {
      sid       = "denySelfModify"
      effect    = "Deny"
      actions   = local.iam_self_modify_actions
      resources = [aws_iam_role.cicd_deploy[each.key].arn]
    }
  }
}

resource "aws_iam_role_policy" "cicd_deploy_permissions" {
  for_each = local.github_oidc_deploy_units

  name   = "${each.value.role_name}-permissions"
  role   = aws_iam_role.cicd_deploy[each.key].id
  policy = data.aws_iam_policy_document.cicd_deploy_permissions[each.key].json
}

# State: through shared-cicd-infrastructure's read/write state role, whose trust
# admits only roles named *-deploy, <repo>-<environment>-deploy included: the
# apply jobs bound to a GitHub Environment, which apply the plan job's saved
# plan through it (the backend names a profile, not a role, so the plan
# carries no role). The read role, and so every plan job, uses the read-only one
# (github-oidc-role-read.tf). Own policy, separately
# revocable; absent until var.state_role_arn is set after
# shared-cicd-infrastructure's first apply.
resource "aws_iam_role_policy" "cicd_deploy_assume_state_access" {
  for_each = var.state_role_arn == "" ? {} : local.github_oidc_deploy_units

  name   = "assume-state"
  role   = aws_iam_role.cicd_deploy[each.key].id
  policy = data.aws_iam_policy_document.cicd_assume_state[0].json
}
