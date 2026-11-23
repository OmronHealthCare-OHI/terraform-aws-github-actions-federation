#!/usr/bin/env bash
# Creates one empty Terraform workspace state, create-only (workspaces.tf,
# CLF-96). Run by terraform_data.workspace_state's local-exec in the baseline's
# gated apply, with the deploy role's credentials in the environment.
#
#   PROVISIONER_ROLE_ARN  shared-cicd-infrastructure's workspace provisioner
#   REPOSITORY_TAG        the caller's own ohi:repository tag, passed unchanged:
#                         the provisioner's trust requires the two to be equal
#   STATE_BUCKET, STATE_REGION, STATE_KEY
#                         the state object, env:/<workspace>/<repo>
#
# The put carries If-None-Match: *, which the state bucket requires of the
# provisioner. 412 PreconditionFailed means the state already exists: that is
# success, and the existing state is untouched. Any other failure fails the
# apply.
set -euo pipefail

: "${PROVISIONER_ROLE_ARN:?}" "${REPOSITORY_TAG:?}" "${STATE_BUCKET:?}" "${STATE_REGION:?}" "${STATE_KEY:?}"

# The grant to assume the provisioner may be new in this same apply, and IAM
# is eventually consistent: retry the assume for up to about a minute.
body=$(mktemp)
errors=$(mktemp)
trap 'rm -f "$body" "$errors"' EXIT

credentials=""
for attempt in 1 2 3 4 5 6; do
  if credentials=$(aws sts assume-role \
    --role-arn "$PROVISIONER_ROLE_ARN" \
    --role-session-name "create-workspace-state" \
    --tags "Key=ohi:repository,Value=${REPOSITORY_TAG}" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
    --output text 2>"$errors"); then
    break
  fi
  echo "assume-role attempt ${attempt} failed: $(cat "$errors")" >&2
  credentials=""
  sleep $((attempt * 3))
done
[ -n "$credentials" ] || { echo "Could not assume ${PROVISIONER_ROLE_ARN}." >&2; exit 1; }

read -r AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN <<<"$credentials"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
unset AWS_PROFILE

# A valid empty state: no resources, serial 0, its own lineage. The
# terraform_version is the lowest any reader may be, so no Terraform refuses
# it as newer than itself; the first apply rewrites it with its own.
lineage=$(python3 -c 'import uuid; print(uuid.uuid4())')
printf '{"version":4,"terraform_version":"1.0.0","serial":0,"lineage":"%s","outputs":{},"resources":[],"check_results":null}\n' "$lineage" >"$body"

# No encryption header: the bucket's default, the state key, applies (the
# bucket refuses an explicit one naming any other key).
if output=$(aws s3api put-object \
  --region "$STATE_REGION" \
  --bucket "$STATE_BUCKET" \
  --key "$STATE_KEY" \
  --body "$body" \
  --content-type application/json \
  --if-none-match '*' 2>&1); then
  echo "Created s3://${STATE_BUCKET}/${STATE_KEY}."
elif grep -q 'PreconditionFailed' <<<"$output"; then
  echo "s3://${STATE_BUCKET}/${STATE_KEY} already exists; left as it is."
else
  echo "Creating s3://${STATE_BUCKET}/${STATE_KEY} failed: ${output}" >&2
  exit 1
fi
