# Recovery runbook: Onward delivery photos

| Situation | Data at risk | Recovery point | Procedure |
|---|---|---|---|
| Photo deleted in the app | none | 0 | App: **Deleted photos → Restore photo** |
| Object deleted in S3 | none | 0 | [Restore an S3 object](#restore-an-s3-object) |
| Row changed or deleted in the database | changes since the restore point | about 5 min | [Point-in-time restore](#point-in-time-restore-of-the-database) |
| Container crash or AZ loss | none | 0 | Automatic (ECS replacement, RDS failover) |
| Primary bucket lost | none | minutes | [Recover from the replica](#primary-region-or-bucket-lost) |
| Database lost or a restore older than 7 days needed | changes since the last daily backup | up to 24 h | [Restore from AWS Backup](#restore-the-database-from-aws-backup) |
| Primary Region lost | database changes since the last daily backup copy (photos and their sidecars are safe) | up to 24 h for the database, minutes for photos | [Recover in the recovery Region](#primary-region-or-bucket-lost) |

## Restore an S3 object

Deleting an object only adds a delete marker. Permanent version deletes are denied by the bucket policy, so recovery copies the last good version back on top.

```bash
B=<photo bucket>; K=<object key>
aws s3api list-object-versions --bucket "$B" --prefix "$K"
aws s3api copy-object --bucket "$B" --key "$K" \
  --copy-source "$B/$K?versionId=<last good VersionId>" \
  --metadata-directive COPY --storage-class INTELLIGENT_TIERING
```

## Point-in-time restore of the database

1. Restore to a new instance (the original keeps running):

```bash
aws rds restore-db-instance-to-point-in-time --source-db-instance-identifier onward-dev-photos-db \
  --target-db-instance-identifier onward-dev-photos-db-pitr --restore-time <UTC ISO time before the error> \
  --db-subnet-group-name <subnet group from the platform stack> --vpc-security-group-ids <db SG> \
  --no-publicly-accessible
```

2. Export the affected rows from the restored instance and insert or update them in the live database.
3. Delete the temporary instance.

## Restore the database from AWS Backup

AWS Backup takes a backup of the database every day at 05:00 UTC and keeps it for 35 days
(`DbBackupPlanRetentionDays`) in `onward-dev-db-backups-eu-west-1`, with a copy in
`onward-dev-db-backups-eu-central-1`. Use it when the point-in-time window (7 days) is not
enough, or when eu-west-1 is unavailable.

1. List the recovery points (use `--region eu-central-1` and the eu-central-1 vault if the primary Region is lost):

```bash
aws backup list-recovery-points-by-backup-vault --region eu-west-1 \
  --backup-vault-name onward-dev-db-backups-eu-west-1 \
  --query 'RecoveryPoints[].[CreationDate,RecoveryPointArn,Status]' --output table
```

2. Restore one to a new instance (the original keeps running). The role is the stack's backup role
   (`onward-dev-db-backup-eu-west-1`); the subnet group and security group come from the platform stack:

```bash
aws backup start-restore-job --region eu-west-1 \
  --recovery-point-arn <RecoveryPointArn> \
  --iam-role-arn arn:aws:iam::<account>:role/onward-dev-db-backup-eu-west-1 \
  --metadata '{"DBInstanceIdentifier":"onward-dev-photos-db-restore","DBSubnetGroupName":"<subnet group>","VpcSecurityGroupIds":"[\"<db SG>\"]","MultiAZ":"false","PubliclyAccessible":"false"}'
aws backup describe-restore-job --region eu-west-1 --restore-job-id <RestoreJobId>
```

3. Copy the rows you need into the live database, as in the point-in-time restore, then delete the temporary instance.

## Primary Region or bucket lost

Every original, thumbnail and `meta/*.json` sidecar is in `onward-dev-photos-replica-<account>-eu-central-1`.

1. If only the bucket was lost, copy objects back from the replica: `aws s3 sync s3://<replica> s3://<new primary> --source-region eu-central-1`.
2. If the Region was lost, deploy the platform template in a healthy Region from this repository (a new deployment file with the replica as the photo source, or a sync of the replica into the new stack's bucket).
3. Restore the database from the latest copy in `onward-dev-db-backups-eu-central-1` ([Restore from AWS Backup](#restore-the-database-from-aws-backup)) into the new stack's data subnets. If no usable copy exists, or to add photos uploaded after it, rebuild the catalogue from the sidecars with the app repository's management command (run it from the app container or a checkout with the database variables set):

```bash
python manage.py rebuild_catalogue --bucket <bucket holding the photos> --dry-run
python manage.py rebuild_catalogue --bucket <bucket holding the photos>
python manage.py rebuild_catalogue --bucket <bucket holding the photos> --report-orphans
```

4. Point the deployment file's `ImageTag` at the last known good image (its git-SHA tag; a new stack starts from `ImageTag`) and confirm with `scripts/live-review-checks.sh`.

**Not protected across Regions:** the running application, ALB and CloudFront origin. These are rebuilt from the repositories. The database is protected by the daily backup copy in eu-central-1 (up to 24 hours of changes at risk) and by the sidecars, which `rebuild_catalogue` reads. Objects uploaded in the last few minutes before an outage may not have replicated yet; S3 Replication Time Control would bound this at 15 minutes for extra cost.
