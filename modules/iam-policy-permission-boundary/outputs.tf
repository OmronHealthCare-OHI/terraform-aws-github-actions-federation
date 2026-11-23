output "label_context" {
  value       = module.label.context
  description = "Context of the label for subsequent use"
}

output "policy_arn" {
  # VENDORED change (main.tf): null without create_policy.
  value       = var.create_policy ? aws_iam_policy.this[0].arn : null
  description = "ARN of the Permission Boundary policy; null when create_policy is false."
}

# VENDORED change (main.tf): not in upstream. With create_policy false, a
# caller builds the ARN of the policy another configuration created from these
# two: arn:aws:iam::<account>:policy<policy_path><policy_name>.
output "policy_name" {
  value       = module.label.id
  description = "Name of the Permission Boundary policy, whether or not this module creates it."
}

output "policy_path" {
  value       = local.boundary_path
  description = "Path of the Permission Boundary policy (/boundaries/), whether or not this module creates it."
}

output "policy_document_json" {
  value       = data.aws_iam_policy_document.this.json
  description = "JSON of the Permission Boundary policy document"
}

# VENDORED change (main.tf): not in upstream. The root module's coverage
# check reads it (permission-boundaries.tf); dropping it in an upstream update
# breaks that check.
output "policy_statements" {
  value       = data.aws_iam_policy_document.this.statement
  description = "The Permission Boundary policy's statements, as configured (effect, actions, resources, …): what a caller checks coverage against. Known at plan, unlike a document read back from the provider."
}
