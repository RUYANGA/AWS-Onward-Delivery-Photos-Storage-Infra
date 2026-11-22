#!/usr/bin/env bash
# Build (or rebuild) everything from this repository.
#   ./scripts/bootstrap.sh connection   # GitHub connections, Git sync roles, ECR, deploy-bundle bucket,
#                                       # GitHub Actions roles (both Regions)
#     -> authorise both connections once in the console (AWS requires a person to approve GitHub access)
#     -> set the Actions variables in both repositories and push both to main:
#        infra CI publishes the nested templates, app CI pushes the first image
#   ./scripts/bootstrap.sh sync         # Git sync builds, in order:
#                                       #   onward-dev-photos-dr  (eu-central-1, replica bucket)
#                                       #   onward-dev-platform   (eu-west-1, starts the :latest image)
#                                       #   onward-dev-pipeline   (eu-west-1, CodeDeploy blue/green releases)
# With existing AVAILABLE GitHub connections, skip the first step and the console:
#   PRIMARY_CONNECTION_ARN=<arn> DR_CONNECTION_ARN=<arn> ./scripts/bootstrap.sh sync
source "$(dirname "$0")/lib.sh"
phase="${1:?usage: bootstrap.sh connection|sync}"
case "$phase" in connection|sync) ;; *) echo "unknown phase: $phase (connection|sync)"; exit 1 ;; esac

# The primary bootstrap creates the GitHub OIDC provider unless the account already has one
# that this stack does not own.
oidc_overrides() {
  local arn owned
  arn="$(aws iam list-open-id-connect-providers --query \
    "OpenIDConnectProviderList[?ends_with(Arn, 'token.actions.githubusercontent.com')].Arn | [0]" --output text)"
  owned="$(aws cloudformation describe-stack-resource --region "$PRIMARY_REGION" --stack-name "$BOOTSTRAP_STACK" \
    --logical-resource-id GitHubOidcProvider --query StackResourceDetail.PhysicalResourceId --output text 2>/dev/null || true)"
  if [[ "$arn" != None && -n "$arn" && "$owned" != "$arn" ]]; then
    echo "CreateGitHubOidcProvider=false" "ExistingGitHubOidcProviderArn=$arn"
  else
    echo "CreateGitHubOidcProvider=true"
  fi
}

# connection_ready <region> <override-arn>: prints the connection ARN if it is AVAILABLE
connection_ready() {
  local arn="$2" status
  [[ -z "$arn" ]] && arn="$(out "$1" "$BOOTSTRAP_STACK" ConnectionArn 2>/dev/null || true)"
  [[ -z "$arn" || "$arn" == None ]] && { echo "No GitHub connection in $1. Run: ./scripts/bootstrap.sh connection" >&2; return 1; }
  status="$(aws codeconnections get-connection --region "$1" --connection-arn "$arn" \
    --query Connection.ConnectionStatus --output text)"
  [[ "$status" == AVAILABLE ]] || {
    echo "Connection $arn is $status, not AVAILABLE. Authorise it: Console > Developer Tools > Settings > Connections" >&2
    return 1
  }
  echo "$arn"
}

# shellcheck disable=SC2046  # oidc_overrides prints several KEY=VALUE words on purpose
if [[ $phase == connection ]]; then
  deploy_bootstrap "$DR_REGION" dr false "$DR_CONNECTION_ARN"
  deploy_bootstrap "$PRIMARY_REGION" primary false "$PRIMARY_CONNECTION_ARN" PipelineReady=false $(oidc_overrides)
  say "Next steps"
  [[ -z "$DR_CONNECTION_ARN$PRIMARY_CONNECTION_ARN" ]] && \
    echo "1. Authorise both connections: Console > Developer Tools > Settings > Connections > $PROJECT-$ENVIRONMENT-github > Update pending connection (in $DR_REGION and $PRIMARY_REGION)."
  echo "2. In GitHub, give the AWS Connector app access to $REPO_NAME."
  echo "3. In $REPO_NAME, set the Actions variable AWS_ROLE_ARN=$(out "$PRIMARY_REGION" "$BOOTSTRAP_STACK" InfraCiRoleArn), then push to main."
  echo "4. In $APP_REPO_NAME, set the Actions variables AWS_REGION=$PRIMARY_REGION,"
  echo "   ECR_REPOSITORY=$ECR_REPOSITORY and AWS_ROLE_ARN=$(out "$PRIMARY_REGION" "$BOOTSTRAP_STACK" AppCiRoleArn), then push to main."
  echo "Then run: ./scripts/bootstrap.sh sync"
  exit 0
fi

# ---------------------------------------------------------------------------- sync
dr_connection="$(connection_ready "$DR_REGION" "$DR_CONNECTION_ARN")"
primary_connection="$(connection_ready "$PRIMARY_REGION" "$PRIMARY_CONNECTION_ARN")"
[[ -n "$DR_CONNECTION_ARN" ]] || dr_connection=""          # created by the bootstrap: keep it managed
[[ -n "$PRIMARY_CONNECTION_ARN" ]] || primary_connection=""

# The platform root stack reads its nested templates from S3 (published by infra CI).
version="$("$ROOT/scripts/nested-templates.sh" version)"
bucket="$(out "$PRIMARY_REGION" "$BOOTSTRAP_STACK" NestedTemplatesBucketName)"
aws s3api head-object --region "$PRIMARY_REGION" --bucket "$bucket" --key "platform/$version/edge.yaml" >/dev/null 2>&1 || {
  echo "Nested templates version $version is not in s3://$bucket yet."
  echo "Push this commit to main (or open a pull request) so CI publishes it, then re-run."
  exit 1
}

# The pipeline releases the image the app's GitHub Actions pushed as :latest.
aws ecr describe-images --region "$PRIMARY_REGION" --repository-name "$ECR_REPOSITORY" \
    --image-ids imageTag=latest >/dev/null 2>&1 || {
  echo "No $ECR_REPOSITORY:latest image yet. Push $APP_REPO_NAME to main so its CI pushes one, then re-run."
  exit 1
}

# 1. Recovery Region first: replication needs the replica bucket to exist.
placeholder "$DR_REGION" "$DR_STACK"
deploy_bootstrap "$DR_REGION" dr true "$dr_connection"
wait_for_sync "$DR_REGION" "$DR_STACK" 15

# 2. Platform: network, storage, database, application and edge (nested stacks).
#    The service starts with the :latest image; after that CodeDeploy owns the running image.
placeholder "$PRIMARY_REGION" "$PLATFORM_STACK"
deploy_bootstrap "$PRIMARY_REGION" primary true "$primary_connection" PipelineReady=false $(oidc_overrides)
wait_for_sync "$PRIMARY_REGION" "$PLATFORM_STACK" 45

# 3. Release pipeline. It imports the platform's exports and releases the deployment bundle
#    (taskdef.json + appspec.yaml) the app's CI builds from the live task definition.
bundle_bucket="$(out "$PRIMARY_REGION" "$BOOTSTRAP_STACK" DeployBundleBucketName)"
if ! aws s3api head-object --region "$PRIMARY_REGION" --bucket "$bundle_bucket" --key deploy/deploy-bundle.zip >/dev/null 2>&1; then
  say "The platform is up: $(out "$PRIMARY_REGION" "$PLATFORM_STACK" ApplicationUrl)"
  echo "No deployment bundle yet (the app's CI can only build it once the task definition exists)."
  echo "Re-run the app's release workflow (Actions > release > Run workflow on main), then run this script again."
  exit 0
fi
placeholder "$PRIMARY_REGION" "$PIPELINE_STACK"
deploy_bootstrap "$PRIMARY_REGION" primary true "$primary_connection" PipelineReady=true $(oidc_overrides)
wait_for_sync "$PRIMARY_REGION" "$PIPELINE_STACK" 15

say "Delivery photos: $(out "$PRIMARY_REGION" "$PLATFORM_STACK" ApplicationUrl)"
echo "Release pipeline: $(out "$PRIMARY_REGION" "$PIPELINE_STACK" PipelineConsoleUrl)"
echo "From now on every merge to the app's main branch is released blue/green by CodeDeploy."
