#!/usr/bin/env bash
# Live review helper: run one client check at a time, e.g.
#   ./scripts/live-review-checks.sh storage-private
# Requires: AWS CLI v2, curl, jq, and credentials for the Onward account.
set -euo pipefail

PROJECT="${PROJECT:-onward}"
ENVIRONMENT="${ENVIRONMENT:-dev}"
PRIMARY_REGION="${PRIMARY_REGION:-eu-west-1}"
DR_REGION="${DR_REGION:-eu-central-1}"
STACK="${PROJECT}-${ENVIRONMENT}-platform"

out() {
  aws cloudformation describe-stacks --region "$PRIMARY_REGION" --stack-name "$STACK" \
    --query "Stacks[0].Outputs[?OutputKey=='$1'].OutputValue" --output text
}
say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }

APP_URL="$(out ApplicationUrl)"
BUCKET="$(out PhotoBucketName)"
REPLICA="$(out ReplicaBucketName)"
ALB="$(out LoadBalancerDnsName)"
DB_HOST="$(out DatabaseEndpoint)"
CLUSTER="$(out ClusterName)"
SERVICE="$(out ServiceName)"

latest_key() {
  aws s3api list-objects-v2 --region "$PRIMARY_REGION" --bucket "$BUCKET" --prefix media/originals/ \
    --query 'sort_by(Contents,&LastModified)[-1].Key' --output text
}

case "${1:-help}" in
  urls)
    say "Public entry point";      echo "$APP_URL"
    say "Photo bucket / replica";  echo "$BUCKET  ->  $REPLICA"
    ;;

  storage-private)
    KEY="$(latest_key)"
    say "1. Direct S3 request is refused (expect 403)"
    curl -s -o /dev/null -w "%{http_code}\n" "https://${BUCKET}.s3.${PRIMARY_REGION}.amazonaws.com/${KEY}"
    say "2. Same photo through Onward's CloudFront domain (expect 200)"
    curl -s -o /dev/null -w "%{http_code}\n" "${APP_URL}/${KEY}"
    say "3. Headers that stop other sites embedding the photo"
    curl -sI "${APP_URL}/${KEY}" | grep -iE "cross-origin-resource-policy|x-robots-tag|x-cache|cache-control"
    say "4. Bucket public access block"
    aws s3api get-public-access-block --region "$PRIMARY_REGION" --bucket "$BUCKET"
    ;;

  alb-locked)
    say "Direct request to the ALB without CloudFront's header (expect 403 or timeout)"
    curl -s -m 8 -o /dev/null -w "%{http_code}\n" "http://${ALB}/" || echo "blocked by security group (timeout)"
    ;;

  db-private)
    say "RDS is not publicly accessible"
    aws rds describe-db-instances --region "$PRIMARY_REGION" \
      --query "DBInstances[?Endpoint.Address=='${DB_HOST}'].[PubliclyAccessible,MultiAZ,BackupRetentionPeriod,DeletionProtection]" --output table
    say "Endpoint resolves to a private address"
    getent hosts "$DB_HOST" || nslookup "$DB_HOST" || true
    say "Connection attempt from this machine (expect timeout)"
    timeout 6 bash -c "</dev/tcp/${DB_HOST}/5432" && echo "UNEXPECTED: reachable" || echo "not reachable from the internet"
    ;;

  no-photo-in-db)
    say "The photos table stores keys, versions and checksums only (no bytea column)"
    echo "Run from the review laptop is impossible by design; show this query in the RDS Query Editor"
    echo "or from an ECS Exec-enabled debug task:"
    echo "  SELECT column_name, data_type FROM information_schema.columns WHERE table_name='photos';"
    ;;

  credentials)
    say "Task definition pulls DB credentials from Secrets Manager (valueFrom, not value)"
    TD="$(aws ecs describe-services --region "$PRIMARY_REGION" --cluster "$CLUSTER" --services "$SERVICE" \
      --query 'services[0].taskDefinition' --output text)"
    aws ecs describe-task-definition --region "$PRIMARY_REGION" --task-definition "$TD" \
      --query 'taskDefinition.containerDefinitions[0].secrets' --output table
    ;;

  s3-recover)
    KEY="$(latest_key)"
    say "Delete the current object (creates a delete marker only)"
    aws s3api delete-object --region "$PRIMARY_REGION" --bucket "$BUCKET" --key "$KEY"
    curl -s -o /dev/null -w "after delete (CloudFront may still serve cache): %{http_code}\n" "${APP_URL}/${KEY}"
    say "Versions now present"
    aws s3api list-object-versions --region "$PRIMARY_REGION" --bucket "$BUCKET" --prefix "$KEY" \
      --query '{Versions:Versions[].[VersionId,IsLatest],DeleteMarkers:DeleteMarkers[].[VersionId,IsLatest]}'
    PREV="$(aws s3api list-object-versions --region "$PRIMARY_REGION" --bucket "$BUCKET" --prefix "$KEY" \
      --query 'Versions[0].VersionId' --output text)"
    say "Restore by copying the previous version back on top (no version is ever deleted)"
    aws s3api copy-object --region "$PRIMARY_REGION" --bucket "$BUCKET" --key "$KEY" \
      --copy-source "${BUCKET}/${KEY}?versionId=${PREV}" \
      --metadata-directive COPY --storage-class INTELLIGENT_TIERING >/dev/null
    aws s3api head-object --region "$PRIMARY_REGION" --bucket "$BUCKET" --key "$KEY" --query '[VersionId,ContentLength]'
    say "Permanent deletion is denied by the bucket policy (expect AccessDenied)"
    aws s3api delete-object --region "$PRIMARY_REGION" --bucket "$BUCKET" --key "$KEY" --version-id "$PREV" \
      || echo "denied as designed"
    ;;

  replica)
    KEY="$(latest_key)"
    say "Replication status on the primary object"
    aws s3api head-object --region "$PRIMARY_REGION" --bucket "$BUCKET" --key "$KEY" --query ReplicationStatus
    say "Same object in ${DR_REGION}"
    aws s3api head-object --region "$DR_REGION" --bucket "$REPLICA" --key "$KEY" \
      --query '[ReplicationStatus,StorageClass,ContentLength,LastModified]'
    ;;

  kill-task)
    say "Stop one running task; ECS replaces it while the other keeps serving"
    TASK="$(aws ecs list-tasks --region "$PRIMARY_REGION" --cluster "$CLUSTER" --service-name "$SERVICE" \
      --query 'taskArns[0]' --output text)"
    aws ecs stop-task --region "$PRIMARY_REGION" --cluster "$CLUSTER" --task "$TASK" --reason "live review: container loss" >/dev/null
    for i in $(seq 1 12); do
      printf '%s  HTTP %s\n' "$(date +%T)" "$(curl -s -o /dev/null -w '%{http_code}' "${APP_URL}/healthz")"; sleep 5
    done
    ;;

  az-spread)
    say "Running tasks per Availability Zone"
    aws ecs describe-tasks --region "$PRIMARY_REGION" --cluster "$CLUSTER" \
      --tasks $(aws ecs list-tasks --region "$PRIMARY_REGION" --cluster "$CLUSTER" --service-name "$SERVICE" --query 'taskArns' --output text) \
      --query 'tasks[].[availabilityZone,lastStatus,healthStatus]' --output table
    ;;

  db-failover)
    say "Force a Multi-AZ failover (simulates loss of the primary DB's AZ)"
    aws rds reboot-db-instance --region "$PRIMARY_REGION" --db-instance-identifier "${PROJECT}-${ENVIRONMENT}-photos-db" --force-failover \
      --query 'DBInstance.DBInstanceStatus'
    ;;

  *)
    echo "usage: $0 {urls|storage-private|alb-locked|db-private|no-photo-in-db|credentials|s3-recover|replica|kill-task|az-spread|db-failover}"
    ;;
esac
