#!/usr/bin/env bash
# Deploy the stacks with the AWS CLI from the same deployments/<env>/*.yaml files Git sync reads,
# for when Git sync can't run yet (GitHub connections still pending approval). Templates,
# parameters and tags are identical, so when `./scripts/bootstrap.sh sync` later turns Git sync on,
# it adopts these stacks without changing them.
#   ./scripts/deploy-direct.sh [all|photos-dr|platform|pipeline]
source "$(dirname "$0")/lib.sh"
target="${1:-all}"
case "$target" in all|photos-dr|platform|pipeline) ;; *) echo "usage: deploy-direct.sh [all|photos-dr|platform|pipeline]"; exit 1 ;; esac

# deploy_file <region> <stack> <deployment-file>
deploy_file() {
  local region="$1" stack="$2" file="$ROOT/deployments/$ENVIRONMENT/$3" template params tags
  template="$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["template-file-path"])' "$file")"
  mapfile -t params < <(python3 -c 'import sys, yaml
for k, v in (yaml.safe_load(open(sys.argv[1])).get("parameters") or {}).items(): print(f"{k}={v}")' "$file")
  mapfile -t tags < <(python3 -c 'import sys, yaml
for k, v in (yaml.safe_load(open(sys.argv[1])).get("tags") or {}).items(): print(f"{k}={v}")' "$file")
  say "Deploying $stack in $region from deployments/$ENVIRONMENT/$3"
  if [[ "$(stack_status "$region" "$stack")" == ROLLBACK_COMPLETE ]]; then
    echo "$stack is ROLLBACK_COMPLETE (failed create); deleting it first"
    aws cloudformation delete-stack --region "$region" --stack-name "$stack"
    aws cloudformation wait stack-delete-complete --region "$region" --stack-name "$stack"
  fi
  aws cloudformation deploy --region "$region" --stack-name "$stack" --template-file "$ROOT/$template" \
    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM CAPABILITY_AUTO_EXPAND --no-fail-on-empty-changeset \
    --parameter-overrides "${params[@]}" --tags "${tags[@]}"
}

require_platform_inputs() {
  local version bucket
  version="$("$ROOT/scripts/nested-templates.sh" version)"
  bucket="$(out "$PRIMARY_REGION" "$BOOTSTRAP_STACK" NestedTemplatesBucketName)"
  aws s3api head-object --region "$PRIMARY_REGION" --bucket "$bucket" --key "platform/$version/edge.yaml" >/dev/null 2>&1 || {
    echo "Nested templates version $version is not in s3://$bucket yet. Push to main so CI publishes it."; exit 1; }
  aws ecr describe-images --region "$PRIMARY_REGION" --repository-name "$ECR_REPOSITORY" \
      --image-ids imageTag=latest >/dev/null 2>&1 || {
    echo "No $ECR_REPOSITORY:latest image yet. Push $APP_REPO_NAME to main so its release workflow pushes one."; exit 1; }
}

require_bundle() {
  local bucket
  bucket="$(out "$PRIMARY_REGION" "$BOOTSTRAP_STACK" DeployBundleBucketName)"
  aws s3api head-object --region "$PRIMARY_REGION" --bucket "$bucket" --key deploy/deploy-bundle.zip >/dev/null 2>&1 || {
    echo "No deploy/deploy-bundle.zip in s3://$bucket yet. Re-run the app's release workflow, then deploy the pipeline."
    return 1; }
}

[[ $target == all || $target == photos-dr ]] && deploy_file "$DR_REGION" "$DR_STACK" photos-dr.yaml
if [[ $target == all || $target == platform ]]; then
  require_platform_inputs
  deploy_file "$PRIMARY_REGION" "$PLATFORM_STACK" platform.yaml
  say "Delivery photos: $(out "$PRIMARY_REGION" "$PLATFORM_STACK" ApplicationUrl)"
fi
if [[ $target == all || $target == pipeline ]]; then
  require_bundle || exit $([[ $target == pipeline ]] && echo 1 || echo 0)
  deploy_file "$PRIMARY_REGION" "$PIPELINE_STACK" pipeline.yaml
  echo "Release pipeline: $(out "$PRIMARY_REGION" "$PIPELINE_STACK" PipelineConsoleUrl)"
fi
