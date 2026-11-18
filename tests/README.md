# Executable scenarios

`terraform test` with mocked `aws`, `tls` and `github` providers, against a
fixture account (`account_key = "cicd"`, `account_id = "123456789012"`) with the
CICD account's consumers and settings as shared-workload sets them, copied into
the test's `variables` block. Run from the repository root:

```sh
terraform init -backend=false
terraform test
terraform -chdir=modules/iam-policy-permission-boundary init -backend=false
terraform -chdir=modules/iam-policy-permission-boundary test
tests/create-workspace-state.test.sh
```

`terraform test` runs only the `tests/` beside the directory it is given, so the
vendored permission-boundary module's own tests run from its directory. They are
what shows a later upstream release, diffed in, still behaves.

Mocked providers return placeholder values for anything computed (role ARNs,
rendered policy JSON), so the assertions stay on what a plan knows: names,
paths, environments, keys.

The script tests `scripts/create-workspace-state.sh` against a stub `aws` on
`PATH`: the put is create-only, 412 is success. It also checks that nothing in
this repository can delete a workspace state.
