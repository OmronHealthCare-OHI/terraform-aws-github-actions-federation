# terraform-aws-github-actions-federation

The GitHub Actions federation of one AWS account: everything that lets the
repositories deploying into it log in with short-lived OIDC credentials, plan
read-only and apply behind a GitHub Environment.

| Resource | Name | Notes |
|---|---|---|
| GitHub Actions OIDC provider | `token.actions.githubusercontent.com` | One per account; every role in it federates against it. |
| Read role, per consumer | `<repo>[-<stage>]-read` at `/<cicd_roles_path>/<github_oidc_path>/` | Trusts `<prefix>:*`, read-only, assumes the read-only state role. |
| Deploy role, per consumer (or per Environment) | `<repo>[-<stage>]-deploy` / `<repo>[-<stage>]-<environment>-deploy` | Trusts only `<prefix>:environment:<env>`, writes the consumer's services, assumes the read/write state role. |
| GitHub Environment, variables, tag ruleset, reviewer access | per consumer | `DEPLOY_ROLE_ARN`, `<ACCOUNT>_READ_ROLE_ARN`, `TF_STATE_*`, `GH_APP_*`. |
| Declared workspaces | `env:/<workspace>/<repo>` | Created empty and create-only, through shared-cicd-infrastructure's workspace provisioner. |

`<prefix>` is read from GitHub for each consumer (`github-oidc-subjects.tf`),
never built from the name. The module is the general part of an account
baseline: [shared-workload](https://github.com/OmronHealthCare-OHI/shared-workload)
(OMRON-internal) calls it for the shared accounts and explains the design and
its reasons in its README, and connect-one-workload calls it for the Connect One
accounts.

## Using it

The caller selects the account and owns the providers: `aws` already running in
the account (`allowed_account_ids` pinned to it), `github` on
`github_organization`, and `tls`.

```hcl
module "github_actions_federation" {
  source = "github.com/OmronHealthCare-OHI/terraform-aws-github-actions-federation?ref=1.0.0"

  account_key   = "cicd"                                        # a key of github_oidc_consumers
  account_id    = data.aws_caller_identity.current.account_id
  label_context = module.label.context                          # account-level: a namespace, no stage

  github_oidc_consumers            = var.github_oidc_consumers
  repository_settings_owner        = "cicd"                     # owns the repository-level settings
  github_environment_reviewer_team = "cloud-foundations-in-connect-one-app"
  permission_boundaries            = var.permission_boundaries  # the deploy, read and service classes
  # state roles, bucket, workspace provisioner, GitHub App keys: see Inputs
}
```

**Pass `permission_boundaries`.** It defaults to empty, which renders no
classes, and without them the consumers' roles and the roles they create under
`/services/<repo>/` carry no boundary: a consumer that may write `lambda` could
run a function as a role with any policy it attaches. shared-workload passes
aws-organization's `shared_permission_boundaries` output. Making the classes
required is a separate, breaking change.

**A read role reads metadata, not values.** A pull request can assume it, so
it is denied secret values, DynamoDB items, and SSM parameter values and S3
object contents outside what the repository declares as its own: by default its
`/<repo>` parameters, and AWS's public `/aws/service/*`. A repository whose
Terraform manages an `aws_ssm_parameter` elsewhere, or an `aws_s3_object`,
declares the paths (`plan_parameter_paths`) or buckets (`plan_object_buckets`)
its plan refreshes. Other configurations' outputs stay readable:
`terraform_remote_state` reads them through the read-only state role, which
this doesn't touch.

The label context comes in as `label_context`, not the `context` other OHI
modules take, and there is no `label_context` output: the module was a local
module of shared-workload first, and its interface moved here unchanged.

Two worked examples, validated in CI:

- [`examples/basic`](examples/basic): one account, one workspace, as in
  shared-workload.
- [`examples/several-stages`](examples/several-stages): one workspace per
  `<stage>-<region>` in an account that holds several stages.

### Several workspaces in one account

The OIDC provider and the permission-boundary policies (the classes and
`<repo>-baseline`) exist once per account. With one workspace per account, as
in shared-workload, that workspace creates them. Where several workspaces share an account
(one per stage, with the stages of an environment in one account), exactly one
owns them and every other one sets `manage_account_resources = false`. Those
workspaces read the provider and the policies by their fixed names. Their plan
fails until the owner has applied, and fails if the provider doesn't accept the
`sts.amazonaws.com` audience the roles trust. They still render the classes, so
the coverage check holds for their own roles, and they compare each class they
read with that rendering: a class change fails their plan until the owner has
applied it.

So every workspace of an account passes the same account-level
`label_context`, without a stage. The class policies are named from it
(`<namespace>-<application>-<class>`), and a stage in the label would have the
qa workspace look up `omron-eu-qa-deploy` where the dev owner created
`omron-eu-dev-deploy`.

The pipeline roles are per workspace, and their names are per account, so
each of those workspaces also sets `stage`: its roles become
`<repo>-<stage>-read` and `<repo>-<stage>-deploy`. A stage appears once per
account: two regions of one stage in one account would claim the same role
names, so each region of a stage needs its own account (as Connect One has,
with nonprd/eu and nonprd/us). With an account per stage
the account id already tells the stages apart, so `stage` stays unset and the
names stay `<repo>-read` and `<repo>-deploy`. The account's owner sets `stage`
too: the baseline boundary it renders then covers every stage's baseline deploy
role (`<baseline>-*-deploy`); a stage workspace fails its plan until the
owner's boundary has that pattern. And no other consumer's deploy role name
may start with `<baseline>-`.

`stage` is the workspace's stage. `environments` on a consumer is a different
thing: several GitHub Environments, each with its own deploy role, of one
repository in one workspace.

### A region per workspace

This module creates IAM roles and GitHub settings, and IAM is global, so it
takes no region. The region belongs to each consumer's own Terraform root,
the same way as at Luscii:

- **A workspace per stage and region.** The workspace is `<stage>-<region>`
  with a short region code (`dev-eu`, `prd-us`), and its region and the rest
  of its settings come from `config/<stage>-<region>.tfvars` in the
  consumer's repository.
- **The consumer lists its own stages and regions** in
  `infrastructure/regions.json`, a stage → regions map such as
  `{"dev": ["eu", "us"], "prd": ["eu"]}`. Its workflows build their matrix
  from it with `fromJSON` instead of typing rows by hand, one run per stage
  with one job per region.
- **The workflow's `aws-region` stays fixed.** It only selects where
  `configure-aws-credentials` gets the session; the roles are global, and the
  Terraform provider takes its region from the tfvars.

What the workflow needs per row it derives from the stage and region, because
this module names everything after the workspace key (`account_key`,
the `github_oidc_consumers` key), and in a configuration with a workspace per
stage and region that key is `<stage>-<region>` too:

| For workspace `<stage>-<region>` | Name | Where |
|---|---|---|
| Plan role | `vars.<STAGE>_<REGION>_READ_ROLE_ARN` (`DEV_EU_READ_ROLE_ARN`) | repository variable |
| Deploy Environment | `<stage>-<region>` (unless the consumer sets `environment` or `environments`) | GitHub Environment |
| Deploy role | `vars.DEPLOY_ROLE_ARN` | in that Environment |
| Terraform workspace | `<stage>-<region>`, declared in the consumer's `workspaces` under that key | created by this module |

```yaml
# A consumer's plan job, one row per region of the stage:
strategy:
  matrix:
    region: ${{ fromJSON(needs.regions.outputs.dev) }}
steps:
  - uses: aws-actions/configure-aws-credentials@<sha>
    with:
      # Expressions have no upper(), but the runner looks up context
      # properties ignoring case, so dev_eu finds DEV_EU_READ_ROLE_ARN.
      role-to-assume: ${{ vars[format('DEV_{0}_READ_ROLE_ARN', matrix.region)] }}
      aws-region: us-west-2 # fixed: credentials only
  # workspace dev-${{ matrix.region }}, -var-file=config/dev-${{ matrix.region }}.tfvars
```

`regions.json` and the workspaces declared here are two lists of the same
thing, and nothing checks one against the other:

- A workspace declared here but missing from `regions.json` is never planned
  or deployed.
- A `regions.json` row for a workspace whose state doesn't exist fails loudly:
  the plan job's read role can't create a workspace, and selecting one that
  doesn't exist fails (unlike Luscii's `workspace select -or-create`).
- A `regions.json` row for a workspace that was declared once and has since
  been removed here does **not** fail. Removing a declaration never deletes
  the workspace's state (`workspaces.tf`), and the consumer's roles don't
  depend on it, so the row keeps planning and deploying. The declaration is
  what gets a workspace created, not an allowlist of where a consumer may
  deploy.

So add a stage or region here first, then to `regions.json`. Retire one the
other way round: from `regions.json` first, then here; deleting its state is a
separate, deliberate step.


## The vendored permission-boundary module

`modules/iam-policy-permission-boundary` is
[Luscii/terraform-aws-iam-policy-permission-boundary](https://github.com/Luscii/terraform-aws-iam-policy-permission-boundary)
(MIT), vendored rather than sourced, because OMRON code doesn't take modules
from another organisation. Its `main.tf` names the upstream commit and lists the
four changes made here, each marked `VENDORED change` where it is. It keeps its
upstream tests, which run in CI next to this module's.

## Tests

`terraform test` from the repository root, the vendored module's tests from its
directory, and the workspace-state script's own test: see
[tests/README.md](tests/README.md). CI runs all of them, and the module's and
the vendored module's tests again on the `required_version` floor.

## Local development

```sh
pre-commit install
terraform init -backend=false
terraform test
pre-commit run --all-files
```

Versions and releases: see [CONTRIBUTING.md](CONTRIBUTING.md).

## Reference

<!-- BEGIN_TF_DOCS -->
### Requirements

| Name | Version |
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.12.0 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.30 |
| <a name="requirement_github"></a> [github](#requirement\_github) | ~> 6.13 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.2 |

### Providers

| Name | Version |
| ---- | ------- |
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.73.0 |
| <a name="provider_github"></a> [github](#provider\_github) | 6.13.0 |
| <a name="provider_terraform"></a> [terraform](#provider\_terraform) | n/a |
| <a name="provider_tls"></a> [tls](#provider\_tls) | 4.4.2 |

### Modules

| Name | Source | Version |
| ---- | ------ | ------- |
| <a name="module_baseline_boundary_label"></a> [baseline\_boundary\_label](#module\_baseline\_boundary\_label) | github.com/OmronHealthCare-OHI/terraform-null-label | 1.0.0 |
| <a name="module_github_oidc_label"></a> [github\_oidc\_label](#module\_github\_oidc\_label) | github.com/OmronHealthCare-OHI/terraform-null-label | 1.0.0 |
| <a name="module_permission_boundary"></a> [permission\_boundary](#module\_permission\_boundary) | ./modules/iam-policy-permission-boundary | n/a |

### Resources

| Name | Type |
| ---- | ---- |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_openid_connect_provider) | resource |
| [aws_iam_policy.baseline_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_role.cicd_deploy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role.cicd_read](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.cicd_deploy_assume_state_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cicd_deploy_assume_workspace_provisioner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cicd_deploy_github_app_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cicd_deploy_github_app_key_guard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cicd_deploy_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cicd_read_assume_state_access](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cicd_read_github_app_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy.cicd_read_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [github_actions_environment_variable.consumer](https://registry.terraform.io/providers/integrations/github/latest/docs/resources/actions_environment_variable) | resource |
| [github_actions_variable.consumer](https://registry.terraform.io/providers/integrations/github/latest/docs/resources/actions_variable) | resource |
| [github_repository_environment.consumer](https://registry.terraform.io/providers/integrations/github/latest/docs/resources/repository_environment) | resource |
| [github_repository_environment_deployment_policy.main](https://registry.terraform.io/providers/integrations/github/latest/docs/resources/repository_environment_deployment_policy) | resource |
| [github_repository_ruleset.release_tags](https://registry.terraform.io/providers/integrations/github/latest/docs/resources/repository_ruleset) | resource |
| [github_team_repository.reviewers](https://registry.terraform.io/providers/integrations/github/latest/docs/resources/team_repository) | resource |
| [terraform_data.permission_boundary_coverage](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.stage_baseline_prefix](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [terraform_data.workspace_state](https://registry.terraform.io/providers/hashicorp/terraform/latest/docs/resources/data) | resource |
| [aws_iam_openid_connect_provider.github](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_openid_connect_provider) | data source |
| [aws_iam_policy.baseline_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy) | data source |
| [aws_iam_policy.class_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy) | data source |
| [aws_iam_policy_document.baseline_boundary](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_assume_read_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_assume_state](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_assume_workspace_provisioner](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_deploy_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_deploy_github_app_key_guard](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_deploy_iam_baseline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_deploy_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_github_app_key](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_read_assume_role](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_read_iam_baseline](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.cicd_read_permissions](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [github_rest_api.deployment_policies](https://registry.terraform.io/providers/integrations/github/latest/docs/data-sources/rest_api) | data source |
| [github_rest_api.oidc_subject](https://registry.terraform.io/providers/integrations/github/latest/docs/data-sources/rest_api) | data source |
| [github_team.reviewers](https://registry.terraform.io/providers/integrations/github/latest/docs/data-sources/team) | data source |
| [tls_certificate.github](https://registry.terraform.io/providers/hashicorp/tls/latest/docs/data-sources/certificate) | data source |

### Inputs

| Name | Description | Type | Default | Required |
| ---- | ----------- | ---- | ------- | :------: |
| <a name="input_account_id"></a> [account\_id](#input\_account\_id) | AWS account id of that account, as the caller's identity reports it: the ARNs this module grants on (the /cicd/gha/ roles, the OIDC provider, the boundary policies) are built from it. Pass the calling configuration's data.aws\_caller\_identity, so it is the account the aws provider actually runs in. | `string` | n/a | yes |
| <a name="input_account_key"></a> [account\_key](#input\_account\_key) | The account this instance federates, as a key of github\_oidc\_consumers (for shared-workload: the shared account's entry id, cicd). Selects the account's consumers, names its read-role variable (<ACCOUNT>\_READ\_ROLE\_ARN) and is the default Environment of a consumer that sets none. | `string` | n/a | yes |
| <a name="input_cicd_roles_path"></a> [cicd\_roles\_path](#input\_cicd\_roles\_path) | Top-level IAM path segment (no slashes) for pipeline-owned roles. Composed with github\_oidc\_path into the roles' path: "cicd" + "gha" gives /cicd/gha/. The path is the key of the permission-boundary taxonomy (CLF-54): pipeline roles here carry the deploy or read class (permission-boundaries.tf). | `string` | `"cicd"` | no |
| <a name="input_create_workspace_states"></a> [create\_workspace\_states](#input\_create\_workspace\_states) | Whether creating a declared workspace (terraform\_data.workspace\_state) calls the workspace provisioner. A test switch: terraform test sets it to false in its apply runs, because a provisioner runs even under an override and would otherwise call the real AWS CLI. Off, the records are kept and nothing is created; back on, every record is replaced and its creation runs. Leave it true everywhere else. | `bool` | `true` | no |
| <a name="input_github_app_key_arns"></a> [github\_app\_key\_arns](#input\_github\_app\_key\_arns) | The ARNs of shared-cicd-infrastructure's GitHub App keys, from its outputs:<br/>plan\_secret\_arn and apply\_secret\_arn from github\_app\_key\_secret\_arns (plan,<br/>apply), kms\_key\_arn from github\_app\_keys\_kms\_key\_arn. The read role of every<br/>manages\_github repository may read the plan key, its deploy role the apply<br/>key (github-app-keys-access.tf). Null until shared-cicd-infrastructure has<br/>applied the keys; then set it here and apply again, as with state\_role\_arn. | <pre>object({<br/>    plan_secret_arn  = string<br/>    apply_secret_arn = string<br/>    kms_key_arn      = string<br/>  })</pre> | `null` | no |
| <a name="input_github_environment_reviewer_team"></a> [github\_environment\_reviewer\_team](#input\_github\_environment\_reviewer\_team) | Slug of the default reviewer team: the GitHub team whose approval a consumer's deploy Environments require, and which gets access to the consumer's repository (github-team-access.tf), because GitHub drops a required reviewer that can't see the repository. A consumer sets its own with reviewer\_team. Looked up through the GitHub Apps, which need the organization's Members: read permission for it. | `string` | n/a | yes |
| <a name="input_github_environment_reviewer_team_permission"></a> [github\_environment\_reviewer\_team\_permission](#input\_github\_environment\_reviewer\_team\_permission) | The reviewer team's access on every consumer repository (github-team-access.tf). maintain is what it had, set by hand, on every consumer when this was adopted (2026-10-20). Reviewing a deployment needs at least pull. | `string` | `"maintain"` | no |
| <a name="input_github_oidc_consumers"></a> [github\_oidc\_consumers](#input\_github\_oidc\_consumers) | The repositories that deploy into each shared account, keyed by shared<br/>account entry id (the workspace name), then by repository name (without the<br/>organization). Each repository gets two roles in that account at<br/>/<cicd\_roles\_path>/<github\_oidc\_path>/, trusting GitHub's OIDC subject<br/>prefix for it (<prefix> = repo:<org>[@<owner-id>]/<repo>[@<repo-id>],<br/>looked up from GitHub, so a name is all a new consumer needs here; the<br/>GitHub Apps must be installed on it):<br/><br/>  <repo>-read    trusts <prefix>:* (any branch, PR or tag);<br/>                 read-only, for PR plans.<br/>  <repo>-deploy  trusts only <prefix>:environment:<environment>;<br/>                 for applies through the GitHub Environment, which only<br/>                 allows main and requires reviewers.<br/><br/>A repository that lists environments gets one deploy role per entry<br/>instead, <repo>-<environment>-deploy, each trusting only its own<br/>Environment: one per stage, each with its own gate and its own audit<br/>trail. Not isolation: the roles share the repository's services and IAM<br/>path in the same account.<br/><br/>Both carry ohi:repository = <repo>: the session tag that<br/>shared-cicd-infrastructure's state role scopes writes by.<br/><br/>Per repository:<br/>  services                  AWS service prefixes the deploy role may write<br/>                            (<svc>:*) and the read role may read. Not iam or<br/>                            sts: IAM access is the fixed split in the role<br/>                            files, never a service wildcard.<br/>  environment               The GitHub Environment the deploy role trusts.<br/>                            Defaults to the account key, so a repository that<br/>                            deploys to several shared accounts has one<br/>                            Environment, and one DEPLOY\_ROLE\_ARN, per account.<br/>  environments              Instead of environment: several Environments in<br/>                            this account, keyed by name (letters, digits,<br/>                            . \_ -), each with its own deploy role. Per<br/>                            Environment, requires\_approval (default true):<br/>                            whether the reviewer team must approve; main is<br/>                            the only deploying branch either way. Not for the<br/>                            baseline or a manages\_github repository, whose<br/>                            single deploy role the rest of this<br/>                            configuration names.<br/>  workspaces                Named Terraform workspaces of the repository<br/>                            (e.g. its stages: test, production). Each<br/>                            env:/<workspace>/<repo> is created here, empty<br/>                            and create-only, before the repository's first<br/>                            plan, through shared-cicd-infrastructure's<br/>                            workspace provisioner (workspaces.tf, CLF-96).<br/>                            Removing one never deletes its state. Not<br/>                            "default": that workspace needs no creating.<br/>  manages\_account\_baseline  Exactly one repository per account: the one<br/>                            whose deploy role applies this configuration.<br/>                            Its deploy role may also manage the OIDC provider,<br/>                            the /cicd/gha/ roles and the permission-boundary<br/>                            policies at /boundaries/, which every other<br/>                            repository is explicitly denied, and it is not<br/>                            denied changing itself (github-oidc-role-deploy.tf).<br/>  manages\_github            The repository's Terraform manages GitHub itself<br/>                            (Environments, secrets, variables) through the<br/>                            GitHub Apps in shared-cicd-infrastructure: its<br/>                            read role may read the plan App's key, its<br/>                            deploy role the apply App's (once<br/>                            github\_app\_key\_arns is set; github-app-keys-access.tf).<br/>                            Must match github\_app\_repositories there.<br/>  reviewer\_team             Slug of the GitHub team whose approval this<br/>                            repository's Environments require, and which<br/>                            gets access to it (github-team-access.tf).<br/>                            Defaults to github\_environment\_reviewer\_team.<br/>  plan\_parameter\_paths      The SSM parameter paths whose values this<br/>                            repository's read role may read (a plan<br/>                            refreshing an aws\_ssm\_parameter decrypts it).<br/>                            IAM patterns starting with "/", "*" only at the<br/>                            end. Defaults to ["/<repo>", "/<repo>/*"]; AWS's<br/>                            public /aws/service/* is always readable. Every<br/>                            other parameter's value is denied<br/>                            (github-oidc-role-read.tf, CLF-145).<br/>  plan\_object\_buckets       The S3 buckets whose objects this repository's<br/>                            read role may read (a plan refreshing an<br/>                            aws\_s3\_object needs s3:GetObject), by name.<br/>                            Defaults to none: every other object is denied.<br/>                            Reading other configurations' outputs through<br/>                            terraform\_remote\_state is unaffected: that goes<br/>                            through the read-only state role.<br/><br/>Set in consumers.auto.tfvars. | <pre>map(map(object({<br/>    services    = list(string)<br/>    environment = optional(string)<br/>    environments = optional(map(object({<br/>      requires_approval = optional(bool, true)<br/>    })))<br/>    workspaces               = optional(list(string), [])<br/>    manages_account_baseline = optional(bool, false)<br/>    manages_github           = optional(bool, false)<br/>    reviewer_team            = optional(string)<br/>    plan_parameter_paths     = optional(list(string))<br/>    plan_object_buckets      = optional(list(string), [])<br/>  })))</pre> | n/a | yes |
| <a name="input_github_oidc_path"></a> [github\_oidc\_path](#input\_github\_oidc\_path) | IAM path segment (no slashes) under cicd\_roles\_path for the GitHub Actions roles. Another CI provider would sit beside it. | `string` | `"gha"` | no |
| <a name="input_github_organization"></a> [github\_organization](#input\_github\_organization) | GitHub organization that owns the consuming repositories. Every OIDC subject this configuration trusts is anchored on GitHub's subject prefix for the repository, repo:<github\_organization>[@<owner-id>]/<repo>[@<repo-id>], read from GitHub (github-oidc-subjects.tf). | `string` | `"OmronHealthCare-OHI"` | no |
| <a name="input_label_context"></a> [label\_context](#input\_label\_context) | The account-level terraform-null-label context the module's labels compose beneath (for shared-workload: omron-shared-<account>). It must carry a namespace. Only the OIDC provider is tagged through it; the roles carry the provider's default\_tags. | `any` | n/a | yes |
| <a name="input_manage_account_resources"></a> [manage\_account\_resources](#input\_manage\_account\_resources) | Whether this configuration owns the account-wide resources: the GitHub<br/>OIDC provider and the permission-boundary policies (the classes and the<br/>baseline repository's own). Each exists once per account, so exactly one<br/>configuration may create it.<br/><br/>true (the default): creates them, as shared-workload does with one<br/>workspace per account.<br/><br/>false: where several workspaces share an account (one per stage, with the<br/>stages of an environment in one account), every workspace but the owner<br/>sets it. The module then reads the provider and the policies the owner<br/>created, by their fixed names, and the plan fails until the owner has<br/>applied, or if the provider doesn't accept the sts.amazonaws.com audience<br/>every role here trusts. Roles, Environments and variables are not<br/>account-wide and stay with every workspace. | `bool` | `true` | no |
| <a name="input_permission_boundaries"></a> [permission\_boundaries](#input\_permission\_boundaries) | The permission-boundary classes to render in this account, keyed by class<br/>name, in the shape aws-organization publishes them (its<br/>shared\_permission\_boundaries output). Each becomes a policy at /boundaries/<br/>named <namespace>-<application>-<class> from the label (omron-shared-deploy,<br/>…), the same name in every account of that application, so an Identity<br/>Center permission set can reference the users class by name and path.<br/>Empty (the default) renders none.<br/><br/>When set, it must carry the classes the federation's roles use (deploy,<br/>read and service), and those must cover every consumer's services in every<br/>account: deploy <svc>:*, read <svc>:Get*, List* and Describe*. A consumer<br/>that adds a service needs it in aws-organization's classes first. | <pre>map(object({<br/>    allow_all                 = optional(bool, false)<br/>    allowed_actions           = optional(list(string), [])<br/>    denied_actions            = optional(list(string), [])<br/>    permit_policy_mutation    = optional(bool, false)<br/>    permit_human_user_actions = optional(bool, false)<br/>    permit_org_governance     = optional(bool, false)<br/>  }))</pre> | `{}` | no |
| <a name="input_read_state_role_arn"></a> [read\_state\_role\_arn](#input\_read\_state\_role\_arn) | ARN of shared-cicd-infrastructure's read-only state role (its read\_state\_role\_arn output, CLF-88). Every <repo>-read role gets sts:AssumeRole and sts:TagSession on it, and nothing on the read/write role: a pull request can assume the read role, so its plan reads state but never writes it, and runs with -lock=false. Empty until shared-cicd-infrastructure has applied that role; then set it here and apply again. | `string` | `""` | no |
| <a name="input_repository_settings_owner"></a> [repository\_settings\_owner](#input\_repository\_settings\_owner) | The workspace that manages every consumer's repository-level settings:<br/>a github\_oidc\_consumers key (account\_key), such as cicd in shared-workload<br/>or one stage and region in a configuration with a workspace per stage.<br/><br/>Repository-level settings are attached to the repository, not to one<br/>workspace's Environment, and have the same value from every workspace:<br/>the release-tag ruleset, the reviewer team's access, and the<br/>repository-level Actions variables GH\_APP\_PLAN\_KEY\_SECRET\_ARN and the<br/>state backend's TF\_STATE\_*. Two workspaces managing them would overwrite<br/>each other on every apply, so this one manages them for every consumer of<br/>every workspace, including a repository that doesn't deploy through it.<br/>Every workspace still manages its own Environments, their variables and<br/>its own <ACCOUNT\_KEY>\_READ\_ROLE\_ARN, whose names differ per workspace.<br/><br/>No default: every configuration names its owner. One rule this module<br/>can't check: a repository that is a consumer in two configurations<br/>(shared-workload and connect-one-workload) would have an owner in each. | `string` | n/a | yes |
| <a name="input_stage"></a> [stage](#input\_stage) | The stage this workspace deploys (dev, qa, stg, …), to put in the pipeline<br/>role names: <repo>-<stage>-read, <repo>-<stage>-deploy and<br/><repo>-<stage>-<environment>-deploy. Only needed where several stages<br/>share an account (see manage\_account\_resources), because the role names<br/>are per account. With an account per stage the account id already tells<br/>the stages apart, so leave it null (the default): names stay<br/><repo>-read and <repo>-deploy.<br/><br/>Set, it also widens the baseline boundary's own-boundary deny to every<br/>stage's baseline deploy role (<baseline>-*-deploy), so the owner of a<br/>shared account sets it too; a workspace without<br/>manage\_account\_resources fails its plan until the owner's boundary has<br/>that pattern. No other consumer's deploy role name may then<br/>start with "<baseline>-", which a stage or an Environment can produce<br/>from an unrelated key: that role would fall under the deny. | `string` | `null` | no |
| <a name="input_state_bucket"></a> [state\_bucket](#input\_state\_bucket) | Name of shared-cicd-infrastructure's state bucket (its state\_bucket output). Published to every consumer repository as TF\_STATE\_BUCKET, for gha-terraform-backend (github\_actions\_settings). Empty publishes no TF\_STATE\_* variable. | `string` | `""` | no |
| <a name="input_state_region"></a> [state\_region](#input\_state\_region) | Region of shared-cicd-infrastructure's state bucket (its state\_region output). Published to every consumer repository as TF\_STATE\_REGION, for gha-terraform-backend (github\_actions\_settings). Empty publishes no TF\_STATE\_* variable. | `string` | `""` | no |
| <a name="input_state_role_arn"></a> [state\_role\_arn](#input\_state\_role\_arn) | ARN of shared-cicd-infrastructure's read/write state role (its state\_role\_arn output). Every <repo>-deploy role gets sts:AssumeRole and sts:TagSession on it, and only those: its trust admits *-deploy roles only (CLF-88). For <repo>-read, see read\_state\_role\_arn. the backend assumes it with the repository as the ohi:repository session tag, and it then reads every state and writes only the repository's own (key = <repo>; per workspace env:/<workspace>/<repo>). Empty until shared-cicd-infrastructure's first apply (the bootstrap's step 2); then set it here and apply again. | `string` | `""` | no |
| <a name="input_workspace_provisioner_role_arn"></a> [workspace\_provisioner\_role\_arn](#input\_workspace\_provisioner\_role\_arn) | ARN of shared-cicd-infrastructure's workspace provisioner (its workspace\_provisioner\_role\_arn output, CLF-95). The baseline repository's deploy role gets sts:AssumeRole and sts:TagSession on it, and creates through it every declared workspace state that does not exist yet (workspaces.tf). Its trust admits only the deploy roles in its workspace\_provisioner\_repositories. Empty until shared-cicd-infrastructure has applied that role; while it is, declared workspaces are not created and a check says so. | `string` | `""` | no |

### Outputs

| Name | Description |
| ---- | ----------- |
| <a name="output_deploy_role_arn"></a> [deploy\_role\_arn](#output\_deploy\_role\_arn) | ARN of each deploy role, keyed by deploy unit: the repository for its <repo>-deploy role, <repo>:<environment> for each <repo>-<environment>-deploy role of a repository with environments. Goes in DEPLOY\_ROLE\_ARN inside that role's GitHub Environment, never at repository level. |
| <a name="output_github_actions_settings"></a> [github\_actions\_settings](#output\_github\_actions\_settings) | What each consuming repository has in GitHub, all managed by this configuration (CLF-93): each GitHub Environment a deploy role trusts (allow only main, require reviewers unless a stage turns them off; github-environments.tf) with its variables, keyed by Environment name under environments, and the repository-level ones (github-actions-variables.tf). Per repository: DEPLOY\_ROLE\_ARN in each Environment and <ACCOUNT>\_READ\_ROLE\_ARN at repository level; for a manages\_github repository, the ARNs of the GitHub App key secrets, which also hold each App's client ID (the apply key's in the Environment, the plan key's at repository level); once the state backend is known (state\_bucket, state\_region and both state role ARNs), gha-terraform-backend's TF\_STATE\_BUCKET, TF\_STATE\_REGION and TF\_STATE\_ROLE\_ARN (the read-only state role) at repository level, and TF\_STATE\_ROLE\_ARN (the read/write one) in the Environment. |
| <a name="output_github_app_installation_repositories"></a> [github\_app\_installation\_repositories](#output\_github\_app\_installation\_repositories) | Every repository the two GitHub Apps must be installed on: each consumer in every account, because the plan reads each one's OIDC subject prefix and manages its Environment and variables with the Apps' tokens. The PR plan job compares this list with the plan App's installation and fails on any difference, missing or extra (CLF-93); the installation itself is changed by hand. |
| <a name="output_github_oidc_provider_arn"></a> [github\_oidc\_provider\_arn](#output\_github\_oidc\_provider\_arn) | ARN of the GitHub Actions OIDC provider in this account, created here or, without manage\_account\_resources, read. |
| <a name="output_permission_boundary_arns"></a> [permission\_boundary\_arns](#output\_permission\_boundary\_arns) | ARN of each permission-boundary class's policy in this account, keyed by class name (permission-boundaries.tf). The same name and path in every account of the same label namespace and application: /boundaries/<namespace>-<application>-<class> (omron-shared-deploy, …). Created here or, without manage\_account\_resources, read. Empty when no classes are given. |
| <a name="output_read_role_arn"></a> [read\_role\_arn](#output\_read\_role\_arn) | ARN of each repository's <repo>-read role, keyed by repository. The plan role of the pull-request pipeline: it reads state through the read-only state role and writes nothing (the deploy pipeline plans with its deploy role). Goes in a repository-level GitHub Actions variable. |
| <a name="output_workspaces"></a> [workspaces](#output\_workspaces) | The named Terraform workspaces declared for each repository in this account (github\_oidc\_consumers' workspaces), keyed by repository; an empty list means the default workspace only. Each is created once, empty and create-only, as env:/<workspace>/<repo> (workspaces.tf). A repository's own matrix must stay within this list: gha-terraform-backend selects a workspace, it never creates one. |
<!-- END_TF_DOCS -->
