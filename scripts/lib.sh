# Shared helpers, sourced by the other scripts.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Defaults for this project. Override any of them for one run, e.g. ENVIRONMENT=staging ./scripts/bootstrap.sh sync
# (deployments/<env>/*.yaml hold the same values for Git sync).
PROJECT="${PROJECT:-onward}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-west-1}"
DR_REGION="${DR_REGION:-eu-central-1}"
GITHUB_OWNER="${GITHUB_OWNER:-RUYANGA}"
REPO_NAME="${REPO_NAME:-AWS-Onward-Delivery-Photos-Storage-Infra}"
# Reuse AVAILABLE GitHub connections instead of creating onward-<env>-github (skips the console step).
# Connections are Regional, so each Region needs its own:
#   PRIMARY_CONNECTION_ARN=arn:aws:codeconnections:eu-west-1:... DR_CONNECTION_ARN=arn:aws:codeconnections:eu-central-1:... \
#     ./scripts/bootstrap.sh sync
PRIMARY_CONNECTION_ARN="${PRIMARY_CONNECTION_ARN:-}"
DR_CONNECTION_ARN="${DR_CONNECTION_ARN:-}"

BOOTSTRAP_STACK="${PROJECT}-${ENVIRONMENT}-bootstrap"
DR_STACK="${PROJECT}-${ENVIRONMENT}-photos-dr"
PIPELINE_STACK="${PROJECT}-${ENVIRONMENT}-pipeline"
PLATFORM_STACK="${PROJECT}-${ENVIRONMENT}-platform"
ECR_REPOSITORY="${PROJECT}-${ENVIRONMENT}/delivery-photos-app"
TAGS=(Project=onward-delivery-photos "Environment=$ENVIRONMENT" Owner=platform-team
      CostCenter=logistics-proof-of-delivery DataClassification=confidential ManagedBy=cloudformation-gitsync)

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

# out <region> <stack> <output-key>
out() {
  aws cloudformation describe-stacks --region "$1" --stack-name "$2" \
    --query "Stacks[0].Outputs[?OutputKey=='$3'].OutputValue" --output text
}

stack_status() {
  aws cloudformation describe-stacks --region "$1" --stack-name "$2" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo MISSING
}

# Git sync only updates stacks that already exist: create an empty placeholder first.
# placeholder <region> <stack>
placeholder() {
  [[ "$(stack_status "$1" "$2")" != MISSING ]] && return 0
  say "Creating the empty placeholder stack $2 in $1 (Git sync only updates existing stacks)"
  aws cloudformation deploy --region "$1" --stack-name "$2" \
    --template-file "$ROOT/templates/gitsync-placeholder.yaml" --no-fail-on-empty-changeset --tags "${TAGS[@]}"
}

# wait_for_sync <region> <stack> <minutes>: the placeholder is CREATE_COMPLETE; Git sync's
# real template arrives as an update.
wait_for_sync() {
  local s
  say "Waiting for Git sync to build $2 in $1 (up to $3 minutes)"
  for _ in $(seq 1 $(( $3 * 3 ))); do
    s="$(stack_status "$1" "$2")"
    echo "$(date +%T) $s"
    case "$s" in
      UPDATE_COMPLETE) return 0 ;;
      *ROLLBACK*|*FAILED) echo "See the stack events: aws cloudformation describe-stack-events --region $1 --stack-name $2"; return 1 ;;
    esac
    sleep 20
  done
  echo "Timed out waiting for $2"; return 1
}

# deploy_bootstrap <region> <primary|dr> <ConnectionReady> <ExistingConnectionArn> [extra overrides...]
deploy_bootstrap() {
  local region="$1" role="$2" ready="$3" connection="$4"; shift 4
  say "Deploying $BOOTSTRAP_STACK in $region (StackRole=$role, ConnectionReady=$ready $*)"
  # GitHub owner names are case-insensitive, but the repository link only accepts lowercase.
  aws cloudformation deploy --region "$region" --stack-name "$BOOTSTRAP_STACK" \
    --template-file "$ROOT/bootstrap/bootstrap.yaml" --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset --tags "${TAGS[@]}" \
    --parameter-overrides "ProjectName=$PROJECT" "Environment=$ENVIRONMENT" "StackRole=$role" \
      "GitHubOwner=${GITHUB_OWNER,,}" "RepoName=$REPO_NAME" "ConnectionReady=$ready" \
      "ExistingConnectionArn=$connection" "$@"
}
