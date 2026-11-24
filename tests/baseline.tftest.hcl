# The module, planned with mocked providers against a fixture account: the
# CICD account's federation as shared-workload deploys it (account_key cicd,
# its consumers and settings copied into the variables below). Run from the
# module's directory (tests/README.md).

# Mocked providers fake locally computed attributes too: a mocked
# aws_iam_policy_document renders random text as json, which the policy
# resources reject at plan, and a mocked tls_certificate has no certificates.
# mock_data gives every instance of those types, the module's included, a
# value that passes the plan-time checks. The rendered policies are therefore
# not under test here; names, paths, keys and outputs are.
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    }
  }

  # The owner's class policies, read without manage_account_resources: the
  # same document the module renders (the mocked json above), as the owner
  # would have stored it, so the comparison holds unless a run overrides it.
  mock_data "aws_iam_policy" {
    defaults = {
      policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Deny\",\"Action\":\"*\",\"Resource\":\"*\"}]}"
    }
  }

  # The owner's provider, read without manage_account_resources: a mocked
  # list would be random text, which the audience check rejects.
  mock_data "aws_iam_openid_connect_provider" {
    defaults = {
      client_id_list = ["sts.amazonaws.com"]
    }
  }
}

# GitHub's OIDC subject prefix per consumer (github-oidc-subjects.tf). The
# default answers 404, so a run that reaches a repository nobody set up here
# fails loudly instead of trusting a made-up prefix; the two real consumers get
# their immutable prefixes below, as GitHub returns them today.
mock_provider "github" {
  # The reviewer team, as GitHub returns it (github-team-access.tf).
  mock_data "github_team" {
    defaults = {
      id   = "18466465"
      slug = "cloud-foundations-in-connect-one-app"
    }
  }

  mock_data "github_rest_api" {
    defaults = {
      code = 404
      body = "{\"message\":\"Not Found\"}"
    }
  }
}

override_data {
  target = data.github_rest_api.oidc_subject["shared-workload"]
  values = {
    code = 200
    body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/shared-workload@1361553613\"}"
  }
}

override_data {
  target = data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]
  values = {
    code = 200
    body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/shared-cicd-infrastructure@1398327937\"}"
  }
}

override_data {
  target = data.github_rest_api.oidc_subject["shared-terraform-registry"]
  values = {
    code = 200
    body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/shared-terraform-registry@1423117984\"}"
  }
}

# Each Environment's deployment policies (github-environments.tf), as GitHub
# returns them today: the main branch policy and nothing else. The registry's
# two stages as GitHub will return them once their Environments exist.
override_data {
  target = data.github_rest_api.deployment_policies["shared-terraform-registry:test"]
  values = {
    code = 200
    body = "{\"total_count\":1,\"branch_policies\":[{\"id\":1,\"name\":\"main\",\"type\":\"branch\"}]}"
  }
}

override_data {
  target = data.github_rest_api.deployment_policies["shared-terraform-registry:production"]
  values = {
    code = 200
    body = "{\"total_count\":1,\"branch_policies\":[{\"id\":2,\"name\":\"main\",\"type\":\"branch\"}]}"
  }
}

override_data {
  target = data.github_rest_api.deployment_policies["shared-workload"]
  values = {
    code = 200
    body = "{\"total_count\":1,\"branch_policies\":[{\"id\":61640649,\"name\":\"main\",\"type\":\"branch\"}]}"
  }
}

override_data {
  target = data.github_rest_api.deployment_policies["shared-cicd-infrastructure"]
  values = {
    code = 200
    body = "{\"total_count\":1,\"branch_policies\":[{\"id\":61640656,\"name\":\"main\",\"type\":\"branch\"}]}"
  }
}

mock_provider "tls" {
  mock_data "tls_certificate" {
    defaults = {
      certificates = [{ sha1_fingerprint = "0000000000000000000000000000000000000000" }]
    }
  }
}

variables {
  account_key = "cicd"
  account_id  = "123456789012"

  # shared-workload's account label: omron-shared-cicd.
  label_context = {
    namespace          = "omron"
    application        = "shared"
    name               = "cicd"
    aws_region         = "us-west-2"
    owner              = "cloud-foundations"
    stack_name_enabled = false
    tags               = { Organization = "omron" }
  }

  # The settings shared-workload sets in terraform.tfvars and
  # consumers.auto.tfvars, which terraform test read when this suite ran from
  # the root configuration: the CICD account's three consumers, the reviewer
  # team and the GitHub App keys.
  github_oidc_consumers = {
    cicd = {
      "shared-workload" = {
        manages_account_baseline = true
        services                 = []
        workspaces               = ["cicd"]
        manages_github           = true
      }
      "shared-cicd-infrastructure" = {
        services = ["s3", "kms", "secretsmanager"]
      }
      "shared-terraform-registry" = {
        services     = ["apigateway", "dynamodb", "events", "lambda", "logs", "s3", "ssm", "states"]
        environments = { test = { requires_approval = false }, production = {} }
        workspaces   = ["test", "production"]
      }
    }
  }
  # No default: every configuration names the workspace that owns the
  # repository-level settings. shared-workload's is cicd.
  repository_settings_owner        = "cicd"
  github_environment_reviewer_team = "cloud-foundations-in-connect-one-app"
  github_app_key_arns = {
    plan_secret_arn  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:fixture-github-app-terraform-plan-Pl4nAb"
    apply_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:fixture-github-app-terraform-apply-Ap7lCd"
    kms_key_arn      = "arn:aws:kms:us-west-2:123456789012:key/00000000-0000-4000-8000-000000000000"
  }

  state_role_arn      = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state"
  read_state_role_arn = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state-read"
  # The provisioner as it will be set once CLF-95 is applied, so the
  # registry's declared workspaces plan as creations rather than tripping the
  # check that waits for it. A run with command = apply must set it to "":
  # terraform_data.workspace_state's local-exec calls the real AWS CLI, and an
  # override does not stop a provisioner. The script is tested on its own,
  # against a stub (tests/create-workspace-state.test.sh).
  workspace_provisioner_role_arn = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state-workspace-provisioner"
  state_bucket                   = "fixture-tf-state"
  state_region                   = "us-west-2"
}

# The mocked aws_iam_policy_document renders one placeholder json for every
# document, so "this role's policy is that document's json" would hold for
# any document. The two state-hop documents get distinct json here, so the
# CLF-88 assertions can tell which hop a role was given.
override_data {
  target = data.aws_iam_policy_document.cicd_assume_state
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"readWriteStateHop\",\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"*\"}]}"
  }
}

override_data {
  target = data.aws_iam_policy_document.cicd_assume_read_state
  values = {
    json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"readOnlyStateHop\",\"Effect\":\"Allow\",\"Action\":\"sts:AssumeRole\",\"Resource\":\"*\"}]}"
  }
}

run "cicd_baseline_plans" {
  command = plan

  # Keys are compared through the outputs, not the resource maps: a failing
  # assertion renders every value its condition touches, and rendering a whole
  # aws_iam_role map crashes Terraform 1.15 on a marked value. tolist(): sort()
  # returns a list, and a list never equals a tuple literal.
  assert {
    condition     = sort(keys(output.read_role_arn)) == tolist(["shared-cicd-infrastructure", "shared-terraform-registry", "shared-workload"]) && sort(keys(output.deploy_role_arn)) == tolist(["shared-cicd-infrastructure", "shared-terraform-registry:production", "shared-terraform-registry:test", "shared-workload"])
    error_message = "Every consumer of the cicd account gets a read role, and a deploy role per Environment: one for shared-cicd-infrastructure and shared-workload, one per stage (test, production) for shared-terraform-registry."
  }

  assert {
    condition     = aws_iam_role.cicd_deploy["shared-cicd-infrastructure"].name == "shared-cicd-infrastructure-deploy" && aws_iam_role.cicd_deploy["shared-cicd-infrastructure"].path == "/cicd/gha/"
    error_message = "Deploy roles are named <repo>-deploy at /cicd/gha/."
  }

  assert {
    condition     = aws_iam_role.cicd_read["shared-cicd-infrastructure"].name == "shared-cicd-infrastructure-read" && aws_iam_role.cicd_read["shared-cicd-infrastructure"].path == "/cicd/gha/"
    error_message = "Read roles are named <repo>-read at /cicd/gha/."
  }

  # The repository tag is what the state role scopes writes by: the session tag
  # must equal it. Both roles of every repository carry their own name; a
  # missing or wrong value would block state, or speak for another repository.
  assert {
    condition = alltrue([
      for repo in ["shared-workload", "shared-cicd-infrastructure"] :
      aws_iam_role.cicd_read[repo].tags["ohi:repository"] == repo && aws_iam_role.cicd_deploy[repo].tags["ohi:repository"] == repo
    ])
    error_message = "Both pipeline roles of every repository carry ohi:repository = <repo>."
  }


  assert {
    condition     = keys(output.github_actions_settings["shared-cicd-infrastructure"].environments) == ["cicd"] && keys(output.github_actions_settings["shared-workload"].environments) == ["cicd"]
    error_message = "A consumer's deploy Environment defaults to the account key."
  }

  assert {
    condition     = keys(output.github_actions_settings["shared-cicd-infrastructure"].repository_variables) == ["CICD_READ_ROLE_ARN", "TF_STATE_BUCKET", "TF_STATE_REGION", "TF_STATE_ROLE_ARN"]
    error_message = "The repository-level variables are the read role (<ACCOUNT>_READ_ROLE_ARN) and the state backend's TF_STATE_*."
  }

  # gha-terraform-backend's variables: the read-only state role at repository
  # level, which every job outside an Environment gets; the read/write one in
  # the Environment, which GitHub prefers in the gated apply.
  assert {
    condition = alltrue(flatten([
      for repo, settings in output.github_actions_settings : [
        settings.repository_variables["TF_STATE_ROLE_ARN"] == var.read_state_role_arn,
        [for environment, variables in settings.environments : variables["TF_STATE_ROLE_ARN"] == var.state_role_arn],
        settings.repository_variables["TF_STATE_BUCKET"] == var.state_bucket,
        settings.repository_variables["TF_STATE_REGION"] == var.state_region,
      ]
    ]))
    error_message = "Every repository gets TF_STATE_BUCKET, TF_STATE_REGION and the read-only TF_STATE_ROLE_ARN at repository level, and the read/write TF_STATE_ROLE_ARN in its Environment."
  }


  assert {
    condition     = length(aws_iam_role_policy.cicd_read_assume_state_access) == length(output.read_role_arn) && length(aws_iam_role_policy.cicd_deploy_assume_state_access) == length(output.deploy_role_arn)
    error_message = "With the state roles set, every read and deploy role gets its assume-state policy."
  }

  # CLF-88: deploy roles assume the read/write state role, read roles the
  # read-only one, each tagging the session with its repository. A read role,
  # which any pull request can assume, never reaches a role that writes state.
  assert {
    condition = alltrue([
      for repo, p in aws_iam_role_policy.cicd_deploy_assume_state_access : p.policy == data.aws_iam_policy_document.cicd_assume_state[0].json
    ]) && toset(data.aws_iam_policy_document.cicd_assume_state[0].statement[0].resources) == toset([var.state_role_arn]) && toset(data.aws_iam_policy_document.cicd_assume_state[0].statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"])
    error_message = "Every deploy role may assume the read/write state role, and tag the session with its repository, and nothing else."
  }

  assert {
    condition = alltrue([
      for repo, p in aws_iam_role_policy.cicd_read_assume_state_access : p.policy == data.aws_iam_policy_document.cicd_assume_read_state[0].json
    ]) && toset(data.aws_iam_policy_document.cicd_assume_read_state[0].statement[0].resources) == toset([var.read_state_role_arn]) && toset(data.aws_iam_policy_document.cicd_assume_read_state[0].statement[0].actions) == toset(["sts:AssumeRole", "sts:TagSession"])
    error_message = "Every read role may assume the read-only state role, and tag the session with its repository, and nothing else: never the read/write one."
  }

}

# A partial backend publishes nothing: a bucket without the roles, or the
# read-only role without the read/write one its apply needs, would only
# move the failure into the pipeline.
run "without_the_full_state_backend_no_tf_state_variables" {
  command = plan

  variables {
    state_region = ""
  }

  # Without the bucket's region the declared workspaces cannot be created
  # either, and the check says so (workspaces.tf).
  expect_failures = [check.declared_workspaces_can_be_created]

  assert {
    condition = alltrue(flatten([
      for repo, settings in output.github_actions_settings : [
        for name in concat(flatten([for environment, variables in settings.environments : keys(variables)]), keys(settings.repository_variables)) :
        !startswith(name, "TF_STATE_")
      ]
    ]))
    error_message = "Without all four of state_bucket, state_region, state_role_arn and read_state_role_arn, no TF_STATE_* variable is published."
  }
}

# Two workspaces managing the same repository-level variable would
# overwrite each other, so a workspace that is not
# repository_settings_owner manages only its own read-role variable.
run "another_workspace_manages_only_its_read_role_variable" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"] }
      }
      identity = {
        "shared-workload" = { manages_account_baseline = true, services = [] }
      }
    }
    repository_settings_owner = "identity"
  }

  assert {
    condition = sort(keys(github_actions_variable.consumer)) == tolist([
      "shared-cicd-infrastructure:CICD_READ_ROLE_ARN",
      "shared-workload:CICD_READ_ROLE_ARN",
    ])
    error_message = "Outside repository_settings_owner only <ACCOUNT>_READ_ROLE_ARN is managed; the plan key's ARN and TF_STATE_* belong to the owning workspace."
  }

  assert {
    condition     = length(github_repository_ruleset.release_tags) == 0
    error_message = "The version tags' ruleset is a repository setting, managed only by repository_settings_owner."
  }

  assert {
    condition     = length(github_team_repository.reviewers) == 0
    error_message = "The reviewer team's repository access is a repository setting too, managed only by repository_settings_owner."
  }

  assert {
    condition     = length(github_actions_environment_variable.consumer) == 5
    error_message = "Environment variables are per account (one Environment each), so every workspace manages its own."
  }

  assert {
    condition     = contains(keys(output.github_actions_settings["shared-workload"].repository_variables), "TF_STATE_BUCKET")
    error_message = "The output still lists every variable a repository needs; only what this workspace manages narrows."
  }
}

# The owning workspace sets the shared variables for every consumer of every
# account: a repository that deploys only into another account needs
# TF_STATE_* just the same, but not this account's read-role variable.
run "the_owner_manages_shared_variables_for_other_accounts_consumers" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"] }
      }
      identity = {
        "shared-workload"  = { manages_account_baseline = true, services = [] }
        "connect-identity" = { services = ["cognito-idp"], manages_github = true }
      }
    }
  }

  assert {
    condition = alltrue([
      for name in ["TF_STATE_BUCKET", "TF_STATE_REGION", "TF_STATE_ROLE_ARN", "GH_APP_PLAN_KEY_SECRET_ARN"] :
      contains(keys(github_actions_variable.consumer), "connect-identity:${name}")
    ]) && !contains(keys(github_actions_variable.consumer), "connect-identity:CICD_READ_ROLE_ARN")
    error_message = "A repository that deploys only into another account gets the shared variables from the owning workspace (GH_APP_PLAN_KEY_SECRET_ARN where it manages GitHub there), and no read-role variable for an account it does not deploy into."
  }

  assert {
    condition     = length([for k in keys(github_actions_environment_variable.consumer) : k if startswith(k, "connect-identity:")]) == 0
    error_message = "Its Environment variables belong to the workspace of the account it deploys into."
  }
}

run "account_keys_that_name_the_same_read_role_variable_are_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd      = { "shared-workload" = { manages_account_baseline = true, services = [] } }
      "foo-bar" = { "shared-workload" = { manages_account_baseline = true, services = [] } }
      foo_bar   = { "shared-workload" = { manages_account_baseline = true, services = [] } }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# Each account key names <ACCOUNT>_READ_ROLE_ARN, and GitHub refuses a
# variable name with anything but letters, digits and "_", one starting with a
# digit, or one starting with GITHUB_. One run per rule.
run "an_account_key_with_a_dot_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd     = { "shared-workload" = { manages_account_baseline = true, services = [] } }
      "dev.eu" = { "shared-workload" = { manages_account_baseline = true, services = [] } }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "an_account_key_starting_with_a_digit_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd    = { "shared-workload" = { manages_account_baseline = true, services = [] } }
      "1-dev" = { "shared-workload" = { manages_account_baseline = true, services = [] } }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "an_account_key_github_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd   = { "shared-workload" = { manages_account_baseline = true, services = [] } }
      github = { "shared-workload" = { manages_account_baseline = true, services = [] } }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# The stage-and-region keys connect-one-workload uses pass.
run "stage_and_region_account_keys_are_accepted" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd     = { "shared-workload" = { manages_account_baseline = true, services = [] } }
      "dev-eu" = { "shared-workload" = { manages_account_baseline = true, services = [] } }
      prd_us   = { "shared-workload" = { manages_account_baseline = true, services = [] } }
    }
  }

  assert {
    condition     = contains(keys(output.github_actions_settings["shared-workload"].repository_variables), "CICD_READ_ROLE_ARN")
    error_message = "The cicd workspace still publishes its read role's variable."
  }
}

run "the_same_environment_in_two_accounts_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3"], environment = "production" }
      }
      identity = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3"], environment = "Production" }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "an_environment_named_after_another_account_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3"], environment = "identity" }
      }
      identity = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# The owner must be a workspace with consumers, whatever accounts the caller
# knows of: the module sees only github_oidc_consumers.
run "an_owner_account_without_consumers_is_rejected" {
  command = plan

  variables {
    repository_settings_owner = "identity"
  }

  expect_failures = [var.repository_settings_owner]
}

run "an_unknown_repository_settings_owner_is_rejected" {
  command = plan

  variables {
    repository_settings_owner = "nope"
  }

  expect_failures = [var.repository_settings_owner]
}

# CLF-93: each consumer's deploy Environment, adopted as it was set by hand:
# only main deploys, the reviewer team approves.
run "environments_are_managed_as_set_by_hand" {
  command = plan

  assert {
    condition     = sort(keys(github_repository_environment.consumer)) == tolist(["shared-cicd-infrastructure", "shared-terraform-registry:production", "shared-terraform-registry:test", "shared-workload"]) && sort(keys(github_repository_environment_deployment_policy.main)) == tolist(["shared-cicd-infrastructure", "shared-terraform-registry:production", "shared-terraform-registry:test", "shared-workload"])
    error_message = "Every consumer in the account gets its deploy Environment and a deployment policy on it."
  }

  assert {
    condition = alltrue([
      for key, env in github_repository_environment.consumer :
      contains(keys(output.github_actions_settings[env.repository].environments), env.environment)
      && env.can_admins_bypass && env.prevent_self_review
      && toset(env.reviewers[0].teams) == toset([tonumber(data.github_team.reviewers["cloud-foundations-in-connect-one-app"].id)])
      && env.deployment_branch_policy[0].custom_branch_policies && !env.deployment_branch_policy[0].protected_branches
      if key != "shared-terraform-registry:test"
    ])
    error_message = "Each Environment is the one github_actions_settings names, with the reviewer team, custom branch policies, admin bypass as set by hand, and no self-review: every one but the registry's test stage, which drops the reviewers on purpose."
  }

  assert {
    condition = (
      length(github_repository_environment.consumer["shared-terraform-registry:test"].reviewers) == 0
      && !github_repository_environment.consumer["shared-terraform-registry:test"].prevent_self_review
      && github_repository_environment.consumer["shared-terraform-registry:test"].deployment_branch_policy[0].custom_branch_policies
    )
    error_message = "The registry's test stage deploys from main without approval (requires_approval = false), and keeps the custom branch policy."
  }

  assert {
    condition     = alltrue([for key, policy in github_repository_environment_deployment_policy.main : policy.branch_pattern == "main" && policy.tag_pattern == null && contains(keys(output.github_actions_settings[policy.repository].environments), policy.environment)])
    error_message = "The only branch allowed to deploy is main, no tag."
  }
}

run "a_reviewer_team_name_instead_of_its_slug_is_rejected" {
  command = plan

  variables {
    github_environment_reviewer_team = "Cloud Foundations"
  }

  expect_failures = [var.github_environment_reviewer_team]
}

run "an_unknown_reviewer_team_permission_is_rejected" {
  command = plan

  variables {
    github_environment_reviewer_team_permission = "write"
  }

  expect_failures = [var.github_environment_reviewer_team_permission]
}

# The reviewer team gets access to every consumer repository, so GitHub keeps
# it as the Environments' required reviewer (a 422 on 2026-10-20 without it).
run "the_reviewer_team_gets_access_to_every_consumer" {
  command = plan

  assert {
    condition = (
      sort(keys(github_team_repository.reviewers)) == tolist([
        "shared-cicd-infrastructure/cloud-foundations-in-connect-one-app",
        "shared-terraform-registry/cloud-foundations-in-connect-one-app",
        "shared-workload/cloud-foundations-in-connect-one-app",
      ])
      && alltrue([for access in github_team_repository.reviewers : access.team_id == "18466465" && access.permission == "maintain"])
    )
    error_message = "The cicd workspace gives each consumer's reviewer team (here the default, looked up by slug) maintain on its repository, keyed <repo>/<team>."
  }

  assert {
    condition     = keys(data.github_team.reviewers) == ["cloud-foundations-in-connect-one-app"] && data.github_team.reviewers["cloud-foundations-in-connect-one-app"].summary_only
    error_message = "Only the teams in use are looked up, by slug and summary only: here just the default."
  }
}

# The Apps must be installed on every consumer of every account, not only this
# workspace's: the list the PR plan job checks the installation against.
run "the_installation_list_spans_every_account" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms"] }
      }
      identity = {
        "shared-workload"  = { manages_account_baseline = true, services = [] }
        "connect-identity" = { services = ["cognito-idp"] }
      }
    }
  }

  assert {
    condition     = output.github_app_installation_repositories == tolist(["connect-identity", "shared-cicd-infrastructure", "shared-workload"])
    error_message = "Every consumer of every account, each once, sorted."
  }

  assert {
    condition = sort(keys(github_repository_ruleset.release_tags)) == tolist(["connect-identity", "shared-cicd-infrastructure", "shared-workload"]) && alltrue([
      for repo, ruleset in github_repository_ruleset.release_tags :
      ruleset.target == "tag" && ruleset.enforcement == "active"
      && ruleset.conditions[0].ref_name[0].include == tolist(["refs/tags/[0-9]*.[0-9]*.[0-9]*"])
      && ruleset.rules[0].update && ruleset.rules[0].deletion && ruleset.rules[0].non_fast_forward
      && !coalesce(ruleset.rules[0].creation, false)
    ])
    error_message = "The owning workspace protects the version tags of every consumer of every account against update and deletion, and leaves their creation (publishing a release) open."
  }
}

run "a_malformed_state_bucket_is_rejected" {
  command = plan

  variables {
    state_bucket = "Fixture_TF_State"
  }

  expect_failures = [var.state_bucket]
}

# S3's naming rules beyond its characters, one run each: every one of these
# passes the character check alone.
run "a_state_bucket_with_adjacent_dots_is_rejected" {
  command = plan

  variables {
    state_bucket = "fixture..tf-state"
  }

  expect_failures = [var.state_bucket]
}

run "a_state_bucket_shaped_like_an_ip_address_is_rejected" {
  command = plan

  variables {
    state_bucket = "192.168.5.4"
  }

  expect_failures = [var.state_bucket]
}

run "a_state_bucket_with_a_reserved_prefix_is_rejected" {
  command = plan

  variables {
    state_bucket = "xn--fixture-tf-state"
  }

  expect_failures = [var.state_bucket]
}

run "a_state_bucket_with_a_reserved_suffix_is_rejected" {
  command = plan

  variables {
    state_bucket = "fixture-tf-state-s3alias"
  }

  expect_failures = [var.state_bucket]
}

# The positive controls: a dotted name that is not an IP address, and the
# European Sovereign Cloud's region, whose first segment is four letters.
run "a_dotted_state_bucket_and_a_sovereign_cloud_region_are_accepted" {
  command = plan

  variables {
    state_bucket = "fixture.tf-state"
    state_region = "eusc-de-east-1"
  }

  assert {
    condition     = output.github_actions_settings["shared-workload"].repository_variables["TF_STATE_BUCKET"] == "fixture.tf-state" && output.github_actions_settings["shared-workload"].repository_variables["TF_STATE_REGION"] == "eusc-de-east-1"
    error_message = "A dotted bucket name and eusc-de-east-1 are valid and are published."
  }
}

run "a_malformed_state_region_is_rejected" {
  command = plan

  variables {
    state_region = "us-west"
  }

  expect_failures = [var.state_region]
}

run "without_state_access_role_no_state_policies" {
  command = plan

  variables {
    state_role_arn      = ""
    read_state_role_arn = ""
  }

  assert {
    condition     = length(aws_iam_role_policy.cicd_read_assume_state_access) == 0 && length(aws_iam_role_policy.cicd_deploy_assume_state_access) == 0
    error_message = "Before shared-cicd-infrastructure exists (empty state role ARNs) no role gets a state-access policy; the roles themselves still plan."
  }
}

# Before the read-only role exists, the read roles get no state access at all,
# rather than falling back to the read/write role (CLF-88).
run "without_read_state_role_read_roles_get_no_state_access" {
  command = plan

  variables {
    read_state_role_arn = ""
  }

  assert {
    condition     = length(aws_iam_role_policy.cicd_read_assume_state_access) == 0 && length(aws_iam_role_policy.cicd_deploy_assume_state_access) == length(output.deploy_role_arn)
    error_message = "Without read_state_role_arn the read roles get no state-access policy, never the read/write role; the deploy roles keep theirs."
  }
}

run "read_state_role_must_not_be_the_read_write_one" {
  command = plan

  variables {
    read_state_role_arn = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state"
  }

  expect_failures = [var.read_state_role_arn]
}

run "a_malformed_read_state_role_is_rejected" {
  command = plan

  variables {
    read_state_role_arn = "omron-shared-cicd-tf-state-read"
  }

  expect_failures = [var.read_state_role_arn]
}

run "a_malformed_state_role_is_rejected" {
  command = plan

  variables {
    state_role_arn = "omron-shared-cicd-tf-state"
  }

  expect_failures = [var.state_role_arn]
}

# An account without consumers would plan the deletion of everything the
# module manages for it, so the module refuses it, whoever calls it.
run "an_account_key_without_consumers_is_rejected" {
  command = plan

  variables {
    account_key = "identity"
  }

  expect_failures = [var.account_key]
}

run "malformed_account_id_is_rejected" {
  command = plan

  variables {
    account_id = "<account-id>"
  }

  expect_failures = [var.account_id]
}

run "iam_in_services_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3", "iam"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# A wildcard service renders an action pattern across every service, IAM and
# STS included, which the exact-name exclusion cannot see.
# GitHub encodes ":" in a context value as %3A in the sub claim; the trust
# must match the encoded form, the settings output keeps the raw name.
# Both trusts are built on the prefix GitHub reports, IDs included: the
# name-only form would never match these repositories' tokens.
run "trusts_use_the_subject_prefix_github_reports" {
  command = plan

  assert {
    condition = alltrue([
      for repo, prefix in {
        "shared-workload"            = "repo:OmronHealthCare-OHI@20930349/shared-workload@1361553613"
        "shared-cicd-infrastructure" = "repo:OmronHealthCare-OHI@20930349/shared-cicd-infrastructure@1398327937"
      } :
      one(flatten([
        for c in data.aws_iam_policy_document.cicd_read_assume_role[repo].statement[0].condition :
        tolist(c.values) if c.variable == "token.actions.githubusercontent.com:sub"
      ])) == "${prefix}:*"
      && one(flatten([
        for c in data.aws_iam_policy_document.cicd_deploy_assume_role[repo].statement[0].condition :
        tolist(c.values) if c.variable == "token.actions.githubusercontent.com:sub"
      ])) == "${prefix}:environment:cicd"
    ])
    error_message = "The read role trusts <prefix>:* and the deploy role <prefix>:environment:<env>, with GitHub's prefix as reported."
  }
}

# An older repository keeps the name-only prefix; it is trusted as reported.
run "a_name_only_prefix_is_trusted_as_reported" {
  command = plan

  override_data {
    target = data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":false,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI/shared-cicd-infrastructure\"}"
    }
  }

  assert {
    condition = one(flatten([
      for c in data.aws_iam_policy_document.cicd_read_assume_role["shared-cicd-infrastructure"].statement[0].condition :
      tolist(c.values) if c.variable == "token.actions.githubusercontent.com:sub"
    ])) == "repo:OmronHealthCare-OHI/shared-cicd-infrastructure:*"
    error_message = "A repository on the name-only subject is trusted with repo:<org>/<repo>:*."
  }
}

# Each rejection breaks only its own rule (the others' fields are valid), so
# the run proves that rule and not just the prefix check behind it.
run "a_repository_github_does_not_find_is_rejected" {
  command = plan

  override_data {
    target = data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]
    values = {
      code = 404
      body = "{\"use_default\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/shared-cicd-infrastructure@1398327937\"}"
    }
  }

  expect_failures = [data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]]
}

run "a_custom_subject_template_is_rejected" {
  command = plan

  override_data {
    target = data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]
    values = {
      code = 200
      body = "{\"use_default\":false,\"include_claim_keys\":[\"repository_id\",\"context\"],\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/shared-cicd-infrastructure@1398327937\"}"
    }
  }

  expect_failures = [data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]]
}

# A prefix naming another repository (or organization) must never become a
# trust, whatever GitHub's answer looked like.
run "a_prefix_for_another_repository_is_rejected" {
  command = plan

  override_data {
    target = data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/shared-workload@1361553613\"}"
    }
  }

  expect_failures = [data.github_rest_api.oidc_subject["shared-cicd-infrastructure"]]
}

run "colon_in_environment_is_encoded_in_the_subject" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3"], environment = "production:v2" }
      }
    }
  }

  assert {
    condition = one(flatten([
      for c in data.aws_iam_policy_document.cicd_deploy_assume_role["shared-cicd-infrastructure"].statement[0].condition :
      tolist(c.values) if c.variable == "token.actions.githubusercontent.com:sub"
    ])) == "repo:OmronHealthCare-OHI@20930349/shared-cicd-infrastructure@1398327937:environment:production%3Av2"
    error_message = "A colon in the Environment name must be %3A in the trusted subject, as GitHub emits it."
  }

  assert {
    condition     = keys(output.github_actions_settings["shared-cicd-infrastructure"].environments) == ["production:v2"]
    error_message = "The settings output names the Environment as it is configured in GitHub: raw, not encoded."
  }
}

run "blank_environment_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3"], environment = "  " }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "wildcard_service_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3", "*"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "wildcard_prefix_service_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [] }
        "shared-cicd-infrastructure" = { services = ["s3", "iam*"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# Service-linked roles are account-wide: deploy roles may create them, never
# delete them, so no repository can remove one another relies on.
run "service_linked_roles_are_created_never_deleted" {
  command = plan

  assert {
    condition = (
      contains(flatten([for s in data.aws_iam_policy_document.cicd_deploy_iam_baseline.statement : s.actions if s.effect == "Allow"]), "iam:CreateServiceLinkedRole")
      && !contains(flatten([for s in data.aws_iam_policy_document.cicd_deploy_iam_baseline.statement : s.actions if s.effect == "Allow"]), "iam:DeleteServiceLinkedRole")
    )
    error_message = "Deploy roles may create service-linked roles but never delete them."
  }
}

run "account_without_baseline_repository_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-cicd-infrastructure" = { services = ["s3", "kms"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# 58 characters: <repo>-deploy would be 65, past IAM's 64-character limit,
# which an apply would only discover at the CreateRole call.
run "repository_name_too_long_for_a_role_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"                                            = { manages_account_baseline = true, services = [] }
        "a-repository-name-that-is-exactly-fifty-eight-chars-long-x" = { services = ["s3"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# A consumer may not touch the permission boundaries, but may manage its own
# policies under /services/<repo>/. The deny on boundary-policy writes is
# scoped to policy/boundaries/*: on "*" it would cancel iamManageOwnedPolicies
# (an explicit Deny beats every Allow). Attaching or removing a boundary is
# denied on every role. The baseline repository, which manages the
# boundaries, gets neither deny.
run "consumers_are_denied_the_boundaries_but_keep_their_own_policies" {
  command = plan

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.cicd_deploy_permissions["shared-cicd-infrastructure"].statement : s
      if s.sid == "denyPermissionBoundaryPolicyChanges" && s.effect == "Deny"
      && toset(s.actions) == toset(["iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy"])
      && toset(s.resources) == toset(["arn:aws:iam::123456789012:policy/boundaries/*"])
    ]) == 1
    error_message = "A consumer's deploy role must be denied policy writes on the boundary policies only (policy/boundaries/*)."
  }

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.cicd_deploy_permissions["shared-cicd-infrastructure"].statement : s
      if s.sid == "denyPermissionBoundaryAttachment" && s.effect == "Deny"
      && toset(s.actions) == toset(["iam:PutRolePermissionsBoundary", "iam:DeleteRolePermissionsBoundary"])
      && toset(s.resources) == toset(["*"])
    ]) == 1
    error_message = "A consumer's deploy role must be denied attaching or removing a permission boundary on every role."
  }

  # No deny may cover a policy-write action on "*": that would cancel the
  # repository's own /services/<repo>/ policies.
  assert {
    condition = alltrue(flatten([
      for repo, doc in data.aws_iam_policy_document.cicd_deploy_permissions : [
        for s in doc.statement :
        !(contains(s.resources, "*") && length(setintersection(toset(s.actions), toset(["iam:CreatePolicy", "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion"]))) > 0)
        if s.effect == "Deny" && s.actions != null
      ]
    ]))
    error_message = "No deploy-role deny may cover policy writes on \"*\": it would cancel the repository's own policies under /services/<repo>/."
  }

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.cicd_deploy_permissions["shared-workload"].statement : s
      if contains(["denyPermissionBoundaryPolicyChanges", "denyPermissionBoundaryAttachment"], s.sid)
    ]) == 0
    error_message = "The baseline repository manages the boundaries, so it gets neither deny."
  }
}

# --- GitHub App keys (github-app-keys-access.tf) ---------------------------
#
# The fixture's consumers mark shared-workload manages_github and
# shared-cicd-infrastructure not, so one repository gets the grants and the
# other must not.

run "without_github_app_keys_no_grants_and_every_read_role_denied" {
  command = plan

  # Explicit, not left unset: the fixture above sets the ARNs, as
  # shared-workload's terraform.tfvars does since shared-cicd-infrastructure
  # applied the keys.
  variables {
    github_app_key_arns = null
  }

  assert {
    condition     = length(aws_iam_role_policy.cicd_read_github_app_key) == 0 && length(aws_iam_role_policy.cicd_deploy_github_app_key) == 0 && length(aws_iam_role_policy.cicd_deploy_github_app_key_guard) == 0
    error_message = "Before shared-cicd-infrastructure has the keys (github_app_key_arns null), no role gets a github-app-key or github-app-key-guard policy."
  }

  assert {
    condition = alltrue([
      for repo in ["shared-workload", "shared-cicd-infrastructure"] :
      length([for s in data.aws_iam_policy_document.cicd_read_permissions[repo].statement : s if s.sid == "denySecretRetrieval" && toset(s.resources) == toset(["*"])]) == 1
    ])
    error_message = "Without the keys, every read role keeps the plain deny on GetSecretValue for every secret."
  }
}

# A pull request can assume the read role, so no read role reads a table's
# items or its stream, whether or not dynamodb is among its services. The
# registry lists dynamodb (its token table), the others don't.
run "every_read_role_is_denied_dynamodb_data_reads" {
  command = plan

  assert {
    condition = (
      contains(local.consumers["shared-terraform-registry"].services, "dynamodb")
      && !contains(local.consumers["shared-cicd-infrastructure"].services, "dynamodb")
      && alltrue([
        for repo in keys(local.consumers) :
        length([
          for s in data.aws_iam_policy_document.cicd_read_permissions[repo].statement : s
          if s.sid == "denyTableDataReads" && s.effect == "Deny" && toset(s.resources) == toset(["*"])
          && toset(s.actions) == toset(["dynamodb:BatchGetItem", "dynamodb:GetItem", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:PartiQLSelect", "dynamodb:Query", "dynamodb:Scan"])
        ]) == 1
      ])
    )
    error_message = "Every read role, with dynamodb in its services or not, is denied DynamoDB's item and stream reads on every table."
  }
}

# CLF-145. A pull request can assume the read role, so no read role reads a
# parameter's value or an object's contents outside what is its own: nothing
# by default, plus AWS's public ones. The deny must leave the hop to the
# read-only state role alone: that session is how a plan reads other
# configurations' outputs (terraform_remote_state).
run "every_read_role_is_denied_parameter_and_object_reads_outside_its_own" {
  command = plan

  assert {
    condition = alltrue([
      for repo in keys(local.consumers) :
      length([
        for s in data.aws_iam_policy_document.cicd_read_permissions[repo].statement : s
        if s.sid == "denyParameterAndObjectReadsOutsideOwn" && s.effect == "Deny"
        && toset(s.actions) == toset(["ssm:GetParameter", "ssm:GetParameterHistory", "ssm:GetParameters", "s3:GetObject", "s3:GetObjectTorrent", "s3:GetObjectVersion", "s3:GetObjectVersionTorrent"])
        && toset(s.not_resources) == toset(["arn:aws:ssm:*::parameter/aws/service/*"])
      ]) == 1
      && length([
        for s in data.aws_iam_policy_document.cicd_read_permissions[repo].statement : s
        if s.sid == "denyParameterTreeReadsOutsideOwnSubtrees" && s.effect == "Deny"
        && toset(s.actions) == toset(["ssm:GetParametersByPath"])
        && toset(s.not_resources) == toset(["arn:aws:ssm:*::parameter/aws/service", "arn:aws:ssm:*::parameter/aws/service/*"])
      ]) == 1
    ])
    error_message = "By default every read role is denied every parameter value, object's contents and parameter tree but AWS's public ones."
  }

  # Only content reads are denied: the object metadata reads and the
  # bucket-level GetObjectLockConfiguration stay readable for a plan. No
  # read-role deny names them, by name or by an s3:GetObject* wildcard.
  assert {
    condition = alltrue(flatten([
      for repo in keys(local.consumers) : [
        for s in data.aws_iam_policy_document.cicd_read_permissions[repo].statement : [
          for a in s.actions : !contains(["s3:getobject*", "s3:get*", "s3:*", "*", "s3:getobjectlockconfiguration", "s3:getobjecttagging", "s3:getobjectacl"], lower(a))
        ] if s.effect == "Deny"
      ]
    ]))
    error_message = "No read-role deny may name s3:GetObjectLockConfiguration or the object metadata reads, directly or by a wildcard: a plan refreshes them."
  }

  assert {
    condition = alltrue([
      for repo in keys(local.consumers) : alltrue([
        for s in data.aws_iam_policy_document.cicd_read_permissions[repo].statement :
        !anytrue([for a in s.actions : startswith(a, "sts:")]) if s.effect == "Deny"
      ])
    ]) && length(data.aws_iam_policy_document.cicd_assume_read_state) == 1 && length(aws_iam_role_policy.cicd_read_assume_state_access) == length(local.consumers)
    error_message = "No read-role deny touches sts:, and every read role may still assume the read-only state role, through which terraform_remote_state reads other configurations' outputs."
  }
}

run "declared_parameter_paths_and_buckets_replace_the_default_exception" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], workspaces = ["cicd"], manages_github = true }
        "shared-terraform-registry" = {
          services             = ["s3", "ssm"]
          plan_parameter_paths = ["/shared-terraform-registry/*", "/platform/config"]
          plan_object_buckets  = ["omron-registry-modules"]
        }
      }
    }
  }

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.cicd_read_permissions["shared-terraform-registry"].statement : s
      if s.sid == "denyParameterAndObjectReadsOutsideOwn" && toset(s.not_resources) == toset([
        "arn:aws:ssm:*::parameter/aws/service/*",
        "arn:aws:ssm:*:123456789012:parameter/shared-terraform-registry/*",
        "arn:aws:ssm:*:123456789012:parameter/platform/config",
        "arn:aws:s3:::omron-registry-modules/*",
      ])
    ]) == 1
    error_message = "Each declared path's values and each declared bucket's objects are excepted."
  }

  # GetParametersByPath is authorized against the path and returns everything
  # below it, so only the declared subtree opens it (on its root and below).
  # The exact /platform/config must not: a recursive call on it would return
  # /platform/config/password.
  assert {
    condition = length([
      for s in data.aws_iam_policy_document.cicd_read_permissions["shared-terraform-registry"].statement : s
      if s.sid == "denyParameterTreeReadsOutsideOwnSubtrees" && toset(s.not_resources) == toset([
        "arn:aws:ssm:*::parameter/aws/service",
        "arn:aws:ssm:*::parameter/aws/service/*",
        "arn:aws:ssm:*:123456789012:parameter/shared-terraform-registry",
        "arn:aws:ssm:*:123456789012:parameter/shared-terraform-registry/*",
      ])
    ]) == 1
    error_message = "Only a declared subtree may be listed with GetParametersByPath: an exact path must not open its descendants."
  }
}

run "a_parameter_path_without_a_leading_slash_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"           = { manages_account_baseline = true, services = [] }
        "shared-terraform-registry" = { services = ["ssm"], plan_parameter_paths = ["shared-terraform-registry/*"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "a_parameter_path_with_a_wildcard_inside_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"           = { manages_account_baseline = true, services = [] }
        "shared-terraform-registry" = { services = ["ssm"], plan_parameter_paths = ["/*/config"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "a_bucket_given_as_an_arn_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"           = { manages_account_baseline = true, services = [] }
        "shared-terraform-registry" = { services = ["s3"], plan_object_buckets = ["arn:aws:s3:::omron-registry-modules"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "github_app_keys_go_to_manages_github_repositories_only" {
  command = plan

  variables {
    github_app_key_arns = {
      plan_secret_arn  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-plan-AbCdEf"
      apply_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-apply-GhIjKl"
      kms_key_arn      = "arn:aws:kms:us-west-2:123456789012:key/11111111-1111-4111-8111-111111111111"
    }
  }

  assert {
    condition     = keys(aws_iam_role_policy.cicd_read_github_app_key) == ["shared-workload"] && keys(aws_iam_role_policy.cicd_deploy_github_app_key) == ["shared-workload"]
    error_message = "Only the manages_github repository's roles get a github-app-key policy."
  }

  # The split: the read role's grant is the plan key, the deploy role's the apply key.
  assert {
    condition = (
      toset(flatten([for s in data.aws_iam_policy_document.cicd_github_app_key["plan"].statement : s.resources if s.sid == "readGithubAppKey"])) == toset([var.github_app_key_arns.plan_secret_arn])
      && toset(flatten([for s in data.aws_iam_policy_document.cicd_github_app_key["apply"].statement : s.resources if s.sid == "readGithubAppKey"])) == toset([var.github_app_key_arns.apply_secret_arn])
    )
    error_message = "The plan document grants the plan key only, the apply document the apply key only."
  }

  assert {
    condition = alltrue([
      for app, arn in { plan = var.github_app_key_arns.plan_secret_arn, apply = var.github_app_key_arns.apply_secret_arn } :
      contains(flatten([for s in data.aws_iam_policy_document.cicd_github_app_key[app].statement : [for c in s.condition : c.values if c.variable == "kms:EncryptionContext:SecretARN"]]), arn)
      && contains(flatten([for s in data.aws_iam_policy_document.cicd_github_app_key[app].statement : [for c in s.condition : c.values if c.variable == "kms:ViaService"]]), "secretsmanager.us-west-2.amazonaws.com")
    ])
    error_message = "Each App's readers decrypt only through Secrets Manager in the secret's region, and only under their own App's secret."
  }

  # The deny exception is exactly the plan key, and only for the repository
  # that manages GitHub.
  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.cicd_read_permissions["shared-workload"].statement : s if s.sid == "denySecretRetrieval"]) == 0
      && toset(flatten([for s in data.aws_iam_policy_document.cicd_read_permissions["shared-workload"].statement : s.not_resources if s.sid == "denySecretRetrievalButThePlanGithubAppKey"])) == toset([var.github_app_key_arns.plan_secret_arn])
    )
    error_message = "A manages_github read role is denied every secret but the plan App's key: never the apply key, never another secret."
  }

  assert {
    condition = (
      length([for s in data.aws_iam_policy_document.cicd_read_permissions["shared-cicd-infrastructure"].statement : s if s.sid == "denySecretRetrieval" && toset(s.resources) == toset(["*"])]) == 1
      && length([for s in data.aws_iam_policy_document.cicd_read_permissions["shared-cicd-infrastructure"].statement : s if s.sid == "denySecretRetrievalButThePlanGithubAppKey"]) == 0
    )
    error_message = "A repository that does not manage GitHub keeps the plain deny on every secret."
  }

  assert {
    condition = (
      output.github_actions_settings["shared-workload"].environments["cicd"]["GH_APP_KEY_SECRET_ARN"] == var.github_app_key_arns.apply_secret_arn
      && output.github_actions_settings["shared-workload"].repository_variables["GH_APP_PLAN_KEY_SECRET_ARN"] == var.github_app_key_arns.plan_secret_arn
      && keys(output.github_actions_settings["shared-cicd-infrastructure"].environments["cicd"]) == ["DEPLOY_ROLE_ARN", "TF_STATE_ROLE_ARN"]
    )
    error_message = "The manages_github repository's settings carry the apply key's secret in the Environment and the plan key's at repository level; others carry neither."
  }

  # GitHub rejects a variable whose name starts with GITHUB_ (HTTP 422), so a
  # name the output hands out must be one that can actually be set.
  assert {
    condition = alltrue(flatten([
      for repo, settings in output.github_actions_settings : [
        for name in concat(flatten([for environment, variables in settings.environments : keys(variables)]), keys(settings.repository_variables)) :
        can(regex("^[A-Z_][A-Z0-9_]*$", name)) && !startswith(name, "GITHUB_")
      ]
    ]))
    error_message = "Every variable in github_actions_settings is a name GitHub accepts: upper-case letters, digits and underscores, not starting with a digit or GITHUB_."
  }

  # The identity-side guard, on every deploy role: the resource policy alone
  # can be rewritten by a deploy role holding secretsmanager:*.
  assert {
    condition     = keys(aws_iam_role_policy.cicd_deploy_github_app_key_guard) == keys(aws_iam_role.cicd_deploy)
    error_message = "Every deploy role carries the github-app-key-guard policy, not only the manages_github ones."
  }

  assert {
    condition = (
      toset(flatten([for s in data.aws_iam_policy_document.cicd_deploy_github_app_key_guard["shared-cicd-infrastructure"].statement : s.resources if s.sid == "denyGithubAppKeyRetrieval" && s.effect == "Deny" && toset(s.actions) == toset(["secretsmanager:GetSecretValue"])])) == toset([var.github_app_key_arns.plan_secret_arn, var.github_app_key_arns.apply_secret_arn])
      && toset(flatten([for s in data.aws_iam_policy_document.cicd_deploy_github_app_key_guard["shared-workload"].statement : s.resources if s.sid == "denyGithubAppKeyRetrieval" && s.effect == "Deny" && toset(s.actions) == toset(["secretsmanager:GetSecretValue"])])) == toset([var.github_app_key_arns.plan_secret_arn])
    )
    error_message = "A deploy role is denied reading every App key it is not granted: both for a repository that does not manage GitHub, the plan key for one that does."
  }

  assert {
    condition = alltrue([
      for repo, doc in data.aws_iam_policy_document.cicd_deploy_github_app_key_guard :
      toset(flatten([for s in doc.statement : s.resources if s.sid == "denyGithubAppKeyValueWrites" && s.effect == "Deny" && toset(s.actions) == toset(["secretsmanager:PutSecretValue"])])) == toset([var.github_app_key_arns.plan_secret_arn, var.github_app_key_arns.apply_secret_arn])
    ])
    error_message = "No deploy role may write an App key's value: they are delivered by hand."
  }

  assert {
    condition = alltrue([
      for repo, doc in data.aws_iam_policy_document.cicd_deploy_github_app_key_guard :
      toset(flatten([for s in doc.statement : s.resources if s.sid == "denyGithubAppKeyReplication" && s.effect == "Deny" && toset(s.actions) == toset(["secretsmanager:ReplicateSecretToRegions"])])) == toset([var.github_app_key_arns.plan_secret_arn, var.github_app_key_arns.apply_secret_arn])
    ])
    error_message = "No deploy role may replicate an App key: a replica's regional ARN escapes the exact-ARN read deny."
  }
}

run "a_partial_github_app_key_arn_is_rejected" {
  command = plan

  variables {
    github_app_key_arns = {
      plan_secret_arn  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-plan"
      apply_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-apply-GhIjKl"
      kms_key_arn      = "arn:aws:kms:us-west-2:123456789012:key/11111111-1111-4111-8111-111111111111"
    }
  }

  expect_failures = [var.github_app_key_arns]
}

run "the_same_key_for_plan_and_apply_is_rejected" {
  command = plan

  variables {
    github_app_key_arns = {
      plan_secret_arn  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-apply-GhIjKl"
      apply_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-apply-GhIjKl"
      kms_key_arn      = "arn:aws:kms:us-west-2:123456789012:key/11111111-1111-4111-8111-111111111111"
    }
  }

  expect_failures = [var.github_app_key_arns]
}

run "a_kms_alias_is_rejected_as_the_key" {
  command = plan

  variables {
    github_app_key_arns = {
      plan_secret_arn  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-plan-AbCdEf"
      apply_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-apply-GhIjKl"
      kms_key_arn      = "arn:aws:kms:us-west-2:123456789012:alias/omron-shared-cicd-github-app-keys"
    }
  }

  expect_failures = [var.github_app_key_arns]
}

# Wildcards in an ARN input would be copied into an identity policy as a
# pattern: the role hops onto every matching role, the App-key grants and the
# read role's NotResource deny exception onto every matching secret.
run "a_wildcard_state_role_is_rejected" {
  command = plan

  variables {
    state_role_arn = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/*"
  }

  expect_failures = [var.state_role_arn]
}

run "a_wildcard_read_state_role_is_rejected" {
  command = plan

  variables {
    read_state_role_arn = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state*"
  }

  expect_failures = [var.read_state_role_arn]
}

# An ARN without a role name passes a character check alone, and would give
# the roles a state hop that names no role.
run "a_state_role_without_a_name_is_rejected" {
  command = plan

  variables {
    state_role_arn = "arn:aws:iam::123456789012:role//"
  }

  expect_failures = [var.state_role_arn]
}

run "a_read_state_role_without_a_name_is_rejected" {
  command = plan

  variables {
    read_state_role_arn = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/"
  }

  expect_failures = [var.read_state_role_arn]
}

# IAM role names are at most 64 characters.
run "a_state_role_name_over_64_characters_is_rejected" {
  command = plan

  variables {
    state_role_arn = "arn:aws:iam::123456789012:role/services/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  }

  expect_failures = [var.state_role_arn]
}

run "a_wildcard_github_app_key_secret_is_rejected" {
  command = plan

  variables {
    github_app_key_arns = {
      plan_secret_arn  = "arn:aws:secretsmanager:us-west-2:123456789012:secret:*-AbCdEf"
      apply_secret_arn = "arn:aws:secretsmanager:us-west-2:123456789012:secret:omron-shared-cicd-github-app-terraform-apply-GhIjKl"
      kms_key_arn      = "arn:aws:kms:us-west-2:123456789012:key/11111111-1111-4111-8111-111111111111"
    }
  }

  expect_failures = [var.github_app_key_arns]
}

# CLF-93, the variables part: every variable github_actions_settings lists is
# a resource here, with the output's own value, so the two cannot disagree.
# An apply run: the mocked role ARNs that become the variables' values are
# only known once applied, and so is the comparison.
run "github_variables_are_managed_from_the_settings" {
  command = apply

  # An apply would run the workspace-creation script for real (see the
  # file-level variables): without the provisioner nothing is created, and
  # the check that says so is expected.
  variables {
    workspace_provisioner_role_arn = ""
  }

  expect_failures = [check.declared_workspaces_can_be_created]

  assert {
    condition = sort(keys(github_actions_variable.consumer)) == tolist([
      "shared-cicd-infrastructure:CICD_READ_ROLE_ARN",
      "shared-cicd-infrastructure:TF_STATE_BUCKET",
      "shared-cicd-infrastructure:TF_STATE_REGION",
      "shared-cicd-infrastructure:TF_STATE_ROLE_ARN",
      "shared-terraform-registry:CICD_READ_ROLE_ARN",
      "shared-terraform-registry:TF_STATE_BUCKET",
      "shared-terraform-registry:TF_STATE_REGION",
      "shared-terraform-registry:TF_STATE_ROLE_ARN",
      "shared-workload:CICD_READ_ROLE_ARN",
      "shared-workload:GH_APP_PLAN_KEY_SECRET_ARN",
      "shared-workload:TF_STATE_BUCKET",
      "shared-workload:TF_STATE_REGION",
      "shared-workload:TF_STATE_ROLE_ARN",
    ])
    error_message = "The cicd workspace manages every repository-level variable of every consumer, keyed <repo>:<name>."
  }

  assert {
    condition = sort(keys(github_actions_environment_variable.consumer)) == tolist([
      "shared-cicd-infrastructure:cicd:DEPLOY_ROLE_ARN",
      "shared-cicd-infrastructure:cicd:TF_STATE_ROLE_ARN",
      "shared-terraform-registry:production:DEPLOY_ROLE_ARN",
      "shared-terraform-registry:production:TF_STATE_ROLE_ARN",
      "shared-terraform-registry:test:DEPLOY_ROLE_ARN",
      "shared-terraform-registry:test:TF_STATE_ROLE_ARN",
      "shared-workload:cicd:DEPLOY_ROLE_ARN",
      "shared-workload:cicd:GH_APP_KEY_SECRET_ARN",
      "shared-workload:cicd:TF_STATE_ROLE_ARN",
    ])
    error_message = "Every Environment variable of every consumer is managed, keyed <repo>:<environment>:<name>: one set per stage for the registry."
  }

  assert {
    condition = alltrue(concat(
      [for v in github_actions_variable.consumer : v.value == output.github_actions_settings[v.repository].repository_variables[v.variable_name]],
      [for v in github_actions_environment_variable.consumer : v.value == output.github_actions_settings[v.repository].environments[v.environment][v.variable_name]],
    ))
    error_message = "Each managed variable carries the value, and the Environment, that github_actions_settings lists for it."
  }
}

# The deployment-policy check reads each Environment's policies once the
# managed main policy exists (depends_on): live, it does, so every plan runs
# the check. Here the policies exist only after the apply run above, so these
# runs follow it; an apply run leaves its state to the runs after it, which is
# why it and these are last in the file.
# A policy added in GitHub, beside Terraform's main, fails: Terraform
# would not see it otherwise.
# An Environment name may hold spaces; urlencode writes them as "+", which a
# URL path would read literally, so the endpoint carries %20 instead.
run "an_environment_name_with_a_space_is_encoded_in_the_endpoint" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"], environment = "release candidate" }
      }
    }
  }

  assert {
    condition     = data.github_rest_api.deployment_policies["shared-cicd-infrastructure"].endpoint == "repos/OmronHealthCare-OHI/shared-cicd-infrastructure/environments/release%20candidate/deployment-branch-policies"
    error_message = "A space in the Environment name must reach GitHub as %20, not +."
  }
}

run "an_extra_deployment_policy_fails_the_plan" {
  command = plan

  override_data {
    target = data.github_rest_api.deployment_policies["shared-workload"]
    values = {
      code = 200
      body = "{\"total_count\":2,\"branch_policies\":[{\"id\":61640649,\"name\":\"main\",\"type\":\"branch\"},{\"id\":1,\"name\":\"release/*\",\"type\":\"branch\"}]}"
    }
  }

  expect_failures = [data.github_rest_api.deployment_policies["shared-workload"]]
}

run "a_main_tag_policy_instead_of_the_branch_fails_the_plan" {
  command = plan

  override_data {
    target = data.github_rest_api.deployment_policies["shared-cicd-infrastructure"]
    values = {
      code = 200
      body = "{\"total_count\":1,\"branch_policies\":[{\"id\":2,\"name\":\"main\",\"type\":\"tag\"}]}"
    }
  }

  expect_failures = [data.github_rest_api.deployment_policies["shared-cicd-infrastructure"]]
}

run "an_environment_github_does_not_find_fails_the_plan" {
  command = plan

  override_data {
    target = data.github_rest_api.deployment_policies["shared-workload"]
    values = {
      code = 404
      body = "{\"message\":\"Not Found\"}"
    }
  }

  expect_failures = [data.github_rest_api.deployment_policies["shared-workload"]]
}

# A repository with environments: one deploy role, Environment and set of
# Environment variables per stage, each role trusting only its own
# Environment. The read role stays one per repository.
run "a_repository_with_environments_gets_a_deploy_role_per_stage" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"] }
        "stage-fixture" = {
          services     = ["s3"]
          environments = { test = { requires_approval = false }, production = {} }
        }
      }
    }
  }

  override_data {
    target = data.github_rest_api.oidc_subject["stage-fixture"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/stage-fixture@1\"}"
    }
  }

  assert {
    condition = (
      aws_iam_role.cicd_deploy["stage-fixture:test"].name == "stage-fixture-test-deploy"
      && aws_iam_role.cicd_deploy["stage-fixture:production"].name == "stage-fixture-production-deploy"
      && !contains(keys(aws_iam_role.cicd_deploy), "stage-fixture")
      && aws_iam_role.cicd_read["stage-fixture"].name == "stage-fixture-read"
    )
    error_message = "Each stage gets <repo>-<environment>-deploy, keyed <repo>:<environment>, and no <repo>-deploy; the read role stays <repo>-read."
  }

  assert {
    condition = alltrue([
      for stage in ["test", "production"] :
      one(flatten([
        for c in data.aws_iam_policy_document.cicd_deploy_assume_role["stage-fixture:${stage}"].statement[0].condition :
        tolist(c.values) if c.variable == "token.actions.githubusercontent.com:sub"
      ])) == "repo:OmronHealthCare-OHI@20930349/stage-fixture@1:environment:${stage}"
    ])
    error_message = "Each stage's deploy role trusts exactly its own Environment's subject."
  }

  assert {
    condition = alltrue([
      for stage in ["test", "production"] :
      aws_iam_role.cicd_deploy["stage-fixture:${stage}"].tags["ohi:repository"] == "stage-fixture"
      && aws_iam_role_policy.cicd_deploy_assume_state_access["stage-fixture:${stage}"].name == "assume-state"
      && aws_iam_role_policy.cicd_deploy_permissions["stage-fixture:${stage}"].name == "stage-fixture-${stage}-deploy-permissions"
    ])
    error_message = "Every stage's role speaks for the repository (ohi:repository), reaches its state, and has its own permissions policy."
  }

  assert {
    condition = alltrue([
      for stage in ["test", "production"] : (
        one([for s in data.aws_iam_policy_document.cicd_deploy_permissions["stage-fixture:${stage}"].statement : s.actions if s.sid == "serviceWrite"]) == toset(["s3:*"])
        && one([for s in data.aws_iam_policy_document.cicd_deploy_permissions["stage-fixture:${stage}"].statement : s.resources if s.sid == "iamCreateOwnedRole"]) == toset(["arn:aws:iam::123456789012:role/services/stage-fixture/*"])
      )
    ])
    error_message = "The stages share the repository's services and its IAM path, /services/<repo>/."
  }

  assert {
    condition = (
      length(github_repository_environment.consumer["stage-fixture:test"].reviewers) == 0
      && !github_repository_environment.consumer["stage-fixture:test"].prevent_self_review
      && toset(github_repository_environment.consumer["stage-fixture:production"].reviewers[0].teams) == toset([tonumber(data.github_team.reviewers["cloud-foundations-in-connect-one-app"].id)])
      && github_repository_environment.consumer["stage-fixture:production"].prevent_self_review
      && github_repository_environment_deployment_policy.main["stage-fixture:test"].branch_pattern == "main"
      && github_repository_environment_deployment_policy.main["stage-fixture:production"].branch_pattern == "main"
    )
    error_message = "A stage with requires_approval = false deploys from main without approval; the others keep the reviewer team and no self-review; main is the only branch for both."
  }

  assert {
    condition = (
      sort(keys(output.github_actions_settings["stage-fixture"].environments)) == tolist(["production", "test"])
      && alltrue([for environment, variables in output.github_actions_settings["stage-fixture"].environments : sort(keys(variables)) == tolist(["DEPLOY_ROLE_ARN", "TF_STATE_ROLE_ARN"])])
      && sort([for key, variable in github_actions_environment_variable.consumer : key if variable.repository == "stage-fixture"]) == tolist([
        "stage-fixture:production:DEPLOY_ROLE_ARN",
        "stage-fixture:production:TF_STATE_ROLE_ARN",
        "stage-fixture:test:DEPLOY_ROLE_ARN",
        "stage-fixture:test:TF_STATE_ROLE_ARN",
      ])
    )
    error_message = "Each stage's Environment gets its own DEPLOY_ROLE_ARN and TF_STATE_ROLE_ARN, keyed <repo>:<environment>:<name>."
  }
}

run "environment_and_environments_together_are_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], manages_github = true }
        "stage-fixture"   = { services = ["s3"], environment = "cicd", environments = { test = {} } }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "an_empty_environments_map_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], manages_github = true }
        "stage-fixture"   = { services = ["s3"], environments = {} }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "environments_on_the_baseline_repository_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], environments = { test = {}, production = {} } }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "environments_on_a_manages_github_repository_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [] }
        "stage-fixture"   = { services = ["s3"], manages_github = true, environments = { test = {} } }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "an_environments_key_that_cannot_be_a_role_name_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], manages_github = true }
        "stage-fixture"   = { services = ["s3"], environments = { "release candidate" = {} } }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "a_stage_role_name_over_64_characters_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], manages_github = true }
        # 50 + 1 + 7 + 7 = 65 characters: stage-fixture-…-staging-deploy.
        "stage-fixture-with-a-name-long-enough-to-overflow1" = { services = ["s3"], environments = { staging = {} } }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "two_environments_differing_only_in_case_are_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], manages_github = true }
        "stage-fixture"   = { services = ["s3"], environments = { test = {}, Test = {} } }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# CLF-96: declared workspaces are created through the workspace provisioner,
# once per <repo>:<workspace>, as env:/<workspace>/<repo>; only the baseline's
# deploy role may assume the provisioner.
run "declared_workspaces_are_created_through_the_provisioner" {
  command = plan

  variables {
    workspace_provisioner_role_arn = "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state-workspace-provisioner"
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"], workspaces = ["test", "production"] }
      }
    }
  }

  assert {
    condition = (
      sort(keys(terraform_data.workspace_state)) == tolist(["shared-cicd-infrastructure:production", "shared-cicd-infrastructure:test"])
      && terraform_data.workspace_state["shared-cicd-infrastructure:test"].input == "env:/test/shared-cicd-infrastructure"
      && terraform_data.workspace_state["shared-cicd-infrastructure:production"].input == "env:/production/shared-cicd-infrastructure"
    )
    error_message = "Each declared workspace is one creation, keyed <repo>:<workspace>, of the state key env:/<workspace>/<repo>."
  }

  assert {
    condition = (
      keys(aws_iam_role_policy.cicd_deploy_assume_workspace_provisioner) == ["shared-workload"]
      && one(data.aws_iam_policy_document.cicd_assume_workspace_provisioner[0].statement).resources == toset([var.workspace_provisioner_role_arn])
      && one(data.aws_iam_policy_document.cicd_assume_workspace_provisioner[0].statement).actions == toset(["sts:AssumeRole", "sts:TagSession"])
    )
    error_message = "Only the baseline repository's deploy role may assume the provisioner, and only that role (AssumeRole with the session tag)."
  }
}

run "declared_workspaces_wait_for_the_provisioner" {
  command = plan

  variables {
    workspace_provisioner_role_arn = ""
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"], workspaces = ["test"] }
      }
    }
  }

  assert {
    condition     = length(terraform_data.workspace_state) == 0 && length(aws_iam_role_policy.cicd_deploy_assume_workspace_provisioner) == 0
    error_message = "Without workspace_provisioner_role_arn nothing is created and no role gets the grant."
  }

  expect_failures = [check.declared_workspaces_can_be_created]
}

run "the_default_workspace_cannot_be_declared" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3"], workspaces = ["default"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "a_workspace_name_with_a_slash_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3"], workspaces = ["test/eu"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

run "a_workspace_listed_twice_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3"], workspaces = ["test", "test"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# A staged consumer's <repo>-<environment>-deploy can equal another
# consumer's <repo>-deploy: different Terraform keys, one IAM role name.
run "a_stage_role_equal_to_another_consumers_role_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"    = { manages_account_baseline = true, services = [], manages_github = true }
        "stage-fixture"      = { services = ["s3"], environments = { test = {} } }
        "stage-fixture-test" = { services = ["s3"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# IAM role names ignore case, so a difference in case is still a collision.
run "a_role_name_collision_differing_only_in_case_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"    = { manages_account_baseline = true, services = [], manages_github = true }
        "stage-fixture"      = { services = ["s3"], environments = { Test = {} } }
        "stage-fixture-test" = { services = ["s3"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# CLF-120: shared-workload declares its own cicd workspace, the output lists
# every repository's declared workspaces, and each declared one is a creation
# of env:/<workspace>/<repo> that runs the real script by default.
run "the_declared_workspaces_are_published_and_planned" {
  command = plan

  assert {
    condition = (
      output.workspaces["shared-workload"] == tolist(["cicd"])
      && output.workspaces["shared-terraform-registry"] == tolist(["test", "production"])
      && length(output.workspaces["shared-cicd-infrastructure"]) == 0
    )
    error_message = "The workspaces output lists each repository's declared workspaces: cicd for shared-workload, the registry's two stages, none for shared-cicd-infrastructure."
  }

  assert {
    condition = (
      terraform_data.workspace_state["shared-workload:cicd"].input == "env:/cicd/shared-workload"
      && terraform_data.workspace_state["shared-terraform-registry:test"].input == "env:/test/shared-terraform-registry"
      && terraform_data.workspace_state["shared-terraform-registry:production"].input == "env:/production/shared-terraform-registry"
    )
    error_message = "Each declared workspace is planned as one creation of its state key; shared-workload's own cicd included (a no-op 412 against the live state)."
  }

  assert {
    condition     = alltrue([for state in terraform_data.workspace_state : state.triggers_replace == true])
    error_message = "By default every creation runs the real script (create_workspace_states = true)."
  }
}

# Removing a declared workspace drops only its record. Its state object is
# never a Terraform-managed resource here, so nothing plans its deletion; the
# record has no destroy-time step (also checked statically by
# tests/create-workspace-state.test.sh). Apply runs, so the switch is off: a
# provisioner runs even under an override and would call the real AWS CLI.
#
# Not proven here: that the remaining record is the same instance afterwards.
# A run reads only outputs of an earlier run, and with the switch off a
# re-creation runs nothing. Nothing depends on it: a replaced record re-runs
# a create-only put, which returns 412 against the existing state.
run "a_declared_workspace_is_recorded" {
  command = apply

  variables {
    create_workspace_states = false
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"], workspaces = ["test", "production"] }
      }
    }
  }

  assert {
    condition     = sort(keys(terraform_data.workspace_state)) == tolist(["shared-cicd-infrastructure:production", "shared-cicd-infrastructure:test"])
    error_message = "Both declared workspaces are recorded."
  }
}

run "removing_a_declared_workspace_only_drops_its_record" {
  command = apply

  variables {
    create_workspace_states = false
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"], workspaces = ["test"] }
      }
    }
  }

  assert {
    condition = (
      keys(terraform_data.workspace_state) == ["shared-cicd-infrastructure:test"]
      && terraform_data.workspace_state["shared-cicd-infrastructure:test"].input == "env:/test/shared-cicd-infrastructure"
      && output.workspaces["shared-cicd-infrastructure"] == tolist(["test"])
    )
    error_message = "Removing production from the list removes only its record; the remaining workspace is still recorded, with its own state key."
  }
}

# A consumer can name its own reviewer team: its Environments require that
# team, and that team gets the access; every other consumer keeps the default.
run "a_consumer_with_its_own_reviewer_team" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3", "kms", "secretsmanager"], reviewer_team = "platform-reviewers" }
      }
    }
  }

  override_data {
    target = data.github_team.reviewers["platform-reviewers"]
    values = {
      id   = "999"
      slug = "platform-reviewers"
    }
  }

  assert {
    condition     = sort(keys(data.github_team.reviewers)) == tolist(["cloud-foundations-in-connect-one-app", "platform-reviewers"])
    error_message = "Each team in use is looked up once, the default included."
  }

  assert {
    condition = (
      toset(github_repository_environment.consumer["shared-cicd-infrastructure"].reviewers[0].teams) == toset([999])
      && toset(github_repository_environment.consumer["shared-workload"].reviewers[0].teams) == toset([18466465])
    )
    error_message = "A consumer's Environments require its own reviewer team; the others keep the default."
  }

  assert {
    condition = (
      sort(keys(github_team_repository.reviewers)) == tolist(["shared-cicd-infrastructure/platform-reviewers", "shared-workload/cloud-foundations-in-connect-one-app"])
      && github_team_repository.reviewers["shared-cicd-infrastructure/platform-reviewers"].team_id == "999"
    )
    error_message = "Each repository grants access to its own reviewer team, not the default's."
  }
}

run "a_reviewer_team_display_name_on_a_consumer_is_rejected" {
  command = plan

  variables {
    github_oidc_consumers = {
      cicd = {
        "shared-workload"            = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-cicd-infrastructure" = { services = ["s3"], reviewer_team = "Platform Reviewers" }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}

# --- The permission-boundary classes (permission-boundaries.tf) --------------
#
# The fixture's consumers use ten services between them: apigateway, dynamodb,
# events, kms, lambda, logs, s3, secretsmanager, ssm and states. The classes
# below cover exactly those. The rendered policies themselves are the vendored
# module's, tested in its own directory; here the classes are counted, keyed
# and checked against the consumers.

run "without_classes_no_boundary_is_rendered" {
  command = plan

  assert {
    condition     = length(output.permission_boundary_arns) == 0
    error_message = "With no permission_boundaries (the default), no boundary policy is rendered."
  }
}

# The classes cover everything the roles' own policies grant, services and the
# rest alike (IAM, the state hop, the App key): the shape of
# shared-permission-boundaries.auto.tfvars.
run "each_class_renders_one_boundary" {
  command = plan

  variables {
    permission_boundaries = {
      deploy = {
        permit_policy_mutation = true
        allowed_actions = [
          "apigateway:*", "dynamodb:*", "events:*", "kms:*", "lambda:*", "logs:*", "s3:*", "secretsmanager:*", "ssm:*", "states:*",
          "iam:Get*", "iam:List*", "iam:GenerateServiceLastAccessedDetails", "iam:GenerateCredentialReport",
          "iam:SimulateCustomPolicy", "iam:SimulatePrincipalPolicy",
          "sts:AssumeRole", "sts:TagSession",
          "iam:CreateServiceLinkedRole", "iam:CreateRole", "iam:DeleteRole", "iam:UpdateRole", "iam:UpdateRoleDescription",
          "iam:UpdateAssumeRolePolicy", "iam:AttachRolePolicy", "iam:DetachRolePolicy", "iam:PutRolePolicy",
          "iam:DeleteRolePolicy", "iam:TagRole", "iam:UntagRole", "iam:PassRole",
          "iam:CreatePolicy", "iam:DeletePolicy", "iam:CreatePolicyVersion", "iam:DeletePolicyVersion",
          "iam:SetDefaultPolicyVersion", "iam:TagPolicy", "iam:UntagPolicy",
          "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:AddRoleToInstanceProfile",
          "iam:RemoveRoleFromInstanceProfile", "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
        ]
      }
      read = {
        allowed_actions = [
          "apigateway:Get*", "apigateway:List*", "apigateway:Describe*",
          "dynamodb:Get*", "dynamodb:List*", "dynamodb:Describe*",
          "events:Get*", "events:List*", "events:Describe*",
          "kms:Get*", "kms:List*", "kms:Describe*",
          "lambda:Get*", "lambda:List*", "lambda:Describe*",
          "logs:Get*", "logs:List*", "logs:Describe*",
          "s3:Get*", "s3:List*", "s3:Describe*",
          "secretsmanager:Get*", "secretsmanager:List*", "secretsmanager:Describe*",
          "ssm:Get*", "ssm:List*", "ssm:Describe*",
          "states:Get*", "states:List*", "states:Describe*",
          "kms:Decrypt",
          "iam:Get*", "iam:List*", "iam:GenerateServiceLastAccessedDetails", "iam:GenerateCredentialReport",
          "iam:SimulateCustomPolicy", "iam:SimulatePrincipalPolicy",
          "sts:AssumeRole", "sts:TagSession",
        ]
      }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  assert {
    condition     = sort(keys(output.permission_boundary_arns)) == tolist(["deploy", "read", "service", "users"])
    error_message = "Every class renders one boundary policy, keyed by class name."
  }
}

# Beyond the services: a class that leaves out what a role's own policy grants
# is an AccessDenied once attached, so the plan stops. The state hop here.
run "a_class_without_the_state_hop_is_rejected" {
  command = plan

  variables {
    permission_boundaries = {
      deploy  = { allow_all = true, denied_actions = ["sts:AssumeRole"] }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"] }
    }
  }

  expect_failures = [terraform_data.permission_boundary_coverage]
}

# A deny that covers only part of what a role is granted narrows the class
# without removing the grant: s3:DeleteBucket out of s3:* is no gap.
run "a_partial_deny_is_not_a_gap" {
  command = plan

  variables {
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true, denied_actions = ["s3:DeleteBucket"] }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"] }
    }
  }

  assert {
    condition     = length(terraform_data.permission_boundary_coverage) == 1
    error_message = "With every class covering the roles, the coverage check is planned and passes."
  }
}

# The deploy roles write policy versions under /services/<repo>/, which every
# class denies unless permit_policy_mutation is set.
run "a_deploy_class_without_policy_mutation_is_rejected" {
  command = plan

  variables {
    permission_boundaries = {
      deploy  = { allow_all = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"] }
    }
  }

  expect_failures = [terraform_data.permission_boundary_coverage]
}

run "classes_without_one_the_roles_use_are_rejected" {
  command = plan

  variables {
    permission_boundaries = {
      deploy = { allowed_actions = ["s3:*"] }
      users  = { allow_all = true }
    }
  }

  expect_failures = [var.permission_boundaries]
}

# A consumer's service the deploy class doesn't allow: the next apply of that
# consumer would be refused by its boundary, so the plan stops here instead.
run "a_service_the_deploy_class_lacks_is_rejected" {
  command = plan

  variables {
    permission_boundaries = {
      deploy = {
        allowed_actions = ["apigateway:*", "dynamodb:*", "events:*", "kms:*", "lambda:*", "logs:*", "s3:*", "secretsmanager:*", "ssm:*"]
      }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"] }
    }
  }

  expect_failures = [var.permission_boundaries]
}

# Read needs all three verbs per service: a read role's plan refreshes with
# Describe* as well as Get* and List*.
run "a_service_the_read_class_reads_only_partly_is_rejected" {
  command = plan

  variables {
    permission_boundaries = {
      deploy = { allow_all = true }
      read = {
        allowed_actions = [
          "apigateway:Get*", "apigateway:List*", "apigateway:Describe*",
          "dynamodb:Get*", "dynamodb:List*", "dynamodb:Describe*",
          "events:Get*", "events:List*", "events:Describe*",
          "kms:Get*", "kms:List*", "kms:Describe*",
          "lambda:Get*", "lambda:List*", "lambda:Describe*",
          "logs:Get*", "logs:List*", "logs:Describe*",
          "s3:Get*", "s3:List*",
          "secretsmanager:Get*", "secretsmanager:List*", "secretsmanager:Describe*",
          "ssm:Get*", "ssm:List*", "ssm:Describe*",
          "states:Get*", "states:List*", "states:Describe*",
        ]
      }
      service = { allowed_actions = ["s3:GetObject"] }
    }
  }

  expect_failures = [var.permission_boundaries]
}

# --- Who carries which boundary, and what creating a role requires ------------
#
# The boundary policies get their real ARNs here, so an assertion tells the
# classes apart (a mocked ARN is random text), already at plan
# (override_during, Terraform 1.11; the floor is 1.12).

override_resource {
  target          = module.permission_boundary["deploy"].aws_iam_policy.this
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy" }
}

override_resource {
  target          = module.permission_boundary["read"].aws_iam_policy.this
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-read" }
}

override_resource {
  target          = module.permission_boundary["service"].aws_iam_policy.this
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-service" }
}

override_resource {
  target          = module.permission_boundary["users"].aws_iam_policy.this
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-users" }
}

override_resource {
  target          = aws_iam_policy.baseline_boundary
  override_during = plan
  values          = { arn = "arn:aws:iam::123456789012:policy/boundaries/shared-workload-baseline" }
}

run "without_classes_no_role_carries_a_boundary" {
  command = plan

  assert {
    condition = alltrue(concat(
      [for role in aws_iam_role.cicd_deploy : role.permissions_boundary == null],
      [for role in aws_iam_role.cicd_read : role.permissions_boundary == null],
    )) && length(aws_iam_policy.baseline_boundary) == 0
    error_message = "With no classes given, no role carries a boundary and no baseline boundary is rendered."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.cicd_deploy_permissions["shared-cicd-infrastructure"].statement :
      length(s.condition) == 0 if s.sid == "iamCreateOwnedRole"
    ])
    error_message = "With no classes given, iam:CreateRole carries no boundary condition."
  }
}

run "with_classes_every_role_carries_its_boundary" {
  command = plan

  variables {
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  assert {
    condition = (
      aws_iam_role.cicd_deploy["shared-cicd-infrastructure"].permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy"
      && aws_iam_role.cicd_deploy["shared-terraform-registry:test"].permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy"
      && aws_iam_role.cicd_deploy["shared-terraform-registry:production"].permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy"
    )
    error_message = "Every consumer's deploy role, one per stage included, carries the deploy class."
  }

  assert {
    condition     = aws_iam_role.cicd_deploy["shared-workload"].permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/shared-workload-baseline"
    error_message = "The baseline repository's deploy role carries its own boundary, not the deploy class."
  }

  assert {
    condition     = alltrue([for role in aws_iam_role.cicd_read : role.permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/omron-shared-read"])
    error_message = "Every read role, the baseline's included, carries the read class."
  }

  assert {
    condition     = aws_iam_policy.baseline_boundary[0].name == "shared-workload-baseline" && aws_iam_policy.baseline_boundary[0].path == "/boundaries/"
    error_message = "The baseline's own boundary is /boundaries/<repo>-baseline."
  }

  # Creating a role under /services/<repo>/ requires the service class.
  assert {
    condition = alltrue(flatten([
      for key, doc in data.aws_iam_policy_document.cicd_deploy_permissions : [
        for s in doc.statement : [
          for c in s.condition :
          c.test == "StringEquals" && c.variable == "iam:PermissionsBoundary" && c.values == tolist(["arn:aws:iam::123456789012:policy/boundaries/omron-shared-service"])
        ] if s.sid == "iamCreateOwnedRole"
      ]
      ])) && alltrue([
      for key, doc in data.aws_iam_policy_document.cicd_deploy_permissions :
      length([for s in doc.statement : s if s.sid == "iamCreateOwnedRole" && length(s.condition) == 1]) == 1
    ])
    error_message = "Every deploy role may create a role under /services/<repo>/ only with the service class as its boundary."
  }

  # The baseline creates and bounds pipeline roles with deploy or read only.
  assert {
    condition = alltrue(flatten([
      for s in data.aws_iam_policy_document.cicd_deploy_permissions["shared-workload"].statement : [
        for c in s.condition :
        c.variable == "iam:PermissionsBoundary" && toset(c.values) == toset(["arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy", "arn:aws:iam::123456789012:policy/boundaries/omron-shared-read"])
      ] if contains(["iamCreateCicdRole", "iamSetPermissionBoundaryOnCicdRoles"], s.sid)
      ])) && length([
      for s in data.aws_iam_policy_document.cicd_deploy_permissions["shared-workload"].statement : s
      if contains(["iamCreateCicdRole", "iamSetPermissionBoundaryOnCicdRoles"], s.sid) && length(s.condition) == 1
    ]) == 2
    error_message = "The baseline's deploy role may create, and attach a boundary to, a pipeline role only with the deploy or read class."
  }

  # Its boundary says the same, because the pipeline rewrites its own policy:
  # one Allow for CreateRole and PutRolePermissionsBoundary, conditioned on
  # deploy or read, and no other Allow that grants either.
  assert {
    condition = length([
      for s in data.aws_iam_policy_document.baseline_boundary[0].statement : s
      if s.sid == "createAndBoundCicdRoles" && s.effect == "Allow"
      && toset(s.actions) == toset(["iam:CreateRole", "iam:PutRolePermissionsBoundary"])
      && toset(s.resources) == toset(["arn:aws:iam::123456789012:role/cicd/gha/*"])
      && length(s.condition) == 1
      && alltrue([
        for c in s.condition :
        c.test == "StringEquals" && c.variable == "iam:PermissionsBoundary" && toset(c.values) == toset(["arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy", "arn:aws:iam::123456789012:policy/boundaries/omron-shared-read"])
      ])
      ]) == 1 && alltrue([
      for s in data.aws_iam_policy_document.baseline_boundary[0].statement :
      !contains(s.actions, "iam:CreateRole") && !contains(s.actions, "iam:PutRolePermissionsBoundary")
      if s.effect == "Allow" && s.actions != null && s.sid != "createAndBoundCicdRoles"
    ])
    error_message = "The baseline boundary allows creating a pipeline role, or attaching its boundary, only with the deploy or read class, in createAndBoundCicdRoles alone."
  }

  # The baseline's own boundary: its job, and the four narrow denies.
  assert {
    condition = toset([for s in data.aws_iam_policy_document.baseline_boundary[0].statement : s.sid]) == toset([
      "iamRead",
      "iamCreateServiceLinkedRoles",
      "manageGithubOidcProvider",
      "manageCicdRoles",
      "createAndBoundCicdRoles",
      "manageBoundaryPolicies",
      "readApplyGithubAppKey",
      "decryptApplyGithubAppKey",
      "assumeStateAndProvisionerRoles",
      "denyWritingThisBoundary",
      "denyChangingOwnBoundary",
      "denyRemovingPipelineBoundaries",
      "denyAssumingAnyRoleButStateAndProvisioner",
    ])
    error_message = "The baseline boundary allows its job (no service writes: the fixture's baseline lists none) and carries the four narrow denies."
  }

  # Removing a boundary from a pipeline role is no pipeline role's to do: the
  # baseline may replace one (deploy or read), never take it off. Its identity
  # policy doesn't grant it, its boundary doesn't allow it, and the boundary
  # denies it explicitly, because the pipeline rewrites its own inline policy.
  assert {
    condition = alltrue(flatten([
      for key, doc in data.aws_iam_policy_document.cicd_deploy_permissions : [
        for s in doc.statement : !contains(s.actions, "iam:DeleteRolePermissionsBoundary")
        if s.effect == "Allow" && s.actions != null
      ]
      ])) && alltrue([
      for s in data.aws_iam_policy_document.baseline_boundary[0].statement :
      !contains(s.actions, "iam:DeleteRolePermissionsBoundary")
      if s.effect == "Allow" && s.actions != null
      ]) && length([
      for s in data.aws_iam_policy_document.baseline_boundary[0].statement : s
      if s.sid == "denyRemovingPipelineBoundaries" && s.effect == "Deny"
      && toset(s.actions) == toset(["iam:DeleteRolePermissionsBoundary"])
      && toset(s.resources) == toset(["arn:aws:iam::123456789012:role/cicd/gha/*"])
    ]) == 1
    error_message = "No pipeline role may be granted removing a permission boundary, and the baseline boundary must deny it on every role at /cicd/gha/."
  }

  assert {
    condition = alltrue([
      for s in data.aws_iam_policy_document.baseline_boundary[0].statement : (
        s.sid == "denyWritingThisBoundary" ? toset(s.resources) == toset(["arn:aws:iam::123456789012:policy/boundaries/shared-workload-baseline"])
        : s.sid == "denyChangingOwnBoundary" ? toset(s.resources) == toset(["arn:aws:iam::123456789012:role/cicd/gha/shared-workload-deploy"])
        : s.sid == "denyAssumingAnyRoleButStateAndProvisioner" ? toset(s.not_resources) == toset([
          "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state",
          "arn:aws:iam::123456789012:role/services/shared-cicd-infrastructure/omron-shared-cicd-tf-state-workspace-provisioner",
        ])
        : s.sid == "readApplyGithubAppKey" ? toset(s.resources) == toset(["arn:aws:secretsmanager:us-west-2:123456789012:secret:fixture-github-app-terraform-apply-Ap7lCd"])
        : true
      )
    ])
    error_message = "The denies name this boundary, the baseline's own deploy role and every role but the state role and the provisioner; the App key read is the apply key's only."
  }
}

# Without the state roles or the provisioner known, the baseline may assume
# nothing at all.
run "without_assumable_roles_the_baseline_assumes_none" {
  command = plan

  variables {
    state_role_arn                 = ""
    workspace_provisioner_role_arn = ""
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"] }
    }
  }

  assert {
    condition = (
      contains([for s in data.aws_iam_policy_document.baseline_boundary[0].statement : s.sid], "denyAssumingAnyRole")
      && !contains([for s in data.aws_iam_policy_document.baseline_boundary[0].statement : s.sid], "assumeStateAndProvisionerRoles")
    )
    error_message = "With no state role or provisioner known, the baseline boundary denies every AssumeRole and allows none."
  }

  expect_failures = [check.declared_workspaces_can_be_created]
}

# --- Without manage_account_resources: another workspace owns the account ---
#
# Several workspaces in one account (one per stage): only the owner creates the
# OIDC provider and the boundary policies, every other one reads them by their
# fixed names. The data sources keep the ARNs they are given (only computed
# attributes are mocked), so the roles' references are checked as built.

run "without_account_resources_nothing_account_wide_is_created" {
  command = plan

  variables {
    manage_account_resources = false
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  assert {
    condition     = length(aws_iam_openid_connect_provider.github) == 0 && length(data.tls_certificate.github) == 0
    error_message = "Without manage_account_resources, no OIDC provider is created."
  }

  assert {
    condition     = length(aws_iam_policy.baseline_boundary) == 0 && alltrue([for class, boundary in module.permission_boundary : boundary.policy_arn == null])
    error_message = "Without manage_account_resources, no boundary policy is created, neither the classes nor the baseline's."
  }

  assert {
    condition     = output.github_oidc_provider_arn == "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    error_message = "Without manage_account_resources, the provider is the account's GitHub provider, read at its fixed ARN."
  }

  assert {
    condition = alltrue([
      for doc in concat(values(data.aws_iam_policy_document.cicd_read_assume_role), values(data.aws_iam_policy_document.cicd_deploy_assume_role)) :
      anytrue(flatten([
        for s in doc.statement : [
          for p in s.principals : contains(p.identifiers, "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com")
        ]
      ]))
    ])
    error_message = "Without manage_account_resources, every read and deploy role trusts the provider that was read."
  }

  assert {
    condition = output.permission_boundary_arns == {
      deploy  = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy"
      read    = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-read"
      service = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-service"
      users   = "arn:aws:iam::123456789012:policy/boundaries/omron-shared-users"
    }
    error_message = "Without manage_account_resources, each class is read at /boundaries/<namespace>-<application>-<class>, the name its owner gives it."
  }

  assert {
    condition = (
      aws_iam_role.cicd_deploy["shared-workload"].permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/shared-workload-baseline"
      && aws_iam_role.cicd_deploy["shared-cicd-infrastructure"].permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/omron-shared-deploy"
      && alltrue([for role in aws_iam_role.cicd_read : role.permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/omron-shared-read"])
    )
    error_message = "Without manage_account_resources, the roles carry the owner's boundaries: the baseline its own, the other deploy roles the deploy class, every read role the read class."
  }

  assert {
    condition     = length(terraform_data.permission_boundary_coverage) == 1
    error_message = "Without manage_account_resources, the classes are still rendered, so the coverage check still holds for this workspace's roles."
  }
}

run "without_account_resources_or_classes_no_boundary_is_read" {
  command = plan

  variables {
    manage_account_resources = false
  }

  assert {
    condition     = length(data.aws_iam_policy.class_boundary) == 0 && length(data.aws_iam_policy.baseline_boundary) == 0
    error_message = "Without classes, no boundary policy is read either."
  }

  assert {
    condition     = length(data.aws_iam_openid_connect_provider.github) == 1
    error_message = "Without manage_account_resources, the provider is read even without classes."
  }
}

run "without_account_resources_a_provider_without_the_sts_audience_fails" {
  command = plan

  variables {
    manage_account_resources = false
  }

  override_data {
    target = data.aws_iam_openid_connect_provider.github
    values = { client_id_list = ["sigstore"] }
  }

  expect_failures = [data.aws_iam_openid_connect_provider.github]
}

# The account carries a class other than the one this workspace renders, for
# example a service added to aws-organization's deploy class but not yet
# applied by the owner. Review on #65.
run "without_account_resources_a_class_that_differs_from_the_rendering_fails" {
  command = plan

  variables {
    manage_account_resources = false
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  override_data {
    target = data.aws_iam_policy.class_boundary["deploy"]
    values = {
      policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Action\":\"s3:*\",\"Resource\":\"*\"}]}"
    }
  }

  expect_failures = [data.aws_iam_policy.class_boundary]
}

# --- With a stage: several stages in one account -----------------------------
#
# Without a stage (every run above) the names are <repo>-read and
# <repo>-deploy, as shared-workload deploys them. With one, every pipeline role
# name carries it, and the baseline boundary covers every stage's baseline
# deploy role.

run "with_a_stage_every_pipeline_role_name_carries_it" {
  command = plan

  variables {
    stage = "dev"
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  assert {
    condition = (
      aws_iam_role.cicd_read["shared-workload"].name == "shared-workload-dev-read"
      && aws_iam_role.cicd_read["shared-cicd-infrastructure"].name == "shared-cicd-infrastructure-dev-read"
      && aws_iam_role.cicd_read["shared-terraform-registry"].name == "shared-terraform-registry-dev-read"
    )
    error_message = "With a stage, every read role is <repo>-<stage>-read."
  }

  assert {
    condition = (
      aws_iam_role.cicd_deploy["shared-workload"].name == "shared-workload-dev-deploy"
      && aws_iam_role.cicd_deploy["shared-cicd-infrastructure"].name == "shared-cicd-infrastructure-dev-deploy"
      && aws_iam_role.cicd_deploy["shared-terraform-registry:test"].name == "shared-terraform-registry-dev-test-deploy"
      && aws_iam_role.cicd_deploy["shared-terraform-registry:production"].name == "shared-terraform-registry-dev-production-deploy"
    )
    error_message = "With a stage, every deploy role is <repo>-<stage>-deploy, or <repo>-<stage>-<environment>-deploy with environments: still ending in -deploy, which the state role's trust matches on."
  }

  assert {
    condition = length([
      for s in data.aws_iam_policy_document.baseline_boundary[0].statement : s
      if s.sid == "denyChangingOwnBoundary" && toset(s.resources) == toset([
        "arn:aws:iam::123456789012:role/cicd/gha/shared-workload-deploy",
        "arn:aws:iam::123456789012:role/cicd/gha/shared-workload-*-deploy",
      ])
    ]) == 1
    error_message = "With a stage, the baseline boundary denies changing the boundary of every stage's baseline deploy role, not only this workspace's."
  }

  assert {
    condition     = length(terraform_data.stage_baseline_prefix) == 1
    error_message = "With a stage, the check that keeps other repositories out of the baseline's pattern runs."
  }
}

run "without_a_stage_the_prefix_check_does_not_run" {
  command = plan

  assert {
    condition     = length(terraform_data.stage_baseline_prefix) == 0
    error_message = "Without a stage there is no pattern, so no prefix to guard."
  }
}

run "with_a_stage_a_repository_under_the_baselines_prefix_is_rejected" {
  command = plan

  variables {
    stage = "dev"
    github_oidc_consumers = {
      cicd = {
        "shared-workload"       = { manages_account_baseline = true, services = [], manages_github = true }
        "shared-workload-extra" = { services = ["s3"] }
      }
    }
  }

  override_data {
    target = data.github_rest_api.oidc_subject["shared-workload-extra"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/shared-workload-extra@1\"}"
    }
  }

  override_data {
    target = data.github_rest_api.deployment_policies["shared-workload-extra"]
    values = {
      code = 200
      body = "{\"total_count\":1,\"branch_policies\":[{\"id\":1,\"name\":\"main\",\"type\":\"branch\"}]}"
    }
  }

  expect_failures = [terraform_data.stage_baseline_prefix]
}

# The stage itself can build a protected name from a key outside the prefix:
# baseline infra-dev, consumer infra, stage dev give infra-dev-deploy, the
# baseline's own exact deny. Copilot on #66.
run "with_a_stage_a_consumer_role_equal_to_the_baselines_is_rejected" {
  command = plan

  variables {
    stage = "dev"
    github_oidc_consumers = {
      cicd = {
        "infra-dev" = { manages_account_baseline = true, services = [], manages_github = true }
        "infra"     = { services = ["s3"] }
      }
    }
  }

  override_data {
    target = data.github_rest_api.oidc_subject["infra-dev"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/infra-dev@1\"}"
    }
  }

  override_data {
    target = data.github_rest_api.oidc_subject["infra"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/infra@2\"}"
    }
  }

  override_data {
    target = data.github_rest_api.deployment_policies["infra-dev"]
    values = {
      code = 200
      body = "{\"total_count\":1,\"branch_policies\":[{\"id\":1,\"name\":\"main\",\"type\":\"branch\"}]}"
    }
  }

  override_data {
    target = data.github_rest_api.deployment_policies["infra"]
    values = {
      code = 200
      body = "{\"total_count\":1,\"branch_policies\":[{\"id\":1,\"name\":\"main\",\"type\":\"branch\"}]}"
    }
  }

  expect_failures = [terraform_data.stage_baseline_prefix]
}

# And an Environment can: consumer infra with Environment test gives
# infra-dev-test-deploy, under the baseline's <baseline>-*-deploy pattern.
run "with_a_stage_a_consumer_environment_role_under_the_baselines_pattern_is_rejected" {
  command = plan

  variables {
    stage = "dev"
    github_oidc_consumers = {
      cicd = {
        "infra-dev" = { manages_account_baseline = true, services = [], manages_github = true }
        "infra"     = { services = ["s3"], environments = { test = {} } }
      }
    }
  }

  override_data {
    target = data.github_rest_api.oidc_subject["infra-dev"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/infra-dev@1\"}"
    }
  }

  override_data {
    target = data.github_rest_api.oidc_subject["infra"]
    values = {
      code = 200
      body = "{\"use_default\":true,\"use_immutable_subject\":true,\"sub_claim_prefix\":\"repo:OmronHealthCare-OHI@20930349/infra@2\"}"
    }
  }

  override_data {
    target = data.github_rest_api.deployment_policies["infra-dev"]
    values = {
      code = 200
      body = "{\"total_count\":1,\"branch_policies\":[{\"id\":1,\"name\":\"main\",\"type\":\"branch\"}]}"
    }
  }

  override_data {
    target = data.github_rest_api.deployment_policies["infra:test"]
    values = {
      code = 200
      body = "{\"total_count\":1,\"branch_policies\":[{\"id\":1,\"name\":\"main\",\"type\":\"branch\"}]}"
    }
  }

  expect_failures = [terraform_data.stage_baseline_prefix]
}

# connect-one-workload's qa and stg shape: a stage, without
# manage_account_resources. The owner's baseline boundary must name every
# stage's baseline deploy role, or this one could swap its own boundary.
# Review on #66.
run "a_stage_without_account_resources_rejects_an_owner_boundary_without_the_pattern" {
  command = plan

  variables {
    stage                    = "qa"
    manage_account_resources = false
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  # A stage-less owner's boundary: the deny names its own role only.
  override_data {
    target = data.aws_iam_policy.baseline_boundary
    values = { policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"denyChangingOwnBoundary\",\"Effect\":\"Deny\",\"Action\":[\"iam:PutRolePermissionsBoundary\",\"iam:DeleteRolePermissionsBoundary\"],\"Resource\":\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-deploy\"}]}" }
  }

  # This workspace's rendering stands in for the same document, so only the
  # pattern check fails, not the comparison with the owner's.
  override_data {
    target = data.aws_iam_policy_document.baseline_boundary
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"denyChangingOwnBoundary\",\"Effect\":\"Deny\",\"Action\":[\"iam:PutRolePermissionsBoundary\",\"iam:DeleteRolePermissionsBoundary\"],\"Resource\":\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-deploy\"}]}" }
  }

  expect_failures = [terraform_data.stage_baseline_prefix]
}

run "a_stage_without_account_resources_accepts_an_owner_boundary_with_the_pattern" {
  command = plan

  variables {
    stage                    = "qa"
    manage_account_resources = false
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  # An owner with a stage: the deny names every stage's baseline deploy role.
  override_data {
    target = data.aws_iam_policy.baseline_boundary
    values = { policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"denyChangingOwnBoundary\",\"Effect\":\"Deny\",\"Action\":[\"iam:PutRolePermissionsBoundary\",\"iam:DeleteRolePermissionsBoundary\"],\"Resource\":[\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-deploy\",\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-*-deploy\"]}]}" }
  }

  # And this workspace renders the same document.
  override_data {
    target = data.aws_iam_policy_document.baseline_boundary
    values = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"denyChangingOwnBoundary\",\"Effect\":\"Deny\",\"Action\":[\"iam:PutRolePermissionsBoundary\",\"iam:DeleteRolePermissionsBoundary\"],\"Resource\":[\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-deploy\",\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-*-deploy\"]}]}" }
  }

  assert {
    condition     = aws_iam_role.cicd_deploy["shared-workload"].name == "shared-workload-qa-deploy" && aws_iam_role.cicd_deploy["shared-workload"].permissions_boundary == "arn:aws:iam::123456789012:policy/boundaries/shared-workload-baseline"
    error_message = "This stage's baseline deploy role carries the owner's baseline boundary."
  }
}

# A stage whose baseline entry differs from the owner's: here a service only
# this workspace declares, so its rendering of the baseline boundary isn't the
# policy the owner applied. Its baseline deploy role would carry a boundary
# that doesn't allow that service. Review on #2 (CLF-146).
run "a_stage_without_account_resources_rejects_an_owner_baseline_boundary_that_differs" {
  command = plan

  variables {
    stage                    = "qa"
    manage_account_resources = false
    permission_boundaries = {
      deploy  = { allow_all = true, permit_policy_mutation = true }
      read    = { allow_all = true }
      service = { allowed_actions = ["s3:GetObject"], denied_actions = ["sts:AssumeRole"] }
      users   = { allow_all = true, denied_actions = ["iam:PassRole"] }
    }
  }

  # The owner's policy: rendered without the logs service this workspace's
  # baseline entry declares. The mocked rendering here is the provider's
  # default document, so any other policy stands for that difference.
  override_data {
    target = data.aws_iam_policy.baseline_boundary
    values = { policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"denyChangingOwnBoundary\",\"Effect\":\"Deny\",\"Action\":[\"iam:PutRolePermissionsBoundary\",\"iam:DeleteRolePermissionsBoundary\"],\"Resource\":[\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-deploy\",\"arn:aws:iam::123456789012:role/cicd/gha/shared-workload-*-deploy\"]}]}" }
  }

  expect_failures = [data.aws_iam_policy.baseline_boundary]
}

run "a_stage_that_pushes_a_role_name_past_64_characters_is_rejected" {
  command = plan

  variables {
    stage = "stg"
    github_oidc_consumers = {
      cicd = {
        "shared-workload" = { manages_account_baseline = true, services = [], manages_github = true }
        # 57 characters: <repo>-deploy fits, <repo>-stg-deploy doesn't.
        "a-repository-name-of-exactly-fifty-seven-characters-long0" = { services = ["s3"] }
      }
    }
  }

  expect_failures = [var.github_oidc_consumers]
}
