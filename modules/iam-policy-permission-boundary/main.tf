# VENDORED from Luscii/terraform-aws-iam-policy-permission-boundary at
# fb6fe296e74074292bee131482606f2014f84d48 (main after 0.1.0: it adds the
# check that rejects repeated-asterisk wildcards in allowed_actions). MIT
# licensed, see LICENSE. Vendored rather than sourced, because OMRON code
# doesn't take modules from another organisation: it moves to the private
# registry once that serves modules.
#
# Four changes from upstream, each marked "VENDORED change" where it is:
#   - this label: OMRON's terraform-null-label wrapper instead of
#     cloudposse/label/null, so the module takes the same context as the rest
#     of this configuration (the policy's name is the label's id; the tests
#     pass a namespace, which OMRON's label requires);
#   - allowed_actions rejects a service wildcard spelled with "?" too
#     ("iam:?*", "sts:*?", "?*"), which upstream's check lets through
#     (variables.tf). To be fixed upstream as well.
#   - a policy_statements output: the document's statements as configured,
#     which the root module checks its roles' grants against (a document
#     read back as JSON is the mock's under terraform test) (outputs.tf). To be
#     proposed upstream as well.
#   - create_policy: renders the statements without creating the policy, for a
#     caller that shares an account with the policy's owner (several stage
#     workspaces of one configuration in one account); the policy_name and
#     policy_path outputs let it build the ARN (variables.tf, policy.tf,
#     outputs.tf). To be proposed upstream as well.
# Keep everything else equal to upstream, so a later upstream release can be
# diffed in.
module "label" {
  source = "github.com/OmronHealthCare-OHI/terraform-null-label?ref=1.0.0"

  context = var.context
  name    = var.name
}
