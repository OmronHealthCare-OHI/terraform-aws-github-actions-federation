# The permission-boundary classes (CLF-54), rendered as policies at
# /boundaries/ in this account. The classes are data, defined in
# aws-organization and published as its shared_permission_boundaries output;
# this module only renders them.
#
# The boundary is a ceiling, not a grant: each role's own policy narrows it
# further. This file renders the policies only. Attaching them by role path
# (deploy and read on the consumers' roles at /cicd/gha/, service through
# iam:CreateRole's iam:PermissionsBoundary condition on /services/<repo>/) and
# the baseline deploy role's own boundary come next, in a separate change.
#
# Roles that write boundaries, and roles humans enter outside Identity Center,
# are not in a class: each gets its own boundary, defined next to it. The
# module's boundaries can't serve them anyway: every one denies all writes to
# policy/boundaries/*, which is exactly the baseline deploy role's job.
#
# Every policy is named <namespace>-<application>-<class> (omron-shared-deploy,
# …): the account label's own name segment (the account key) is replaced by the
# class, so the name is the same in every shared account. An Identity Center
# permission set references a customer-managed boundary by name and path, once,
# for every account it is assigned in; an account-specific name would break
# that for the users class.
#
# Like the OIDC provider, the policies are account-wide: only the
# configuration that owns the account's resources creates them
# (manage_account_resources). Every other one still renders the classes, so
# the coverage check below holds for its own roles, and reads the policies by
# name, which fails its plan until the owner has applied.

module "permission_boundary" {
  source   = "./modules/iam-policy-permission-boundary"
  for_each = var.permission_boundaries

  context       = var.label_context
  name          = each.key
  create_policy = var.manage_account_resources

  allow_all                 = each.value.allow_all
  allowed_actions           = each.value.allowed_actions
  denied_actions            = each.value.denied_actions
  permit_policy_mutation    = each.value.permit_policy_mutation
  permit_human_user_actions = each.value.permit_human_user_actions
  permit_org_governance     = each.value.permit_org_governance
}

# ---------------------------------------------------------------------------
# Which boundary each role carries
# ---------------------------------------------------------------------------
#
# Once classes are given (and only then), every role here carries one:
#
#   <repo>-read, every consumer's      the read class
#   <repo>-deploy, every consumer's    the deploy class
#   the baseline repository's deploy   its own <repo>-baseline (below)
#   role
#
# and every role a consumer creates is born with the service class
# (github-oidc-role-deploy.tf, iamCreateOwnedRole).

locals {
  boundaries_enabled = length(var.permission_boundaries) > 0

  # The baseline repository: exactly one per account (the caller's
  # precondition), with a single deploy role keyed by its name (variables.tf).
  # Empty, not an error, while that doesn't hold, so the precondition is the
  # message a misconfigured run gets.
  baseline_repository = length(local.baseline_repositories) == 1 ? local.baseline_repositories[0] : ""

  class_boundary_arns = (
    var.manage_account_resources
    ? { for class, boundary in module.permission_boundary : class => boundary.policy_arn }
    : { for class, policy in data.aws_iam_policy.class_boundary : class => policy.arn }
  )

  # The baseline's own boundary and deploy role, as ARNs built from their
  # names: the boundary's policy names the role, and the role carries the
  # boundary, so neither may reference the other's resource.
  baseline_boundary_name = "${local.baseline_repository}-baseline"
  baseline_boundary_arn  = "${local.account_arn_prefix}:policy/boundaries/${local.baseline_boundary_name}"

  # With a stage, the stages sharing the account each have a baseline deploy
  # role (<baseline>-<stage>-deploy), and this boundary, rendered once by the
  # account's owner, must cover them all: hence the pattern. The prefix check
  # below keeps other repositories' roles out of it.
  baseline_deploy_role_arns = (
    var.stage == null
    ? ["${local.account_arn_prefix}:role/${var.cicd_roles_path}/${var.github_oidc_path}/${local.baseline_repository}-deploy"]
    : [
      "${local.account_arn_prefix}:role/${var.cicd_roles_path}/${var.github_oidc_path}/${local.baseline_repository}-deploy",
      "${local.account_arn_prefix}:role/${var.cicd_roles_path}/${var.github_oidc_path}/${local.baseline_repository}-*-deploy",
    ]
  )

  # The roles the baseline's deploy role may assume: the read/write state role
  # and the workspace provisioner, whichever are known.
  baseline_assumable_role_arns = compact([var.state_role_arn, var.workspace_provisioner_role_arn])

  # The baseline boundary the baseline's deploy role carries: created here, or
  # read from the owner.
  baseline_boundary_policy_arn = !local.boundaries_enabled ? null : (
    var.manage_account_resources
    ? aws_iam_policy.baseline_boundary[0].arn
    : data.aws_iam_policy.baseline_boundary[0].arn
  )
}

# Without manage_account_resources: the owner's policies, read by the names
# both configurations build. A missing one fails the plan, before any role
# would be created with a boundary that doesn't exist.
#
# Each class must also be the one this workspace renders: the coverage check
# proves the roles fit this rendering, so it only protects them while the
# account carries the same. A class change applied here before the owner
# (aws-organization adds a service, a consumer starts using it) would
# otherwise pass and then fail closed, with AccessDenied, until the owner
# applies. Compared as decoded JSON, so key order and whitespace don't count.
# The baseline's own boundary isn't compared: only its owner renders it.
data "aws_iam_policy" "class_boundary" {
  for_each = var.manage_account_resources ? toset([]) : toset(keys(var.permission_boundaries))

  arn = "${local.account_arn_prefix}:policy${module.permission_boundary[each.key].policy_path}${module.permission_boundary[each.key].policy_name}"

  lifecycle {
    postcondition {
      condition     = jsondecode(self.policy) == jsondecode(module.permission_boundary[each.key].policy_document_json)
      error_message = "The ${each.key} permission-boundary class in account ${var.account_id} differs from the one this workspace renders, so the coverage check doesn't hold for the policy the roles would carry. Apply the class change on the account's owner workspace (manage_account_resources = true) first."
    }
  }
}

data "aws_iam_policy" "baseline_boundary" {
  count = !var.manage_account_resources && local.boundaries_enabled ? 1 : 0

  arn = local.baseline_boundary_arn
}

# With a stage, the baseline boundary denies changing the boundary of
# <baseline>-deploy and every <baseline>-*-deploy role. Every deploy role name
# ends in -deploy, so a role falls under one of the two exactly when its name
# starts with "<baseline>-". The check is on the generated names, not the
# repository keys: a stage or an Environment can build such a name from a key
# that doesn't start with it (baseline infra-dev, consumer infra and stage dev
# give infra-dev-deploy). A consumer role under the deny is one the baseline
# can no longer bound. Ignoring case, as IAM role names do.
#
# And the deny must be there: a workspace without manage_account_resources
# carries the owner's baseline boundary, which has the pattern only if the
# owner set a stage too. Without it, this stage's baseline deploy role isn't
# named by denyChangingOwnBoundary, and since both its policy and the
# boundary allow PutRolePermissionsBoundary on /cicd/gha/* with the deploy or
# read class, it could swap its own boundary for the deploy class and shed
# the baseline's denies. The owner's policy is read anyway, so it is checked
# here. Review on #66.
locals {
  baseline_pattern_collisions = local.baseline_repository == "" ? [] : sort([
    for key, unit in local.github_oidc_deploy_units : unit.role_name
    if unit.repository != local.baseline_repository && startswith(lower(unit.role_name), lower("${local.baseline_repository}-"))
  ])
}

resource "terraform_data" "stage_baseline_prefix" {
  count = var.stage == null ? 0 : 1

  lifecycle {
    precondition {
      condition     = length(local.baseline_pattern_collisions) == 0
      error_message = "With a stage set, no other consumer's deploy role may be named \"${local.baseline_repository}-…\": the baseline boundary denies changing the boundary of ${local.baseline_repository}-deploy and ${local.baseline_repository}-*-deploy, so the baseline could no longer bound it. Rename the repository key or the environments key. Colliding: ${join(", ", local.baseline_pattern_collisions)}."
    }

    precondition {
      condition = length(data.aws_iam_policy.baseline_boundary) == 0 ? true : anytrue([
        for s in jsondecode(data.aws_iam_policy.baseline_boundary[0].policy).Statement :
        try(s.Sid, "") == "denyChangingOwnBoundary" && contains(flatten([s.Resource]), local.baseline_deploy_role_arns[1])
      ])
      error_message = "The owner's ${local.baseline_boundary_name} doesn't deny changing the boundary of ${local.baseline_repository}-*-deploy, so this stage's baseline deploy role could change its own. Set stage on the owner workspace too, and apply it first."
    }
  }
}

# ---------------------------------------------------------------------------
# The baseline repository's own boundary
# ---------------------------------------------------------------------------
#
# The deploy role that applies this configuration writes the boundaries, so no
# class can bound it: every class denies all writes to policy/boundaries/*,
# which is its job. It gets a boundary of its own, written here (CLF-54,
# decided 2026-10-27):
#
#   - Allow: its job and nothing else. IAM reads; service-linked roles; its
#     own services, if any; the GitHub OIDC provider; the pipeline roles at
#     /cicd/gha/, created and given a boundary (never removed) only with the
#     deploy or read class; the boundary policies
#     at /boundaries/; the apply App's key, if it manages GitHub; and the hop
#     to the state role and the workspace provisioner. Not the IAM writes on
#     /services/<repo>/ that its policy carries like every consumer's: it has
#     no service roles. A service that needs one adds them here, by admin
#     apply.
#   - Deny, narrowly: writing this boundary policy, attaching or removing a
#     boundary on its own role, removing the boundary from any pipeline role,
#     and sts:AssumeRole on anything but the roles it hops to. The AssumeRole
#     deny is explicit, not only left out of the Allow: a trust policy that
#     names a role's session isn't limited by a boundary's implicit deny, and
#     this role writes trust policies.
#
# So the pipeline can't change this boundary, take it off its own role, or
# leave a pipeline role unbounded. A change to any of these, including one that
# only follows from new inputs (the state role, the App keys, the baseline's
# services), is a recorded local apply by an account admin, like this
# boundary's first apply (README, "Permission boundaries").
#
# What the boundary is for: mistakes, not a hostile apply. This pipeline is
# admin-equivalent by design, because its job is writing trust policies, roles
# and boundaries. Its GitHub job can federate (AssumeRoleWithWebIdentity, which
# this boundary doesn't govern) into any pipeline role whose trust and policy
# it writes, and from there act within the class that role carries, which it
# can also widen. Closing that would take role and trust provisioning away from
# it. Its gate is who can release and approve its deploy: the reviewers of its
# GitHub Environment (decided on PR #56, 2026-11-09).

data "aws_iam_policy_document" "baseline_boundary" {
  count = var.manage_account_resources && local.boundaries_enabled ? 1 : 0

  #checkov:skip=CKV_AWS_107: A boundary caps; it grants nothing. The App-key read is on the one apply secret.
  #checkov:skip=CKV_AWS_108: A boundary caps; it grants nothing. Reads are IAM's and the one apply secret.
  #checkov:skip=CKV_AWS_109: A boundary caps; it grants nothing. Permissions management is on /cicd/gha/ and /boundaries/ only, its job.
  #checkov:skip=CKV_AWS_111: A boundary caps; it grants nothing. Writes are on the OIDC provider, /cicd/gha/ and /boundaries/ only.
  #checkov:skip=CKV_AWS_356: IAM reads and service-linked-role creation can't be resource-scoped; everything else is.

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

  statement {
    sid       = "iamCreateServiceLinkedRoles"
    effect    = "Allow"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
  }

  dynamic "statement" {
    for_each = length(local.consumers[local.baseline_repository].services) > 0 ? [1] : []

    content {
      sid       = "serviceWrite"
      effect    = "Allow"
      actions   = [for svc in local.consumers[local.baseline_repository].services : "${svc}:*"]
      resources = ["*"]
    }
  }

  statement {
    sid       = "manageGithubOidcProvider"
    effect    = "Allow"
    actions   = local.iam_oidc_provider_write_actions
    resources = [local.oidc_provider_arn]
  }

  statement {
    sid       = "manageCicdRoles"
    effect    = "Allow"
    actions   = local.iam_role_write_actions
    resources = [local.cicd_roles_arn]
  }

  # Creating a pipeline role, or replacing its boundary, only with the deploy
  # or the read class: the same condition as the deploy role's own
  # iamCreateCicdRole and iamSetPermissionBoundaryOnCicdRoles, repeated here
  # because the pipeline rewrites its own inline policy. Without a boundary
  # given, the condition key is absent and CreateRole isn't allowed.
  statement {
    sid       = "createAndBoundCicdRoles"
    effect    = "Allow"
    actions   = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
    resources = [local.cicd_roles_arn]

    condition {
      test     = "StringEquals"
      variable = "iam:PermissionsBoundary"
      values   = [local.class_boundary_arns["deploy"], local.class_boundary_arns["read"]]
    }
  }

  statement {
    sid       = "manageBoundaryPolicies"
    effect    = "Allow"
    actions   = local.iam_policy_write_actions
    resources = [local.boundary_policies_arn]
  }

  dynamic "statement" {
    for_each = contains(local.github_app_key_repositories, local.baseline_repository) ? [1] : []

    content {
      sid       = "readApplyGithubAppKey"
      effect    = "Allow"
      actions   = ["secretsmanager:GetSecretValue"]
      resources = [var.github_app_key_arns.apply_secret_arn]
    }
  }

  dynamic "statement" {
    for_each = contains(local.github_app_key_repositories, local.baseline_repository) ? [1] : []

    content {
      sid       = "decryptApplyGithubAppKey"
      effect    = "Allow"
      actions   = ["kms:Decrypt"]
      resources = [var.github_app_key_arns.kms_key_arn]
    }
  }

  dynamic "statement" {
    for_each = length(local.baseline_assumable_role_arns) > 0 ? [1] : []

    content {
      sid       = "assumeStateAndProvisionerRoles"
      effect    = "Allow"
      actions   = ["sts:AssumeRole", "sts:TagSession"]
      resources = local.baseline_assumable_role_arns
    }
  }

  statement {
    sid       = "denyWritingThisBoundary"
    effect    = "Deny"
    actions   = local.iam_policy_write_actions
    resources = [local.baseline_boundary_arn]
  }

  statement {
    sid       = "denyChangingOwnBoundary"
    effect    = "Deny"
    actions   = local.iam_role_boundary_actions
    resources = local.baseline_deploy_role_arns
  }

  # Explicit, not only left out of manageCicdRoles: the pipeline rewrites its
  # own inline policy, so its identity policy is no guard on its own.
  statement {
    sid       = "denyRemovingPipelineBoundaries"
    effect    = "Deny"
    actions   = ["iam:DeleteRolePermissionsBoundary"]
    resources = [local.cicd_roles_arn]
  }

  # NotResource needs at least one ARN: with none known, every AssumeRole.
  dynamic "statement" {
    for_each = length(local.baseline_assumable_role_arns) > 0 ? [1] : []

    content {
      sid           = "denyAssumingAnyRoleButStateAndProvisioner"
      effect        = "Deny"
      actions       = ["sts:AssumeRole"]
      not_resources = local.baseline_assumable_role_arns
    }
  }

  dynamic "statement" {
    for_each = length(local.baseline_assumable_role_arns) > 0 ? [] : [1]

    content {
      sid       = "denyAssumingAnyRole"
      effect    = "Deny"
      actions   = ["sts:AssumeRole"]
      resources = ["*"]
    }
  }
}

module "baseline_boundary_label" {
  source = "github.com/OmronHealthCare-OHI/terraform-null-label?ref=1.0.0"

  context = var.label_context
  name    = local.baseline_boundary_name
}

resource "aws_iam_policy" "baseline_boundary" {
  count = var.manage_account_resources && local.boundaries_enabled ? 1 : 0

  name        = local.baseline_boundary_name
  path        = "/boundaries/"
  description = "Permission boundary of ${local.baseline_repository}'s deploy role, which applies the account baseline: its job, nothing else. Changed only by an account admin's recorded local apply."
  policy      = data.aws_iam_policy_document.baseline_boundary[0].json

  tags = module.baseline_boundary_label.tags
}

# ---------------------------------------------------------------------------
# Every action a role's own policies allow, its class must allow too
# ---------------------------------------------------------------------------
#
# A boundary is a ceiling: an action the role's policy grants but its class
# doesn't is an AccessDenied, found only once the boundaries are attached. The
# services are validated on the variable (variables.tf), with the repository
# that needs each one. This covers everything else the roles do: IAM reads and
# writes, the state hop (sts:AssumeRole, sts:TagSession), the GitHub App key,
# and the policy-version writes a class only allows with permit_policy_mutation.
#
# Both sides come from the documents themselves, not from a second list:
#   - required: every Allow action in the policies on the roles a class bounds,
#     read from the policy documents (their statement blocks, known at plan);
#     the deploy class bounds every deploy role but the baseline's, which has
#     its own boundary; the read class every read role;
#   - allowed: the class's statements, as the boundary module configures them
#     (its policy_statements output). An action is covered when an
#     Allow on "*" matches it and no Deny on "*" matches all of it. Matching
#     treats * and ? as IAM does, ignoring case. A Deny scoped to some
#     resources (the module's own on policy/boundaries/*) narrows the class
#     without removing the action, so it doesn't count.

locals {
  # Per class, per role: the Allow actions of the policies on that role.
  boundary_class_required_actions = length(var.permission_boundaries) == 0 ? {} : {
    deploy = {
      for key, unit in local.github_oidc_deploy_units : unit.role_name => distinct(flatten([
        for doc in concat(
          [data.aws_iam_policy_document.cicd_deploy_iam_baseline, data.aws_iam_policy_document.cicd_deploy_permissions[key]],
          data.aws_iam_policy_document.cicd_assume_state,
          [for app, d in data.aws_iam_policy_document.cicd_github_app_key : d if app == "apply" && contains(local.github_app_key_repositories, unit.repository)],
          ) : [
          for s in doc.statement : s.actions if try(coalesce(s.effect, "Allow"), "Allow") == "Allow" && s.actions != null
        ]
      ])) if !contains(local.baseline_repositories, unit.repository)
    }
    read = {
      for repo, consumer in local.consumers : "${repo}${local.stage_infix}-read" => distinct(flatten([
        for doc in concat(
          [data.aws_iam_policy_document.cicd_read_iam_baseline, data.aws_iam_policy_document.cicd_read_permissions[repo]],
          data.aws_iam_policy_document.cicd_assume_read_state,
          [for app, d in data.aws_iam_policy_document.cicd_github_app_key : d if app == "plan" && contains(local.github_app_key_repositories, repo)],
          ) : [
          for s in doc.statement : s.actions if try(coalesce(s.effect, "Allow"), "Allow") == "Allow" && s.actions != null
        ]
      ]))
    }
  }

  # Each class's statements, as the module configures them.
  boundary_class_statements = {
    for class, boundary in module.permission_boundary : class => boundary.policy_statements
  }

  # "<class>: <role>: <action>" for every action a role needs that its class
  # doesn't allow. A pattern matches an action, or a narrower pattern, when its
  # * and ? (as regex .* and .) match that text.
  boundary_class_coverage_gaps = flatten([
    for class, roles in local.boundary_class_required_actions : [
      for role, actions in roles : [
        for action in actions : "${class}: ${role}: ${action}"
        if !(
          length([
            for s in lookup(local.boundary_class_statements, class, []) : s
            if try(coalesce(s.effect, "Allow"), "Allow") == "Allow" && contains(coalesce(s.resources, []), "*") && anytrue([
              for p in coalesce(s.actions, []) : can(regex("^${replace(replace(lower(p), "*", ".*"), "?", ".")}$", lower(action)))
            ])
          ]) > 0 &&
          length([
            for s in lookup(local.boundary_class_statements, class, []) : s
            if s.effect == "Deny" && contains(coalesce(s.resources, []), "*") && anytrue([
              for p in coalesce(s.actions, []) : can(regex("^${replace(replace(lower(p), "*", ".*"), "?", ".")}$", lower(action)))
            ])
          ]) == 0
        )
      ]
    ]
  ])
}

resource "terraform_data" "permission_boundary_coverage" {
  count = length(var.permission_boundaries) > 0 ? 1 : 0

  lifecycle {
    precondition {
      condition     = length(local.boundary_class_coverage_gaps) == 0
      error_message = "A permission-boundary class doesn't allow an action its roles' own policies grant, which would be an AccessDenied once the boundaries are attached. Add it to aws-organization's shared_permission_boundaries (or set the class's permit_policy_mutation, for policy-version writes) first. Missing (class: role: action): ${join(", ", sort(local.boundary_class_coverage_gaps))}."
    }
  }
}
