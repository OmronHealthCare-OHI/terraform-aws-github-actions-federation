#!/usr/bin/env bash
# Tests scripts/create-workspace-state.sh against a stub `aws` on PATH: the
# put is create-only (If-None-Match: *), 412 is success, anything else fails,
# and a failing assume-role is retried. Run: tests/create-workspace-state.test.sh
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
script="$here/../scripts/create-workspace-state.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

mkdir -p "$work/bin"
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
case "$1 $2" in
  "sts assume-role")
    n=$(($(cat "$STUB_DIR/assume-count" 2>/dev/null || echo 0) + 1)); echo "$n" >"$STUB_DIR/assume-count"
    if [ "$n" -le "${STUB_ASSUME_FAILURES:-0}" ]; then echo "AccessDenied" >&2; exit 254; fi
    printf 'AKIA\tsecret\ttoken\n' ;;
  "s3api put-object")
    while [ $# -gt 0 ]; do [ "$1" = "--body" ] && cp "$2" "$STUB_DIR/body.json"; shift; done
    case "$STUB_PUT" in
      ok) echo '{"ETag":"\"x\""}' ;;
      exists) echo "An error occurred (PreconditionFailed) when calling the PutObject operation" >&2; exit 254 ;;
      *) echo "An error occurred (AccessDenied) when calling the PutObject operation" >&2; exit 254 ;;
    esac ;;
esac
STUB
chmod +x "$work/bin/aws"

run() {
  rm -f "$work/assume-count" "$work/log" "$work/body.json"
  env PATH="$work/bin:$PATH" STUB_LOG="$work/log" STUB_DIR="$work" STUB_PUT="$1" STUB_ASSUME_FAILURES="${2:-0}" \
    PROVISIONER_ROLE_ARN=arn:aws:iam::123456789012:role/p REPOSITORY_TAG=shared-workload \
    STATE_BUCKET=bucket STATE_REGION=us-west-2 STATE_KEY=env:/test/repo "$script"
}
fail() { echo "FAIL: $*" >&2; exit 1; }

out=$(run ok) || fail "a new state must succeed"
grep -q "Created s3://bucket/env:/test/repo" <<<"$out" || fail "no creation message: $out"
grep -q -- "--if-none-match \*" "$work/log" || fail "the put must carry If-None-Match: *"
grep -q -- "--tags Key=ohi:repository,Value=shared-workload" "$work/log" || fail "the assume must pass the repository tag"
python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); assert s["version"]==4 and s["serial"]==0 and s["resources"]==[] and len(s["lineage"])==36' "$work/body.json" || fail "the body is not an empty state"

out=$(run exists) || fail "412 PreconditionFailed must count as success"
grep -q "already exists" <<<"$out" || fail "no already-exists message: $out"

if run denied >/dev/null 2>&1; then fail "any other put error must fail"; fi

out=$(run ok 2 2>/dev/null) || fail "two failed assumes must be retried"
[ "$(cat "$work/assume-count")" = 3 ] || fail "expected 3 assume attempts"

# Removing a declared workspace must never delete its state (README,
# "Decommissioning a workspace"). terraform test can't see provisioners or
# what a script does, so check the configuration itself: no destroy-time
# provisioner, no Terraform-managed state object, no delete call. The whole
# repository, the vendored module and the examples included; .terraform/
# holds downloaded modules, not ours. A caller's own configuration is the
# caller's to check.
repository="$here/.."
tf_files=()
while IFS= read -r f; do tf_files+=("$f"); done < <(find "$repository" -name '*.tf' -not -path '*/.terraform/*' -not -path '*/.external_modules/*' | sort)
[ "${#tf_files[@]}" -gt 0 ] || fail "found no .tf files under $repository"
scripts=("$here"/../scripts/*.sh)
if grep -n -E 'when[[:space:]]*=[[:space:]]*destroy' "${tf_files[@]}"; then fail "a destroy-time provisioner could delete a workspace state"; fi
if grep -n -E 'resource[[:space:]]+"aws_s3_object(_copy)?"' "${tf_files[@]}"; then fail "a Terraform-managed S3 object would be deleted when its declaration is removed"; fi
if grep -n -E 'delete-object|rm[[:space:]]+s3://' "${tf_files[@]}" "${scripts[@]}"; then fail "nothing here may delete a state object"; fi

echo "create-workspace-state: all tests passed"
