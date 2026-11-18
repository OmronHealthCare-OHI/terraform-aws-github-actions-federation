# The identity half of reading a GitHub App key, for the repositories whose
# Terraform manages GitHub itself (manages_github in consumers.auto.tfvars).
#
# shared-cicd-infrastructure holds the private keys of two GitHub Apps
# (github-app-keys.tf there) and decides, in each secret's resource policy and
# in the KMS key policy, who may read them: the plan App's key to <repo>-read,
# the apply App's key to <repo>-deploy, for its github_app_repositories only.
# That is the gate. This file is the grant the reading role must hold as well:
# a key policy that names account roots delegates to IAM, and a read from
# another account always needs both sides. The two lists, manages_github here
# and github_app_repositories there, name the same repositories; a repository
# in only one of them reads nothing.
#
#   <repo>-read    GetSecretValue on the plan key, and the exception to its
#                  denySecretRetrieval (github-oidc-role-read.tf) for exactly
#                  that secret. A pull request's plan can then mint a
#                  read-only GitHub token, and read no other secret.
#   <repo>-deploy  GetSecretValue on the apply key. Only the protected
#                  Environment can assume it.
#
# Both may decrypt with the App keys' KMS key only through Secrets Manager and
# only under their own App's secret (the encryption context Secrets Manager
# passes), as the key policy requires too.
#
# Accepted risk: the read role trusts every ref, so a pull request can rewrite
# its workflow and keep the plan App's private key, which does not expire. What
# it then holds is the plan App's reach, lasting until the key is rotated
# (shared-cicd-infrastructure's github-apps/README.md): read-only, no contents,
# secret names but never values, on the repositories the App is installed on
# and the organization's settings and variables. Only someone who can push a
# branch gets that far; a fork's pull request gets no OIDC token. Suspected
# exposure is answered by rotating the plan key. Keeping the key out of the
# runner altogether (a signer that never releases it) is CLF-89.
#
# Own policies, named github-app-key, so revoking one repository's access never
# touches its other grants. Absent while var.github_app_key_arns is null, which
# is only the case before shared-cicd-infrastructure has applied the keys.

locals {
  github_repositories = [for repo, consumer in local.consumers : repo if consumer.manages_github]

  # The pipeline role each App's key is for, and the secret.
  github_app_keys = var.github_app_key_arns == null ? {} : {
    plan  = var.github_app_key_arns.plan_secret_arn
    apply = var.github_app_key_arns.apply_secret_arn
  }

  github_app_key_repositories = var.github_app_key_arns == null ? [] : local.github_repositories
}

data "aws_iam_policy_document" "cicd_github_app_key" {
  for_each = local.github_app_keys

  statement {
    sid       = "readGithubAppKey"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [each.value]
  }

  # The secret's own region: Secrets Manager calls KMS from there.
  statement {
    sid       = "decryptGithubAppKeyThroughSecretsManager"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.github_app_key_arns.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${split(":", each.value)[3]}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:SecretARN"
      values   = [each.value]
    }
  }
}

resource "aws_iam_role_policy" "cicd_read_github_app_key" {
  for_each = toset(local.github_app_key_repositories)

  name   = "github-app-key"
  role   = aws_iam_role.cicd_read[each.key].id
  policy = data.aws_iam_policy_document.cicd_github_app_key["plan"].json
}

# Keyed by repository, which is also the deploy unit's key: a manages_github
# repository has one deploy role (no environments; variables.tf).
resource "aws_iam_role_policy" "cicd_deploy_github_app_key" {
  for_each = toset(local.github_app_key_repositories)

  name   = "github-app-key"
  role   = aws_iam_role.cicd_deploy[each.key].id
  policy = data.aws_iam_policy_document.cicd_github_app_key["apply"].json
}

# The guard, on EVERY deploy role (each deploy unit's, so every stage of a
# repository with environments too), the manages_github ones included. The
# secrets' resource policy in shared-cicd-infrastructure is the gate, but not
# a durable one on its own: a deploy role with secretsmanager in its services
# (shared-cicd-infrastructure's own, which creates the secrets) holds
# secretsmanager:* on *, so it could rewrite that resource policy and then
# read a key. An identity deny cannot be lifted from that side, and no deploy
# role may delete its own policies (denySelfModify in github-oidc-role-deploy.tf).
# The one exception is the baseline repository's (manages_account_baseline):
# it applies this file, so it maintains these roles and their guards, its own
# included, and could drop that guard. For that role the secrets' resource
# policy holds alone, behind the Environment's reviewers; its guard states the
# intent, it is not a control.
#
# Durable only together with the resource side: the guard binds the deploy
# role, not a role it creates. Until CLF-54 bounds the roles a deploy role
# may create under /services/<repo>/, shared-cicd-infrastructure's could mint
# an unbounded helper role, so the secrets' own policy (in that repository)
# lets no pipeline role change it, replicate the secrets or delete them: only
# the admin role, in a recorded local apply. A helper is then still refused by
# its read deny.
#
#   GetSecretValue  denied on every App key the role is not granted: both for
#                   a repository that does not manage GitHub, the plan key for
#                   one that does (its deploy role reads the apply key only).
#   PutSecretValue  denied on both: the values are delivered by hand
#                   (shared-cicd-infrastructure creates the secrets empty and
#                   has no secret version), so no pipeline ever writes one.
#   ReplicateSecretToRegions
#                   denied on both: a replica copies the value under another
#                   region's ARN, which the exact-ARN denies above don't cover,
#                   and it can be promoted and given its own policy.
#
# Not denied: secretsmanager:UpdateSecret, which can also set a value, because
# Terraform needs it to change a secret's description or KMS key. A deploy
# role misusing it can destroy a key (fixed by delivering it again), never
# read one.
data "aws_iam_policy_document" "cicd_deploy_github_app_key_guard" {
  for_each = var.github_app_key_arns == null ? {} : local.github_oidc_deploy_units

  statement {
    sid     = "denyGithubAppKeyRetrieval"
    effect  = "Deny"
    actions = ["secretsmanager:GetSecretValue"]
    resources = contains(local.github_app_key_repositories, each.value.repository) ? [
      var.github_app_key_arns.plan_secret_arn,
      ] : [
      var.github_app_key_arns.plan_secret_arn,
      var.github_app_key_arns.apply_secret_arn,
    ]
  }

  statement {
    sid     = "denyGithubAppKeyValueWrites"
    effect  = "Deny"
    actions = ["secretsmanager:PutSecretValue"]
    resources = [
      var.github_app_key_arns.plan_secret_arn,
      var.github_app_key_arns.apply_secret_arn,
    ]
  }

  statement {
    sid     = "denyGithubAppKeyReplication"
    effect  = "Deny"
    actions = ["secretsmanager:ReplicateSecretToRegions"]
    resources = [
      var.github_app_key_arns.plan_secret_arn,
      var.github_app_key_arns.apply_secret_arn,
    ]
  }
}

resource "aws_iam_role_policy" "cicd_deploy_github_app_key_guard" {
  for_each = data.aws_iam_policy_document.cicd_deploy_github_app_key_guard

  name   = "github-app-key-guard"
  role   = aws_iam_role.cicd_deploy[each.key].id
  policy = each.value.json
}
