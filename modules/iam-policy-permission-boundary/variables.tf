variable "context" {
  # VENDORED change (main.tf): an OMRON terraform-null-label context, not a
  # CloudPosse one. The wrapper types and defaults it.
  type        = any
  default     = {}
  description = "Label context from a parent OMRON terraform-null-label (its context output). Explicit variables override matching context fields; attributes and tags are merged."
}

variable "allow_all" {
  type        = bool
  default     = false
  description = <<-EOT
    Emit an unrestricted `Allow *` on `*`. This is the standard shape
    for a Permission Boundary configured as a deny-list — the boundary
    caps via its built-in + caller-supplied denies; identity-based
    policies still grant the actual permissions. Mutually exclusive
    with `allowed_actions`: use one or the other.
  EOT
}

variable "allowed_actions" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Allow-list for the Permission Boundary policy.
    Use qualified actions (e.g., `iam:Get*`, `s3:GetObject`).
    Bare service wildcards that would defeat an allow-list boundary
    (`iam:*`, `sts:*`, `organizations:*`, `account:*`, `*`) are rejected
    here, including any mix of `*` and `?` that holds an asterisk
    (`iam:**`, `iam:?*`, `sts:*?`, `?*` too). For the deny-list PB shape
    (allow everything, cap via denies), use `allow_all = true` instead.
    May be empty (default) if the boundary is deny-only or uses `allow_all`.
  EOT

  validation {
    # trimspace() before lower() so leading/trailing whitespace can't
    # bypass the denylist (e.g., "iam:* " would otherwise pass the
    # check yet still be effectively iam:* at apply time).
    #
    # VENDORED change (main.tf): any mix of * and ? with at least one *,
    # not only a run of asterisks. In IAM, ? matches one character and *
    # any run, so "iam:?*" and "sts:*?" match every action of the service
    # just like "iam:*", and "?*" every action of every service. A pattern
    # of ? alone ("iam:???") matches only actions of that length, so it
    # can't open a whole service and is left alone.
    condition = alltrue([
      for action in var.allowed_actions :
      !can(regex("^((iam|sts|organizations|account):)?[*?]*\\*[*?]*$", lower(trimspace(action))))
    ])
    error_message = "allowed_actions must not contain bare wildcards for iam, sts, organizations, account, or '*': any mix of '*' and '?' that holds an asterisk counts ('iam:**', 'iam:?*', 'sts:*?', '?*'), because it matches every action. Use qualified actions like 'iam:Get*' instead."
  }
}

variable "denied_actions" {
  type        = list(string)
  default     = []
  description = <<-EOT
    Caller-supplied additional denies, applied on top of the
    module's built-in denies. Overlap with built-ins is harmless
    (idempotent). May be empty (default).
  EOT
}

variable "name" {
  type        = string
  description = "Name of the resource to be labeled. This is used to generate the label key and value."
}

variable "permit_human_user_actions" {
  type        = bool
  default     = false
  description = <<-EOT
    Permit the human-user-surface actions (`iam:CreateUser`,
    `iam:CreateLoginProfile`, `iam:UpdateLoginProfile`,
    `iam:CreateAccessKey`, `iam:UpdateAccessKey`) that this module
    denies by default. Only set to `true` for boundaries on roles
    that legitimately manage human users (rare).
  EOT
}

variable "permit_org_governance" {
  type        = bool
  default     = false
  description = <<-EOT
    Permit `organizations:*` and `account:*` that this module denies
    by default. Only set to `true` for boundaries on org-management
    roles (rare).
  EOT
}

variable "permit_policy_mutation" {
  type        = bool
  default     = false
  description = <<-EOT
    Permit `iam:UpdateAssumeRolePolicy`, `iam:CreatePolicyVersion`,
    and `iam:SetDefaultPolicyVersion` that this module denies by
    default. These actions can be used to bypass the boundary
    (rewriting trust policies, mutating attached policies in place,
    activating older policy versions). Only set to `true` for
    boundaries on roles that legitimately manage other roles' trust
    policies or policy versions (rare).

    Note: setting this to `true` only relaxes the deny on *non-boundary*
    policies. Mutation of policies at the `/boundaries/` path remains
    denied unconditionally via a separate, always-on statement,
    regardless of this toggle.
  EOT
}

# VENDORED change (main.tf): not in upstream.
variable "create_policy" {
  type        = bool
  default     = true
  nullable    = false
  description = <<-EOT
    Create the policy. Set to `false` where another configuration creates the
    same policy in this account (one owner per policy name): the module then
    only renders the statements (`policy_statements`, `policy_document_json`)
    and names the policy (`policy_name`, `policy_path`), and `policy_arn` is
    null. The precondition on `allow_all` and `allowed_actions` runs on the
    policy, so only where it is created.
  EOT
}
