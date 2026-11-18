variable "account_key" {
  description = "The account this instance federates, as a key of github_oidc_consumers (for shared-workload: the shared account's entry id, cicd). Selects the account's consumers, names its read-role variable (<ACCOUNT>_READ_ROLE_ARN) and is the default Environment of a consumer that sets none."
  type        = string

  # An unknown key would select no consumers, and against an existing state
  # plan the deletion of every consumer's roles, Environments and variables
  # instead of failing. The root's precondition guards its own workspace; the
  # module guards every caller.
  validation {
    condition     = contains(keys(var.github_oidc_consumers), var.account_key)
    error_message = "account_key \"${var.account_key}\" is not a key of github_oidc_consumers (${join(", ", sort(keys(var.github_oidc_consumers)))}): add the account's consumers there, including its manages_account_baseline repository."
  }
}

variable "account_id" {
  description = "AWS account id of that account, as the caller's identity reports it: the ARNs this module grants on (the /cicd/gha/ roles, the OIDC provider, the boundary policies) are built from it. Pass the calling configuration's data.aws_caller_identity, so it is the account the aws provider actually runs in."
  type        = string

  validation {
    condition     = can(regex("^[0-9]{12}$", var.account_id))
    error_message = "account_id must be a 12-digit AWS account id."
  }
}

variable "manage_account_resources" {
  description = <<-EOT
    Whether this configuration owns the account-wide resources: the GitHub
    OIDC provider and the permission-boundary policies (the classes and the
    baseline repository's own). Each exists once per account, so exactly one
    configuration may create it.

    true (the default): creates them, as shared-workload does with one
    workspace per account.

    false: where several workspaces share an account (one per stage, with the
    stages of an environment in one account), every workspace but the owner
    sets it. The module then reads the provider and the policies the owner
    created, by their fixed names, and the plan fails until the owner has
    applied, or if the provider doesn't accept the sts.amazonaws.com audience
    every role here trusts. Roles, Environments and variables are not
    account-wide and stay with every workspace.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "stage" {
  description = <<-EOT
    The stage this workspace deploys (dev, qa, stg, …), to put in the pipeline
    role names: <repo>-<stage>-read, <repo>-<stage>-deploy and
    <repo>-<stage>-<environment>-deploy. Only needed where several stages
    share an account (see manage_account_resources), because the role names
    are per account. With an account per stage the account id already tells
    the stages apart, so leave it null (the default): names stay
    <repo>-read and <repo>-deploy.

    Set, it also widens the baseline boundary's own-boundary deny to every
    stage's baseline deploy role (<baseline>-*-deploy), so the owner of a
    shared account sets it too; a workspace without
    manage_account_resources fails its plan until the owner's boundary has
    that pattern. No other consumer's deploy role name may then
    start with "<baseline>-", which a stage or an Environment can produce
    from an unrelated key: that role would fall under the deny.
  EOT
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.stage == null ? true : can(regex("^[a-z][a-z0-9]{0,9}$", var.stage))
    error_message = "stage must be lower-case letters and digits, starting with a letter, at most 10 characters (dev, qa, stg, prd): it becomes part of every pipeline role name."
  }
}

variable "label_context" {
  description = "The account-level terraform-null-label context the module's labels compose beneath (for shared-workload: omron-shared-<account>). It must carry a namespace. Only the OIDC provider is tagged through it; the roles carry the provider's default_tags."
  type        = any
}

variable "github_organization" {
  description = "GitHub organization that owns the consuming repositories. Every OIDC subject this configuration trusts is anchored on GitHub's subject prefix for the repository, repo:<github_organization>[@<owner-id>]/<repo>[@<repo-id>], read from GitHub (github-oidc-subjects.tf)."
  type        = string
  default     = "OmronHealthCare-OHI"
}

variable "cicd_roles_path" {
  description = "Top-level IAM path segment (no slashes) for pipeline-owned roles. Composed with github_oidc_path into the roles' path: \"cicd\" + \"gha\" gives /cicd/gha/. The path is the key of the permission-boundary taxonomy (CLF-54): pipeline roles here carry the deploy or read class (permission-boundaries.tf)."
  type        = string
  default     = "cicd"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.cicd_roles_path))
    error_message = "cicd_roles_path is a single path segment: letters, digits, _ and - only, no slashes."
  }
}

variable "github_oidc_path" {
  description = "IAM path segment (no slashes) under cicd_roles_path for the GitHub Actions roles. Another CI provider would sit beside it."
  type        = string
  default     = "gha"

  validation {
    condition     = can(regex("^[A-Za-z0-9_-]+$", var.github_oidc_path))
    error_message = "github_oidc_path is a single path segment: letters, digits, _ and - only, no slashes."
  }
}

variable "github_oidc_consumers" {
  description = <<-EOT
    The repositories that deploy into each shared account, keyed by shared
    account entry id (the workspace name), then by repository name (without the
    organization). Each repository gets two roles in that account at
    /<cicd_roles_path>/<github_oidc_path>/, trusting GitHub's OIDC subject
    prefix for it (<prefix> = repo:<org>[@<owner-id>]/<repo>[@<repo-id>],
    looked up from GitHub, so a name is all a new consumer needs here; the
    GitHub Apps must be installed on it):

      <repo>-read    trusts <prefix>:* (any branch, PR or tag);
                     read-only, for PR plans.
      <repo>-deploy  trusts only <prefix>:environment:<environment>;
                     for applies through the GitHub Environment, which only
                     allows main and requires reviewers.

    A repository that lists environments gets one deploy role per entry
    instead, <repo>-<environment>-deploy, each trusting only its own
    Environment: one per stage, each with its own gate and its own audit
    trail. Not isolation: the roles share the repository's services and IAM
    path in the same account.

    Both carry ohi:repository = <repo>: the session tag that
    shared-cicd-infrastructure's state role scopes writes by.

    Per repository:
      services                  AWS service prefixes the deploy role may write
                                (<svc>:*) and the read role may read. Not iam or
                                sts: IAM access is the fixed split in the role
                                files, never a service wildcard.
      environment               The GitHub Environment the deploy role trusts.
                                Defaults to the account key, so a repository that
                                deploys to several shared accounts has one
                                Environment, and one DEPLOY_ROLE_ARN, per account.
      environments              Instead of environment: several Environments in
                                this account, keyed by name (letters, digits,
                                . _ -), each with its own deploy role. Per
                                Environment, requires_approval (default true):
                                whether the reviewer team must approve; main is
                                the only deploying branch either way. Not for the
                                baseline or a manages_github repository, whose
                                single deploy role the rest of this
                                configuration names.
      workspaces                Named Terraform workspaces of the repository
                                (e.g. its stages: test, production). Each
                                env:/<workspace>/<repo> is created here, empty
                                and create-only, before the repository's first
                                plan, through shared-cicd-infrastructure's
                                workspace provisioner (workspaces.tf, CLF-96).
                                Removing one never deletes its state. Not
                                "default": that workspace needs no creating.
      manages_account_baseline  Exactly one repository per account: the one
                                whose deploy role applies this configuration.
                                Its deploy role may also manage the OIDC provider,
                                the /cicd/gha/ roles and the permission-boundary
                                policies at /boundaries/, which every other
                                repository is explicitly denied, and it is not
                                denied changing itself (github-oidc-role-deploy.tf).
      manages_github            The repository's Terraform manages GitHub itself
                                (Environments, secrets, variables) through the
                                GitHub Apps in shared-cicd-infrastructure: its
                                read role may read the plan App's key, its
                                deploy role the apply App's (once
                                github_app_key_arns is set; github-app-keys-access.tf).
                                Must match github_app_repositories there.
      reviewer_team             Slug of the GitHub team whose approval this
                                repository's Environments require, and which
                                gets access to it (github-team-access.tf).
                                Defaults to github_environment_reviewer_team.

    Set in consumers.auto.tfvars.
  EOT
  type = map(map(object({
    services    = list(string)
    environment = optional(string)
    environments = optional(map(object({
      requires_approval = optional(bool, true)
    })))
    workspaces               = optional(list(string), [])
    manages_account_baseline = optional(bool, false)
    manages_github           = optional(bool, false)
    reviewer_team            = optional(string)
  })))

  # The same slug form as github_environment_reviewer_team: a team's display
  # name is not found.
  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : consumer.reviewer_team == null || can(regex("^[a-z0-9][a-z0-9-]*$", consumer.reviewer_team))
      ]
    ]))
    error_message = "A consumer's reviewer_team, when set, must be a team slug (lowercase letters, digits, hyphens), not its display name."
  }

  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : consumer.manages_account_baseline || length(consumer.services) > 0
      ]
    ]))
    error_message = "Each consumer's services list must be non-empty (an empty list would render a statement with actions = [], which AWS rejects). Only the repository with manages_account_baseline = true may leave it empty."
  }

  # Each entry renders as <svc>:* on *, so it must be a literal service prefix
  # as AWS writes it: lowercase letters, digits and hyphens, nothing else. A
  # wildcard ("*", "iam*", "i*") would render an action pattern that matches
  # every service, IAM and STS included, past the exact-name exclusion below.
  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : [for s in consumer.services : can(regex("^[a-z0-9-]+$", s))]
      ]
    ]))
    error_message = "Every services entry must be a literal AWS service prefix in its normal form (lowercase letters, digits, hyphens; e.g. s3, kms, elasticloadbalancing): no wildcard, no whitespace, no uppercase. It renders as <svc>:* on every resource."
  }

  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : length(setintersection(toset([for s in consumer.services : lower(trimspace(s))]), toset(["iam", "sts", "organizations", "account"]))) == 0
      ]
    ]))
    error_message = "services must not include iam, sts, organizations or account: those would render <svc>:* on every resource and bypass the IAM split (read on *, write on this repository's own path, deny self-modify) that the roles rely on."
  }

  validation {
    condition = alltrue([
      for account, consumers in var.github_oidc_consumers :
      length([for repo, consumer in consumers : repo if consumer.manages_account_baseline]) == 1
    ])
    error_message = "Every account in github_oidc_consumers needs exactly one repository with manages_account_baseline = true: the one whose deploy role applies this configuration in that account."
  }

  # Each account's read role is published as <ACCOUNT>_READ_ROLE_ARN: the
  # account key upper-cased, "-" as "_". Two keys with the same result
  # (foo-bar, foo_bar) would have two workspaces manage one variable of a
  # repository that consumes both, each overwriting the other.
  validation {
    condition     = length(distinct([for account in keys(var.github_oidc_consumers) : upper(replace(account, "-", "_"))])) == length(var.github_oidc_consumers)
    error_message = "Two github_oidc_consumers account keys give the same <ACCOUNT>_READ_ROLE_ARN name once upper-cased with \"-\" as \"_\" (foo-bar and foo_bar). Rename one."
  }

  # A repository's Environment holds that account's DEPLOY_ROLE_ARN and
  # TF_STATE_ROLE_ARN, and the account's deploy role trusts it. The same
  # Environment for one repository in two accounts would have two workspaces
  # manage it, and two deploy roles trust it. GitHub's Environment names
  # ignore case, so neither does this check.
  validation {
    condition = length(distinct(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : (
          consumer.environments == null
          ? [lower("${repo}:${consumer.environment == null ? account : consumer.environment}")]
          : [for environment in keys(consumer.environments) : lower("${repo}:${environment}")]
        )
      ]
      ]))) == length(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : consumer.environments == null ? [repo] : keys(consumer.environments)
      ]
    ]))
    error_message = "A repository uses the same GitHub Environment twice in github_oidc_consumers: in two accounts (an explicit environment, an environments key, or one equal to another account's key), or as two environments keys that differ only in case. Each Environment belongs to one deploy role."
  }

  # environments replaces environment; setting both leaves it unclear which
  # Environment the deploy roles trust. An empty map would leave the
  # repository without any deploy role.
  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : consumer.environments == null || (consumer.environment == null && length(consumer.environments) > 0)
      ]
    ]))
    error_message = "Set environment or environments, not both; environments, when set, lists at least one Environment."
  }

  # The baseline repository's deploy role is the one that applies this
  # configuration and maintains the others, and a manages_github repository's
  # is the one shared-cicd-infrastructure lets read the apply App's key, by the
  # name <repo>-deploy. Both stay a single role.
  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : consumer.environments == null || !(consumer.manages_account_baseline || consumer.manages_github)
      ]
    ]))
    error_message = "environments is not for the manages_account_baseline or manages_github repository: their single <repo>-deploy role is the one the rest of the configuration names. Use environment."
  }

  # A workspace name is a segment of the state key, env:/<workspace>/<repo>,
  # and of the S3 object the provisioner creates: no "/", nothing a shell or a
  # URL would reinterpret. "default" is not a named workspace: its state is
  # <repo>, which a missing object already reads as empty.
  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : [
          for workspace in consumer.workspaces :
          can(regex("^[A-Za-z0-9_-]{1,64}$", workspace)) && workspace != "default"
        ]
      ]
    ]))
    error_message = "Every workspaces entry is a named workspace: letters, digits, _ and - only, at most 64 characters, and not \"default\"."
  }

  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : length(distinct(consumer.workspaces)) == length(consumer.workspaces)
      ]
    ]))
    error_message = "A repository lists the same workspace twice."
  }

  # Each environments key becomes part of a role name,
  # <repo>[-<stage>]-<environment>-deploy, which IAM caps at 64 characters and to
  # letters, digits and +=,.@_-; the narrower set here is also a valid GitHub
  # Environment name, so one name serves both.
  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : [
          for environment in keys(consumer.environments == null ? {} : consumer.environments) :
          can(regex("^[A-Za-z0-9._-]+$", environment)) && length("${repo}${var.stage == null ? "" : "-${var.stage}"}-${environment}-deploy") <= 64
        ]
      ]
    ]))
    error_message = "Every environments key must be letters, digits, . _ - only, and <repo>[-<stage>]-<environment>-deploy at most 64 characters (IAM's role-name limit)."
  }

  # Every deploy role in an account needs a name of its own. A staged
  # consumer's <repo>-<environment>-deploy can equal another consumer's
  # <repo>-deploy (stage-fixture with environment test, and a repository named
  # stage-fixture-test): two Terraform keys, one IAM role name, and the apply
  # fails with EntityAlreadyExists. IAM role names ignore case, so this check
  # does too.
  validation {
    condition = alltrue([
      for account, consumers in var.github_oidc_consumers : length(distinct(flatten([
        for repo, consumer in consumers : (
          consumer.environments == null
          ? [lower("${repo}${var.stage == null ? "" : "-${var.stage}"}-deploy")]
          : [for environment in keys(consumer.environments) : lower("${repo}${var.stage == null ? "" : "-${var.stage}"}-${environment}-deploy")]
        )
        ]))) == length(flatten([
        for repo, consumer in consumers : consumer.environments == null ? [repo] : keys(consumer.environments)
      ]))
    ])
    error_message = "Two consumers in one account generate the same deploy role name, ignoring case: ${join(", ", distinct(flatten([for account, consumers in var.github_oidc_consumers : [for name in flatten([for repo, consumer in consumers : consumer.environments == null ? [lower("${repo}${var.stage == null ? "" : "-${var.stage}"}-deploy")] : [for environment in keys(consumer.environments) : lower("${repo}${var.stage == null ? "" : "-${var.stage}"}-${environment}-deploy")]]) : "${account}/${name}" if length([for other in flatten([for repo, consumer in consumers : consumer.environments == null ? [lower("${repo}${var.stage == null ? "" : "-${var.stage}"}-deploy")] : [for environment in keys(consumer.environments) : lower("${repo}${var.stage == null ? "" : "-${var.stage}"}-${environment}-deploy")]]) : other if other == name]) > 1]])))}. Rename a repository key or an environments key."
  }

  # The repository key IS the role name (<repo>[-<stage>]-read,
  # <repo>[-<stage>]-deploy), and IAM caps a role name at 64 characters: 57
  # leaves room for "-deploy", less the stage when one is set. Without this a
  # long repository name passes plan and fails at apply.
  #
  # The environment check is a conditional, not ||: before Terraform 1.12,
  # || evaluates both sides, so trimspace(null) would fail every consumer that
  # leaves environment unset. The floor in main.tf is now 1.12, where ||
  # short-circuits; the conditional stays because it is correct on any version.
  validation {
    condition = alltrue(flatten([
      for account, consumers in var.github_oidc_consumers : [
        for repo, consumer in consumers : can(regex("^[A-Za-z0-9._-]{1,57}$", repo)) && length("${repo}${var.stage == null ? "" : "-${var.stage}"}-deploy") <= 64 && (consumer.environment == null ? true : length(trimspace(consumer.environment)) > 0)
      ]
    ]))
    error_message = "Repository keys are GitHub repository names (letters, digits, . _ -) of at most 57 characters, so <repo>-deploy fits IAM's 64-character role-name limit (with a stage, <repo>-<stage>-deploy must fit); environment, when set, must be non-empty."
  }
}

variable "repository_settings_owner" {
  description = <<-EOT
    The workspace that manages every consumer's repository-level settings:
    a github_oidc_consumers key (account_key), such as cicd in shared-workload
    or one stage and region in a configuration with a workspace per stage.

    Repository-level settings are attached to the repository, not to one
    workspace's Environment, and have the same value from every workspace:
    the release-tag ruleset, the reviewer team's access, and the
    repository-level Actions variables GH_APP_PLAN_KEY_SECRET_ARN and the
    state backend's TF_STATE_*. Two workspaces managing them would overwrite
    each other on every apply, so this one manages them for every consumer of
    every workspace, including a repository that doesn't deploy through it.
    Every workspace still manages its own Environments, their variables and
    its own <ACCOUNT_KEY>_READ_ROLE_ARN, whose names differ per workspace.

    No default: every configuration names its owner. One rule this module
    can't check: a repository that is a consumer in two configurations
    (shared-workload and connect-one-workload) would have an owner in each.
  EOT
  type        = string
  nullable    = false

  # A key of github_oidc_consumers: the owning workspace has to run, so it
  # must be one that has consumers. Not shared_accounts, which main.tf
  # replaces with aws-organization's remote state.
  validation {
    condition     = contains(keys(var.github_oidc_consumers), var.repository_settings_owner)
    error_message = "repository_settings_owner must be one of github_oidc_consumers' keys (${join(", ", sort(keys(var.github_oidc_consumers)))}): the workspace that manages every consumer's repository-level settings."
  }
}

variable "github_environment_reviewer_team" {
  description = "Slug of the default reviewer team: the GitHub team whose approval a consumer's deploy Environments require, and which gets access to the consumer's repository (github-team-access.tf), because GitHub drops a required reviewer that can't see the repository. A consumer sets its own with reviewer_team. Looked up through the GitHub Apps, which need the organization's Members: read permission for it."
  type        = string

  # GitHub's slug form: lowercase letters, digits and hyphens. A team name
  # ("Cloud Foundations") is not a slug and would not be found.
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.github_environment_reviewer_team))
    error_message = "github_environment_reviewer_team must be a team slug (lowercase letters, digits, hyphens), e.g. cloud-foundations-in-connect-one-app, not its display name."
  }
}

variable "github_environment_reviewer_team_permission" {
  description = "The reviewer team's access on every consumer repository (github-team-access.tf). maintain is what it had, set by hand, on every consumer when this was adopted (2026-10-20). Reviewing a deployment needs at least pull."
  type        = string
  default     = "maintain"

  validation {
    condition     = contains(["pull", "triage", "push", "maintain", "admin"], var.github_environment_reviewer_team_permission)
    error_message = "github_environment_reviewer_team_permission must be one of pull, triage, push, maintain or admin."
  }
}

variable "state_role_arn" {
  description = "ARN of shared-cicd-infrastructure's read/write state role (its state_role_arn output). Every <repo>-deploy role gets sts:AssumeRole and sts:TagSession on it, and only those: its trust admits *-deploy roles only (CLF-88). For <repo>-read, see read_state_role_arn. the backend assumes it with the repository as the ohi:repository session tag, and it then reads every state and writes only the repository's own (key = <repo>; per workspace env:/<workspace>/<repo>). Empty until shared-cicd-infrastructure's first apply (the bootstrap's step 2); then set it here and apply again."
  type        = string
  default     = ""

  # IAM's own name and path characters, never ".+": an ARN with "*" or "?"
  # would be copied into an identity policy as a pattern, granting the hop on
  # every matching role. And IAM's own shape: path segments are non-empty,
  # and the role name is a final segment of 1 to 64 characters, so "role//" or
  # "role/services/" (no name) is rejected too. The same pattern guards
  # read_state_role_arn.
  validation {
    condition     = var.state_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/(?:[A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]{1,64}$", var.state_role_arn))
    error_message = "state_role_arn must be empty or an IAM role ARN (arn:aws:iam::<account>:role/<path/><name>)."
  }
}

variable "create_workspace_states" {
  description = "Whether creating a declared workspace (terraform_data.workspace_state) calls the workspace provisioner. A test switch: terraform test sets it to false in its apply runs, because a provisioner runs even under an override and would otherwise call the real AWS CLI. Off, the records are kept and nothing is created; back on, every record is replaced and its creation runs. Leave it true everywhere else."
  type        = bool
  default     = true
  nullable    = false
}

variable "workspace_provisioner_role_arn" {
  description = "ARN of shared-cicd-infrastructure's workspace provisioner (its workspace_provisioner_role_arn output, CLF-95). The baseline repository's deploy role gets sts:AssumeRole and sts:TagSession on it, and creates through it every declared workspace state that does not exist yet (workspaces.tf). Its trust admits only the deploy roles in its workspace_provisioner_repositories. Empty until shared-cicd-infrastructure has applied that role; while it is, declared workspaces are not created and a check says so."
  type        = string
  default     = ""

  # The same pattern as state_role_arn: IAM's own characters, never a wildcard
  # that would turn the grant into a pattern.
  validation {
    condition     = var.workspace_provisioner_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/(?:[A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]{1,64}$", var.workspace_provisioner_role_arn))
    error_message = "workspace_provisioner_role_arn must be empty or an IAM role ARN (arn:aws:iam::<account>:role/<path/><name>)."
  }
}

variable "read_state_role_arn" {
  description = "ARN of shared-cicd-infrastructure's read-only state role (its read_state_role_arn output, CLF-88). Every <repo>-read role gets sts:AssumeRole and sts:TagSession on it, and nothing on the read/write role: a pull request can assume the read role, so its plan reads state but never writes it, and runs with -lock=false. Empty until shared-cicd-infrastructure has applied that role; then set it here and apply again."
  type        = string
  default     = ""

  validation {
    condition     = var.read_state_role_arn == "" || can(regex("^arn:aws:iam::[0-9]{12}:role/(?:[A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]{1,64}$", var.read_state_role_arn))
    error_message = "read_state_role_arn must be empty or an IAM role ARN (arn:aws:iam::<account>:role/<path/><name>)."
  }

  # Pointing the read roles at the read/write role would quietly undo CLF-88.
  validation {
    condition     = var.read_state_role_arn == "" || var.read_state_role_arn != var.state_role_arn
    error_message = "read_state_role_arn must not be the read/write state role: the read roles are assumable by any pull request and must never reach a role that writes state."
  }
}

variable "state_bucket" {
  description = "Name of shared-cicd-infrastructure's state bucket (its state_bucket output). Published to every consumer repository as TF_STATE_BUCKET, for gha-terraform-backend (github_actions_settings). Empty publishes no TF_STATE_* variable."
  type        = string
  default     = ""

  # S3's naming rules for general purpose buckets, not just its characters:
  # a name the backend would reject must fail here, before it is published.
  validation {
    condition = var.state_bucket == "" || (
      can(regex("^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$", var.state_bucket))
      && !strcontains(var.state_bucket, "..")
      && !can(regex("^[0-9]+(\\.[0-9]+){3}$", var.state_bucket))
      && !anytrue([for prefix in ["xn--", "sthree-", "amzn-s3-demo-"] : startswith(var.state_bucket, prefix)])
      && !anytrue([for suffix in ["-s3alias", "--ol-s3", ".mrap", "--x-s3", "--table-s3"] : endswith(var.state_bucket, suffix)])
    )
    error_message = "state_bucket must be empty or an S3 bucket name: 3 to 63 lower-case letters, digits, dots and hyphens, starting and ending with a letter or digit; no two adjacent dots; not shaped like an IP address; not starting with xn--, sthree- or amzn-s3-demo-; not ending with -s3alias, --ol-s3, .mrap, --x-s3 or --table-s3."
  }
}

variable "state_region" {
  description = "Region of shared-cicd-infrastructure's state bucket (its state_region output). Published to every consumer repository as TF_STATE_REGION, for gha-terraform-backend (github_actions_settings). Empty publishes no TF_STATE_* variable."
  type        = string
  default     = ""

  # The leading segment is not always two letters: the European Sovereign
  # Cloud's region is eusc-de-east-1.
  validation {
    condition     = var.state_region == "" || can(regex("^[a-z]{2,}(-[a-z]+)+-[0-9]+$", var.state_region))
    error_message = "state_region must be empty or an AWS region (e.g. us-west-2, us-gov-west-1, eusc-de-east-1)."
  }
}

variable "github_app_key_arns" {
  description = <<-EOT
    The ARNs of shared-cicd-infrastructure's GitHub App keys, from its outputs:
    plan_secret_arn and apply_secret_arn from github_app_key_secret_arns (plan,
    apply), kms_key_arn from github_app_keys_kms_key_arn. The read role of every
    manages_github repository may read the plan key, its deploy role the apply
    key (github-app-keys-access.tf). Null until shared-cicd-infrastructure has
    applied the keys; then set it here and apply again, as with state_role_arn.
  EOT
  type = object({
    plan_secret_arn  = string
    apply_secret_arn = string
    kms_key_arn      = string
  })
  default = null

  # Secrets Manager's name characters, never ".+": a "*" or "?" in a secret
  # ARN would become a pattern in the grants and, worse, in the read role's
  # NotResource deny exception, exempting every matching secret from it.
  # The full ARN, with Secrets Manager's six-character suffix: the read role's
  # deny exception is a NotResource on it, and a partial ARN would match no
  # request, leaving the plan key denied with no hint why.
  validation {
    condition = var.github_app_key_arns == null ? true : alltrue([
      for arn in [var.github_app_key_arns.plan_secret_arn, var.github_app_key_arns.apply_secret_arn] :
      can(regex("^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[A-Za-z0-9/_+=.@-]+-[A-Za-z0-9]{6}$", arn))
    ])
    error_message = "plan_secret_arn and apply_secret_arn must be full secret ARNs, ending in Secrets Manager's -XXXXXX suffix, as shared-cicd-infrastructure's github_app_key_secret_arns output gives them."
  }

  validation {
    condition     = var.github_app_key_arns == null ? true : var.github_app_key_arns.plan_secret_arn != var.github_app_key_arns.apply_secret_arn
    error_message = "plan_secret_arn and apply_secret_arn must differ: the plan and apply Apps' keys are what separates a PR's read-only token from an apply's write token."
  }

  validation {
    condition     = var.github_app_key_arns == null ? true : can(regex("^arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]+$", var.github_app_key_arns.kms_key_arn))
    error_message = "kms_key_arn must be a KMS key ARN (arn:aws:kms:<region>:<account>:key/<id>), not an alias: shared-cicd-infrastructure's github_app_keys_kms_key_arn output."
  }
}

variable "permission_boundaries" {
  description = <<-EOT
    The permission-boundary classes to render in this account, keyed by class
    name, in the shape aws-organization publishes them (its
    shared_permission_boundaries output). Each becomes a policy at /boundaries/
    named <namespace>-<application>-<class> from the label (omron-shared-deploy,
    …), the same name in every account of that application, so an Identity
    Center permission set can reference the users class by name and path.
    Empty (the default) renders none.

    When set, it must carry the classes the federation's roles use (deploy,
    read and service), and those must cover every consumer's services in every
    account: deploy <svc>:*, read <svc>:Get*, List* and Describe*. A consumer
    that adds a service needs it in aws-organization's classes first.
  EOT
  type = map(object({
    allow_all                 = optional(bool, false)
    allowed_actions           = optional(list(string), [])
    denied_actions            = optional(list(string), [])
    permit_policy_mutation    = optional(bool, false)
    permit_human_user_actions = optional(bool, false)
    permit_org_governance     = optional(bool, false)
  }))
  default  = {}
  nullable = false

  validation {
    condition     = length(var.permission_boundaries) == 0 || length(setsubtract(["deploy", "read", "service"], keys(var.permission_boundaries))) == 0
    error_message = "permission_boundaries must carry the deploy, read and service classes (missing: ${join(", ", setsubtract(["deploy", "read", "service"], keys(var.permission_boundaries)))}): the consumers' deploy and read roles and the roles they create under /services/<repo>/ are bounded by them."
  }

  validation {
    condition     = alltrue([for name, class in var.permission_boundaries : can(regex("^[a-z][a-z0-9-]*$", name))])
    error_message = "Every permission_boundaries key must be a lower-case class name (letters, digits, hyphens): it becomes part of the policy name."
  }

  # Cross-variable: the classes against every consumer's services, in every
  # account, so a gap shows in any account's plan. The conditional (not ||)
  # indexes deploy and read only once the validation above has them present.
  validation {
    condition = length(setsubtract(["deploy", "read", "service"], keys(var.permission_boundaries))) > 0 ? true : length([
      for pair in flatten([
        for account, consumers in var.github_oidc_consumers : [
          for repo, consumer in consumers : [for svc in consumer.services : { repo = repo, svc = svc }]
        ]
      ]) : "${pair.repo}/${pair.svc}"
      if !(
        (var.permission_boundaries["deploy"].allow_all || contains(var.permission_boundaries["deploy"].allowed_actions, "${pair.svc}:*")) &&
        (var.permission_boundaries["read"].allow_all || length(setsubtract(["${pair.svc}:Get*", "${pair.svc}:List*", "${pair.svc}:Describe*"], var.permission_boundaries["read"].allowed_actions)) == 0)
      )
    ]) == 0
    error_message = "The deploy and read permission-boundary classes don't cover every consumer's service: each needs <svc>:* in deploy and <svc>:Get*, <svc>:List* and <svc>:Describe* in read. Add it to aws-organization's shared_permission_boundaries first. Uncovered (repository/service): ${length(setsubtract(["deploy", "read", "service"], keys(var.permission_boundaries))) > 0 ? "" : join(", ", sort(distinct([
      for pair in flatten([
        for account, consumers in var.github_oidc_consumers : [
          for repo, consumer in consumers : [for svc in consumer.services : { repo = repo, svc = svc }]
        ]
      ]) : "${pair.repo}/${pair.svc}"
      if !(
        (var.permission_boundaries["deploy"].allow_all || contains(var.permission_boundaries["deploy"].allowed_actions, "${pair.svc}:*")) &&
        (var.permission_boundaries["read"].allow_all || length(setsubtract(["${pair.svc}:Get*", "${pair.svc}:List*", "${pair.svc}:Describe*"], var.permission_boundaries["read"].allowed_actions)) == 0)
      )
    ])))}."
  }
}
