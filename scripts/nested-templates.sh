#!/usr/bin/env bash
# Nested template helper for the platform stack.
#
# CloudFormation reads nested templates from S3, and Git sync does not upload them,
# so CI publishes the nested templates listed below to a content-addressed, write-once prefix:
#
#   s3://<project>-<env>-cfn-templates-<account>-<region>/platform/<version>/<file>.yaml
#
# <version> is the first 12 hex characters of a SHA-256 over every nested template.
# The root template picks the version through NestedTemplatesVersion in
# deployments/<env>/platform.yaml, so a merged change set always points at files that exist.
#
# Usage:
#   ./scripts/nested-templates.sh version   print the version of the working tree
#   ./scripts/nested-templates.sh check     fail if deployments/<env>/platform.yaml is out of date
#   ./scripts/nested-templates.sh publish   upload to S3 (needs AWS credentials)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE_DIR="$ROOT/templates"

# Nested stacks of templates/platform.yaml, one per domain, in deployment order.
# templates/platform.yaml (root) and templates/photos-dr.yaml are deployed by Git sync directly.
NESTED_TEMPLATES=(network.yaml database.yaml edge.yaml storage.yaml application.yaml)
PROJECT="${PROJECT:-onward}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
DEPLOYMENT_FILE="$ROOT/deployments/${ENVIRONMENT}/platform.yaml"
REGION="${AWS_REGION:-eu-west-1}"

version() {
  (cd "$TEMPLATE_DIR" && sha256sum -- "${NESTED_TEMPLATES[@]}") | sha256sum | cut -c1-12
}

pinned_version() {
  sed -nE 's/^[[:space:]]*NestedTemplatesVersion:[[:space:]]*"?([0-9a-f]*)"?.*/\1/p' "$DEPLOYMENT_FILE"
}

check() {
  local want have
  want="$(version)"
  have="$(pinned_version)"
  if [[ "$want" != "$have" ]]; then
    echo "NestedTemplatesVersion in ${DEPLOYMENT_FILE#"$ROOT/"} is '${have}', expected '${want}'."
    echo "A nested template changed. Update the deployment file:"
    echo "  NestedTemplatesVersion: \"${want}\""
    return 1
  fi
  echo "OK: NestedTemplatesVersion ${have} matches the nested templates."
}

publish() {
  local v account bucket file key err
  v="$(version)"
  account="$(aws sts get-caller-identity --query Account --output text)"
  bucket="${PROJECT}-${ENVIRONMENT}-cfn-templates-${account}-${REGION}"
  echo "Publishing nested templates as version ${v} to s3://${bucket}/platform/${v}/"

  for name in "${NESTED_TEMPLATES[@]}"; do
    file="$TEMPLATE_DIR/$name"
    key="platform/${v}/${name}"
    # Write-once: the bucket policy rejects any PutObject without If-None-Match.
    if err="$(aws s3api put-object --region "$REGION" --bucket "$bucket" --key "$key" \
                --body "$file" --content-type application/x-yaml --if-none-match '*' 2>&1 >/dev/null)"; then
      echo "  uploaded  ${key}"
    elif grep -q "PreconditionFailed" <<<"$err"; then
      # Already published by an earlier run: prove the stored copy is identical.
      aws s3 cp --region "$REGION" --only-show-errors "s3://${bucket}/${key}" - | cmp -s - "$file" \
        || { echo "  MISMATCH  ${key} exists with different content"; return 1; }
      echo "  unchanged ${key}"
    else
      echo "$err" >&2
      return 1
    fi
  done
}

case "${1:-}" in
  version) version ;;
  check)   check ;;
  publish) publish ;;
  *) sed -n '2,16p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
