# RegOps Sentinel - Screenshot Manifest

**Project:** Project 14, RegOps Sentinel
**Location on disk:** `C:\Users\Ebube\aws-cloud-portfolio\14-regops-sentinel\screenshots\`
**Total screenshots:** 50
**Status:** Airtight, locked, no additions without explicit discussion

## Capture rules

1. Filenames are exact. Do not improvise.
2. Numbers are by capture order, not by feature category.
3. When Claude says "capture screenshot NN now," refer to this manifest for the exact filename and what to frame.
4. A phase is not complete until all its screenshots are saved.
5. New screenshots only added after explicit discussion, given the next sequential number, and documented here first.
6. Description amendments to existing rows require explicit discussion and must be logged in the "Manifest amendments" section at the bottom.

## Phase 0: Foundation Setup (5)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 01 | 01-aws-iam-user-created.png | AWS Console > IAM > Users > new regops-terraform-admin user with attached policies | After dedicated IAM user created (not root) |
| 02 | 02-aws-billing-alert-set.png | AWS Console > Billing > Budgets > $50 budget alarm configured | After billing alert set |
| 03 | 03-powershell-aws-cli-authenticated.png | PowerShell aws sts get-caller-identity output with IAM user ARN | After local AWS CLI configured |
| 04 | 04-terraform-bootstrap-success.png | PowerShell terraform apply completed for bootstrap (S3 bucket + DynamoDB table) | After bootstrap completes |
| 05 | 05-aws-s3-state-bucket.png | AWS Console > S3 > regops-sentinel-tfstate-ca-central-1 bucket with versioning enabled | After bootstrap, browse to S3 |

## Phase 1: Core Infrastructure (8)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 06 | 06-terraform-init-remote-backend.png | PowerShell terraform init with Successfully configured the backend s3 message | After main terraform init |
| 07 | 07-terraform-plan-infrastructure.png | PowerShell terraform plan with resource count summary | Right before first apply |
| 08 | 08-terraform-apply-complete.png | PowerShell Apply complete with N resources added | After successful first apply |
| 09 | 09-aws-vpc-architecture.png | AWS Console > VPC > Resource Map showing VPC, subnets, NAT, IGW | After VPC is up |
| 10 | 10-aws-rds-postgres-running.png | AWS Console > RDS > PostgreSQL Available with Multi-AZ enabled | After RDS provisioning ~10 min |
| 11 | 11-aws-cognito-user-pool.png | AWS Console > Cognito > user pool with multi-tenant attribute schema | After Cognito deployed |
| 12 | 12-aws-secrets-manager.png | AWS Console > Secrets Manager > list of secrets | After secrets populated |
| 13 | 13-aws-kms-keys.png | AWS Console > KMS > customer-managed keys for RDS, S3, Secrets Manager | After KMS deployment |

## Phase 2: The Watchers (7)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 14 | 14-app-watcher-shortage-code.png | VS Code with Lambda code for shortage list watcher | After writing the code |
| 15 | 15-aws-lambda-watcher-shortage-deployed.png | AWS Console > Lambda > regops-watcher-shortage-list deployed | After Terraform deploys it |
| 16 | 16-aws-lambda-watcher-whatsnew-deployed.png | AWS Console > Lambda > regops-watcher-whatsnew deployed | After deployment |
| 17 | 17-aws-lambda-watcher-forwardplan-deployed.png | AWS Console > Lambda > regops-watcher-forwardplan deployed | After deployment |
| 18 | 18-aws-eventbridge-schedules.png | AWS Console > EventBridge > three scheduled rules every 30 min | After EventBridge config |
| 19 | 19-aws-sqs-queue-with-messages.png | AWS Console > SQS > ingestion queue with messages visible | After first successful watcher execution |
| 20 | 20-aws-cloudwatch-watcher-logs.png | CloudWatch > Log Groups > successful watcher execution with parsed Health Canada items | After first successful run |

## Phase 3: The Brain (8)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 21 | 21-app-brain-classifier-code.png | VS Code with FastAPI Brain code, GPT-4o classification function | After writing Brain code |
| 22 | 22-aws-ecr-image-pushed.png | AWS Console > ECR > Brain container image with vulnerability scan zero CRITICAL | After CI/CD pushes image |
| 23 | 23-aws-ecs-brain-task-running.png | AWS Console > ECS > Brain service with running tasks healthy | After Brain deployment |
| 24 | 24-azure-openai-integration.png | Azure Portal > OpenAI resource > recent API calls in metrics panel | After Brain processes first message |
| 25 | 25-app-classification-result.png | PowerShell with JSON classification result from GPT-4o for real Health Canada update | First successful classification |
| 26 | 26-aws-rds-data-populated.png | pgAdmin or DBeaver showing alerts table populated with tenant_id visible | After several alerts processed |
| 27 | 27-aws-s3-audit-blob.png | AWS Console > S3 > audit bucket with JSON classification objects, Versioning enabled and SSE-KMS encryption visible | After multiple classifications |
| 28 | 28-aws-ecs-brain-cloudwatch-logs.png | CloudWatch logs for Brain showing full processing cycle | After Brain has been running |

## Phase 4: The Window (10)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 29 | 29-app-nextjs-login-page.png | Browser showing RegOps Sentinel login page with tenant selector | First login attempt |
| 30 | 30-app-nextjs-cognito-mfa-prompt.png | Browser showing Cognito MFA enrollment / TOTP prompt | During first user setup |
| 31 | 31-app-window-dashboard.png | Browser showing main dashboard with KPIs | After first login as tenant user |
| 32 | 32-app-window-alerts-list.png | Browser showing Alerts page filtered to one tenant | On Alerts tab |
| 33 | 33-app-window-alert-detail.png | Browser showing detail view of single alert | Click into one alert |
| 34 | 34-app-window-obligation-tracker.png | Browser showing Obligations page with deadlines | On Obligations tab |
| 35 | 35-app-window-device-catalog.png | Browser showing Device Catalog upload screen | On Device Catalog tab |
| 36 | 36-app-window-audit-log.png | Browser showing Audit Log page | On Audit tab |
| 37 | 37-app-window-tenant-isolation-proof.png | Two browser tabs side by side: Tenant A vs Tenant B data | After both tenants seeded |
| 38 | 38-app-window-mobile-responsive.png | Browser dev tools mobile view of dashboard | Once UI polished |

## Phase 5: Security Hardening (5)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 39 | 39-aws-waf-blocking-attack.png | AWS Console > WAF > blocked requests sample SQLi attempt blocked | After running controlled SQLi attempt |
| 40 | 40-aws-guardduty-active.png | AWS Console > GuardDuty > service active in ca-central-1 | After GuardDuty enabled |
| 41 | 41-aws-config-compliance.png | AWS Console > AWS Config > conformance pack rules passing | After Config rules deployed |
| 42 | 42-aws-cloudtrail-logging.png | AWS Console > CloudTrail > recent management events captured to audit S3 bucket | After running through platform |
| 43 | 43-aws-iam-accessanalyzer.png | AWS Console > IAM > Access Analyzer > zero external access findings | After IAM hardening |

## Phase 6: Observability (3)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 44 | 44-aws-cloudwatch-dashboard.png | CloudWatch custom dashboard with system health metrics | After dashboard built |
| 45 | 45-aws-cloudwatch-alarm-fired.png | CloudWatch alarm in OK or ALARM state for controlled trigger | After triggering controlled test |
| 46 | 46-aws-xray-trace.png | AWS Console > X-Ray > service map ALB > ECS > RDS > S3 | After X-Ray instrumentation |

## Phase 7: End-to-End Demo (2)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 47 | 47-app-end-to-end-flow.png | Browser showing single Health Canada update full lifecycle | After full real-world scenario run |
| 48 | 48-app-weekly-digest-email.png | Email client showing weekly digest with classified updates | After first digest run |

## Phase 8: Repo and CI/CD (2)

| # | Filename | What it shows | When to capture |
|---|---|---|---|
| 49 | 49-github-actions-pipeline.png | GitHub > Actions > CI/CD pipeline succeeding (lint, test, security scan, plan, deploy) | After CI/CD wired up |
| 50 | 50-github-repo-readme.png | GitHub repo home page showing rendered README with diagram and badges | After final commit |

## Manifest summary

| Phase | Screenshots | Range |
|---|---|---|
| 0: Foundation | 5 | 01-05 |
| 1: Core Infrastructure | 8 | 06-13 |
| 2: The Watchers | 7 | 14-20 |
| 3: The Brain | 8 | 21-28 |
| 4: The Window | 10 | 29-38 |
| 5: Security Hardening | 5 | 39-43 |
| 6: Observability | 3 | 44-46 |
| 7: End-to-End Demo | 2 | 47-48 |
| 8: Repo and CI/CD | 2 | 49-50 |
| Total | 50 | 01-50 |

## Manifest amendments

Description-only changes to existing rows. Filenames and capture order remain locked.

| Date | Row | Change | Reason |
|---|---|---|---|
| 2026-05-09 | 27 | Description changed from "audit container with JSON blobs, Object Lock enabled" to "audit bucket with JSON classification objects, Versioning enabled and SSE-KMS encryption visible" | Audit bucket was created without `object_lock_enabled` flag at bucket creation; enabling Object Lock retroactively requires either bucket recreation (destroys existing audit records) or a CLI side-call + Terraform reconcile. Object Lock deferred to Phase 5 (Security Hardening) where it belongs as part of the bucket hardening sprint. Current bucket has Versioning + SSE-KMS + Public Access Block + Lifecycle to Glacier — strong v1 posture without Object Lock. |

| 2026-05-14 | 34 | Deferred to Phase 5C | Obligations tracker (`34-app-window-obligation-tracker.png`) is a real domain feature requiring its own engineering sprint (~8-10hr). Phase 5C committed for the weeks ahead. Capture when the feature ships. |
| 2026-05-14 | 35 | Deferred to Phase 5B | Device catalog upload UI (`35-app-window-device-catalog.png`) is a real domain feature requiring its own engineering sprint (~8-10hr). Phase 5B committed for the weeks ahead. Capture when the feature ships. |
| 2026-05-14 | 36 | Captured (Phase 5A shipped) | Audit log UI shipped 2026-05-14 evening. Brain `GET /audit` endpoint with cursor pagination + multi-audience Cognito JWT verification (web + CLI clients). Window `/audit` server component + BFF proxy + sidebar nav entry. End-to-end validated: 84 audit blobs across 2 pages, tenant scoping verified via S3 prefix derived from JWT claim. Screenshot captured against real RDS-backed data. |
| 2026-05-14 | 37 | Deferred | Tenant isolation proof requires seeding a second Cognito tenant + RDS rows under a separate tenant_id, then side-by-side browser capture. Tenant scoping is verified architecturally (Brain derives S3 prefix from JWT claim, never trusts query input) but visual proof needs a second tenant. Out of scope for the Phase 5A sprint; revisit during Phase 5+ polish. |
| 2026-05-14 | 38 | Deferred | Mobile responsiveness not currently tested or optimised. Page layouts use Tailwind sm:/lg: breakpoints but no specific mobile audit has been performed. Revisit during Phase 5+ polish. |
| 2026-05-14 | 44 | Deferred (capture only) | CloudWatch dashboard infrastructure deployed (commit da0fa9a). Screenshot deferred until meaningful traffic populates widgets - a flat-line screenshot would mislead. Recapture once Phase 5B/5C are live and generating sustained load. |
## Phase 5 pending work (audit bucket hardening)

Items deferred from earlier phases to be addressed during Phase 5 Security Hardening sprint. These do not get their own manifest screenshots unless explicitly added; they are work items folded into existing Phase 5 deliverables.

- **Audit bucket Object Lock** — enable retroactively via `aws s3api put-object-lock-configuration` with `ObjectLockEnabled=Enabled` and `Rule.DefaultRetention` set (Governance or Compliance mode, retention period TBD per regulatory horizon). Reconcile in Terraform by setting `object_lock_enabled = true` on `aws_s3_bucket.audit` and adding `aws_s3_bucket_object_lock_configuration` resource. Verify the change is plan-clean (in-place update, not bucket recreation) before applying.
- **Audit bucket `force_destroy` flag** — flip from `true` to `false` (or remove the line; `false` is the default). The current `force_destroy = true` lets `terraform destroy` wipe the bucket and its objects in one shot, which contradicts the immutable audit narrative. Acceptable in dev iteration; not acceptable for the final hardened state.