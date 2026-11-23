#!/usr/bin/env bash
# Delete the environment after a demo; rebuild later with ./scripts/bootstrap.sh sync.
# Photo buckets, the replica, the database backup vaults, the ECR repository and the template/deploy-bundle
# buckets are retained on purpose (evidence and release history); RDS takes a final snapshot.
source "$(dirname "$0")/lib.sh"
read -r -p "Delete $PIPELINE_STACK, $PLATFORM_STACK and $DR_STACK? Type the environment name to confirm: " ok
[[ "$ok" == "$ENVIRONMENT" ]] || { echo "Cancelled."; exit 1; }

say "Stopping Git sync first so it does not recreate the stacks"
for region_role in "$PRIMARY_REGION primary" "$DR_REGION dr"; do
  set -- $region_role
  aws cloudformation deploy --region "$1" --stack-name "$BOOTSTRAP_STACK" \
    --template-file "$ROOT/bootstrap/bootstrap.yaml" --capabilities CAPABILITY_NAMED_IAM \
    --no-fail-on-empty-changeset --parameter-overrides ConnectionReady=false
done

delete() {  # delete <region> <stack>
  say "Deleting $2 in $1"
  aws cloudformation delete-stack --region "$1" --stack-name "$2"
  aws cloudformation wait stack-delete-complete --region "$1" --stack-name "$2"
}
db_protected="$(aws rds describe-db-instances --region "$PRIMARY_REGION" \
  --db-instance-identifier "$PROJECT-$ENVIRONMENT-photos-db" --query 'DBInstances[0].DeletionProtection' --output text 2>/dev/null || echo False)"
if [[ "$db_protected" == True ]]; then
  echo "The database has deletion protection. Set DbDeletionProtection: \"false\" in deployments/$ENVIRONMENT/platform.yaml,"
  echo "merge, wait for Git sync, then run this script again."; exit 1
fi
# The pipeline imports the platform's exports, so it goes first.
delete "$PRIMARY_REGION" "$PIPELINE_STACK"
delete "$PRIMARY_REGION" "$PLATFORM_STACK"
delete "$DR_REGION" "$DR_STACK"
echo "Deleted. The bootstrap stacks (connections, roles, ECR) remain and cost almost nothing."
