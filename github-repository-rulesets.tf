# The version tags of every consumer cannot be moved or deleted: a release's
# tag records what was deployed and when, and redeploying it must deploy the
# same commit (github-environments.tf). Creating a tag stays open, which is
# how a release is published; deploy.yml deploys a tag only once it has checked
# that it is on main.
#
# A repository setting, the same from every workspace, so only the workspace
# named by repository_settings_owner manages it, for every consumer of every
# workspace (github-actions-variables.tf).
locals {
  # Release tags as release-drafter writes them ("$RESOLVED_VERSION": 1.2.3).
  # It leaves out the moving tags promote-release.yml pushes (latest, 1, 1.0),
  # which must move.
  release_tag_pattern = "[0-9]*.[0-9]*.[0-9]*"
}

resource "github_repository_ruleset" "release_tags" {
  for_each = local.manages_repository_settings ? toset(local.all_consumer_repositories) : toset([])

  repository  = each.key
  name        = "release-tags"
  target      = "tag"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/tags/${local.release_tag_pattern}"]
      exclude = []
    }
  }

  rules {
    update           = true
    deletion         = true
    non_fast_forward = true
  }
}
