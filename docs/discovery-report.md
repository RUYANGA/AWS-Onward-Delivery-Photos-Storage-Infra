# Discovery Report: Storing and Serving Delivery Photos for Onward Logistics

| | |
|---|---|
| **Lab** | Storing and Serving Delivery Photos for Onward Logistics |
| **Name** | Merci RUYANGA |
| **Date** | 22 November 2026 |
| **Client** | Onward Logistics (see the Client Profile) |

## 1. What I found

### The client's need

Onward needs a safe, permanent record of every delivery photo its riders take, so that anyone
can later prove a parcel was delivered, and that proof must never be lost, altered or exposed to
people who should not see it.

### Solutions that exist

| Solution | How it works | Trade-off for this client |
|---|---|---|
| Photos stored inside the database | Each image is saved as binary data in a table row next to the delivery details. | **Strength:** one system to back up, and the photo and its record always stay together. **Weakness:** the database grows fast, becomes slow and expensive, and every photo view loads the database that the whole app depends on. |
| Files on the application server's disk or a shared file system (e.g. Amazon EFS) | The app writes each photo to a folder on a server or a network drive and serves it itself. | **Strength:** simple and familiar, little code. **Weakness:** the app serves every image, a deleted or overwritten file is gone, and protecting it against a lost data centre needs extra work. |
| Object storage with a CDN in front (Amazon S3 + CloudFront) | Photos go to a private S3 bucket; the database keeps only the details and a pointer; CloudFront delivers images to viewers from locations close to them. | **Strength:** very durable, cheap per GB, keeps every version and copies itself to another Region, and the app stops carrying image traffic. **Weakness:** more moving parts (bucket, CDN, permissions) to design and secure correctly. |

### What happens with no solution

A delivery photo is Onward's evidence. Without it, a customer who says "my parcel never arrived"
cannot be answered, so Onward pays the refund or the merchant's claim, and loses the merchant's
trust as well. If photos sit on one server or in one Region, a single mistake or outage can wipe
out all of that evidence at once:

- **Code Spaces (2014):** an attacker who got into the company's AWS console deleted its data
  and backups, which lived in the same account. The company could not recover and closed within
  days.
- **GitLab (2017):** an engineer deleted the production database by mistake, and five backup
  methods turned out not to work. About six hours of customer data was lost.

Photos can also show addresses, homes and people. If a bucket is left public, Onward faces legal
exposure under data-protection law (GDPR Article 32 requires "appropriate technical measures") and
damage to customer trust.

### Sources

- InfoWorld, "Murder in the Amazon cloud" (Code Spaces, 2014): https://www.infoworld.com/article/2608076/murder-in-the-amazon-cloud.html
- GitLab, "Postmortem of database outage of January 31": https://about.gitlab.com/blog/2017/02/10/postmortem-of-database-outage-of-january-31/
- GDPR Article 32, Security of processing: https://gdpr-info.eu/art-32-gdpr/
- AWS, Retaining multiple versions of objects with S3 Versioning: https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html
- AWS, Replicating objects within and across Regions: https://docs.aws.amazon.com/AmazonS3/latest/userguide/replication.html
- AWS, Restricting access to an Amazon S3 origin (Origin Access Control): https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/private-content-restricting-access-to-s3.html
- AWS Well-Architected Framework, Reliability Pillar: https://docs.aws.amazon.com/wellarchitected/latest/reliability-pillar/welcome.html
- AWS Pricing Calculator, cost estimate for this design: https://calculator.aws/#/estimate?id=b6617eb4f66753a080f5b30314c770496b8a8af2

## 2. The business value of my solution

### My chosen approach

I chose **object storage with a CDN in front**: photos in a private, versioned S3 bucket that
copies itself to a second Region, delivered through CloudFront, with the delivery details in a
managed PostgreSQL database. It fits Onward better than the other options because the photos are
evidence: S3 keeps every version, nobody can permanently erase one, and a full copy sits in
another country in case the main Region fails. The original file is stored unchanged with a
checksum, so Onward can show it has not been edited. Storage cost stays low as the number of
photos grows, and the application only handles uploads and pages, so it stays fast for riders.

### Services I will use

| Service | The job it does | Why this service, used this way |
|---|---|---|
| Amazon S3 (primary, eu-west-1) | Stores every original photo, thumbnail and details file. | Versioning, Block Public Access and a bucket policy that denies permanent deletes keep the evidence safe; Intelligent-Tiering lowers cost for old photos nobody looks at. |
| S3 Cross-Region Replication (eu-central-1) | Copies every photo to a replica bucket in another Region. | Protects against losing the bucket or the whole Region; deletes are not replicated, and the copy uses Glacier Instant Retrieval because it is rarely read. |
| Amazon CloudFront | The only public address; serves photos and pages over HTTPS. | Fast for viewers everywhere, and Origin Access Control means only CloudFront can read the bucket. |
| AWS WAF + Application Load Balancer | Passes page requests to the app, only when they come from Onward's CloudFront. | Nobody can bypass CloudFront to reach the app directly; the ALB also spreads traffic across two data centres. |
| Amazon ECS on Fargate | Runs the Django app (2 to 6 containers in two Availability Zones). | No servers to patch; a failed container is replaced automatically and capacity grows with demand. |
| Amazon RDS for PostgreSQL (Multi-AZ) | Holds the photo catalogue: reference, rider, merchant, city, file location, checksum. | Managed backups and point-in-time restore; a standby in a second zone takes over if the first fails. |
| AWS Backup | Backs up the database every day, keeps it 35 days and copies it to Frankfurt. | The catalogue survives the loss of the main Region and can be restored further back than the 7-day point-in-time window. |
| AWS Secrets Manager and SSM Parameter Store | Hold the database password and the app settings. | No credentials in the code, image or repository; RDS rotates the password itself. |
| VPC with private subnets and VPC endpoints | Keeps the app and database off the internet. | The database is unreachable from outside, and the app reaches AWS services privately. |
| AWS CloudFormation (Git sync) | Builds and changes all of the above from the repository. | Every change is a reviewed pull request, and the whole system can be rebuilt from Git. |
| GitHub Actions, Amazon ECR, CodePipeline, CodeDeploy | Test, scan and release new app versions blue/green. | Customers never see a half-released version, and a bad release rolls back by itself. |

### Estimated cost

Full estimate in the AWS Pricing Calculator:
[calculator.aws estimate](https://calculator.aws/#/estimate?id=b6617eb4f66753a080f5b30314c770496b8a8af2)

**About USD 217 a month (about USD 2,600 a year)**, on-demand prices, without free tiers.
Assumptions: about 30,000 photos a month at about 3 MB each, storage taken at month 12
(about 1.1 TB), and about 100 GB a month delivered to viewers.

| Service | Region | USD a month |
|---|---|---|
| VPC interface endpoints (5 in 2 AZs) and 2 public IPv4 addresses | Ireland | 87.80 |
| ECS on Fargate (2 tasks, 0.5 vCPU / 1 GB) | Ireland | 36.04 |
| RDS for PostgreSQL (db.t4g.micro Multi-AZ, 20 GB gp3) | Ireland | 30.63 |
| Application Load Balancer | Ireland | 18.63 |
| CloudFront | Global | 11.74 |
| S3 photo bucket (Intelligent-Tiering, 1.1 TB) | Ireland | 11.42 |
| S3 replica (Glacier Instant Retrieval) | Frankfurt | 7.75 |
| AWS WAF | Ireland | 6.30 |
| CloudWatch (logs and alarms) | Ireland | 3.37 |
| Secrets Manager, CodePipeline, ECR | Ireland | 1.45 |
| **Calculator total** | | **215.13** |
| Replication transfer Ireland to Frankfurt (90 GB, not in the calculator) | | 1.80 |
| **Total** | | **216.93** |

Storing a photo in both Regions costs about USD 0.0006 a month, so growth in photos adds little.
Most of the bill is always-on infrastructure; the largest line, the VPC endpoints, is the price
of running the app with no route to the internet. CloudFront's free tier would remove about
USD 12, and a Savings Plan or a Reserved Instance would cut Fargate and RDS further.

### Who benefits, and how I will know

*Roles below should be checked against the stakeholders named in the Client Profile.*

| Stakeholder | Benefit | How I would know |
|---|---|---|
| Riders | Upload a photo quickly at the door and move on. | Upload completes in a few seconds; upload errors (4xx/5xx) stay near zero in the ALB metrics. |
| Customer support / claims team | Find the proof for any delivery and settle "not received" disputes quickly. | Search by delivery reference returns the photo in seconds; fewer refunds paid for lack of evidence. |
| Merchants and customers | See trustworthy proof that their parcel arrived. | Fewer delivery disputes escalated by merchants; the photo's checksum matches the stored file. |
| Operations / IT lead | A system that survives mistakes and outages without manual rescue. | Live checks pass: a deleted photo is restored, a stopped container is replaced while the site keeps answering, the database fails over, and today's photo exists in the replica bucket. |
| Finance / management | Predictable, low running cost as photo volume grows. | Monthly AWS cost per environment tracked by the `CostCenter` tag stays within budget; storage cost per photo falls as old photos move to cheaper tiers. |

### Limits and risks of my design

- **The running system is not copied to the second Region.** Photos are replicated within minutes
  and the database is backed up daily to Frankfurt, but the app, load balancer and CloudFront
  setup are rebuilt from the repositories after a Region failure, which takes time. Up to a day of
  database changes could be lost; the catalogue can be completed from the details files.
- **Replication is not instant.** Photos uploaded in the last few minutes before an outage may not
  be in the replica yet. S3 Replication Time Control would cap this at 15 minutes for extra cost.
- **Old versions expire.** Overwritten or deleted versions are kept for a set number of days, not
  forever. If Onward needs legal retention for a fixed period, S3 Object Lock should be added.
- **No sign-in yet.** The app has no user accounts or roles, so anyone with the address can view
  and upload photos. Authentication (e.g. Amazon Cognito) is needed before real use.
- **Single account.** Production, backups and the replica live in one AWS account; a compromised
  administrator could still do damage. A separate backup account would reduce this.
- **Cost of always-on parts.** Multi-AZ RDS, VPC interface endpoints, WAF and at least two
  containers cost money even when nobody uploads; `scripts/teardown.sh` removes them after a demo.
