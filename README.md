# RegOps Sentinel

A regulatory intelligence platform for Canadian medical device distributors. Continuously watches Health Canada signals (recalls, drug shortages, MedEffect adverse events), classifies them with GPT-4o through Azure OpenAI, and delivers tenant-scoped alerts with an immutable audit trail.

**Status:** Phase 3 of 9 complete. Ingestion + classification pipeline live end-to-end. UI, security hardening, and CI/CD pending.

---

## Why this exists

Medical device distributors in Canada have a problem most software doesn't address. Health Canada publishes regulatory signals across at least three feeds — the Recalls and Safety Alerts database, the Drug Shortages portal, and the MedEffect adverse event database. Compliance teams are expected to know about a Class I recall affecting their catalog within hours, not days. The current tooling for this is a mix of email subscriptions, manual portal checks, and Excel-based triage. A 4-person clinic in Mississauga and a regional health authority running 12 clinics use the same primitive workflow.

That's the pain. The opportunity is that classifying these signals — "is this a Class I or Class II event," "does this affect my product catalog," "is the urgency high enough to halt distribution today" — is exactly the kind of structured judgment a well-prompted GPT-4o handles reliably. The hard part isn't the AI; the hard part is the regulated-data plumbing around it. Multi-tenant isolation. Immutable audit. Failure modes that don't drop signals on the floor when the AI is unavailable. PHIPA and HIPAA-adjacent expectations even though the data itself is mostly public.

RegOps Sentinel is the platform that does the plumbing.

## What's built

### Architecture

The system runs on AWS in `ca-central-1` for Canadian data residency, with Azure OpenAI as the only non-AWS dependency. It's hybrid by design — AWS for the regulated infrastructure plane, Azure for the LLM reasoning plane.

```
Health Canada feeds (3 sources)
        |
        v
EventBridge (30-min schedule)
        |
        v
Lambda watchers (recalls, shortages, medeffect)
        |
        v
SQS ingestion queue ----------> DLQ
        |
        v
Brain (FastAPI on ECS Fargate)
   |-- Azure OpenAI (GPT-4o classification)
   |-- RDS Postgres Multi-AZ (alerts table, tenant-scoped)
   +-- S3 audit bucket (immutable JSON blobs, KMS-encrypted)
        |
        v
ALB (internet-facing for Brain API)
   |-- /classify     manual classification
   |-- /alerts       tenant-scoped alert query
   |-- /health       liveness
   +-- /health/db    DB connectivity check
```

A formal architecture diagram is planned for Phase 8.

### What the Brain actually does

The Brain is a FastAPI application running on Fargate behind an ALB. Its SQS worker thread consumes ingested signals, sends each one to GPT-4o through Azure OpenAI for classification, and writes the result to two destinations: RDS for queryable alerts, S3 for immutable audit.

GPT-4o gets a structured prompt with the source feed, signal title, body text, and external ID. It returns one of three classifications (`RELEVANT`, `NOT_RELEVANT`, `NEEDS_REVIEW`), a relevance score, an urgency tier (`LOW` / `MEDIUM` / `HIGH` / `CRITICAL`), product categories, and a one-line summary suitable for an alerts list.

Sample output, real input, captured during Phase 3:

| Input | Classification | Score | Urgency | Categories |
|---|---|---|---|---|
| Class I recall for cardiac stent migration | RELEVANT | 1.0 | CRITICAL | cardiology-devices |
| Insulin Glargine drug shortage | RELEVANT | 0.9 | CRITICAL | diabetes-management-devices |
| Acetaminophen hepatotoxicity adverse event | NOT_RELEVANT | 0.0 | LOW | (none) |

The third row matters more than the first two. A naive system would tag every Health Canada signal as relevant; a useful system distinguishes pharmacovigilance (a pharma issue) from device safety (the distributor's actual concern). The Brain has a real domain filter, not a keyword matcher.

### Multi-tenancy

The audit bucket organizes objects by tenant prefix:

```
s3://regops-sentinel-dev-audit-1a8df723/
  audit/
    tenant-acme-meddev/
      2026/05/09/
        health-canada-recalls_82041_*.json
        health-canada-shortages_27_*.json
        health-canada-medeffect_82045_*.json
```

The `alerts` table in RDS carries a `tenant_id` column on every row. The `/alerts` API requires a tenant_id parameter and only returns matching rows. The audit prefix is the storage-layer expression of the same boundary the application enforces. Phase 5 will add an IAM bucket policy that denies cross-tenant prefix access, making the storage boundary cryptographically enforceable rather than just conventional.

## Phase status

| Phase | Status |
|---|---|
| 0: Foundation Setup (IAM, billing, Terraform bootstrap, remote state) | Complete |
| 1: Core Infrastructure (VPC, RDS, Cognito, KMS, Secrets Manager) | Complete |
| 2: The Watchers (3 Lambdas, EventBridge, SQS, CloudWatch) | Complete |
| 3: The Brain (FastAPI on Fargate, Azure OpenAI, audit + alerts) | Complete |
| 4: The Window (Next.js UI, Cognito MFA, dashboard, alerts list) | Pending |
| 5: Security Hardening (WAF, GuardDuty, Config, CloudTrail, Object Lock) | Pending |
| 6: Observability (CloudWatch dashboard, alarms, X-Ray) | Pending |
| 7: End-to-End Demo (real-world scenario, weekly digest email) | Pending |
| 8: Repo and CI/CD (GitHub Actions, architecture diagram, badges) | Pending |

Each phase has a defined screenshot manifest entry. See [SCREENSHOTS-MANIFEST.md](SCREENSHOTS-MANIFEST.md). Current capture: 28 of 50.

## Engineering decisions worth flagging

A few choices that aren't obvious from the architecture diagram:

**Internet-facing ALB on a regulatory platform.** The Brain ALB is public, not internal. This is intentional for the dev environment so I can test `/classify` from my laptop without setting up a VPN or jump host. CloudWatch logs already show automated scanners probing the ALB for `/mcp`, `/jsonrpc`, and `/login` endpoints — the Brain returns 404 to all of them with no information leakage, but Phase 5 will add WAF rules to drop these at the edge before they reach the application. For production deployments, the ALB will be internal-facing with a separate authenticated edge.

**Failure mode when Azure OpenAI is unavailable.** The Brain's classifier catches Azure errors and falls back to `NEEDS_REVIEW` with a `MEDIUM` urgency. Nothing gets dropped, nothing gets auto-classified as safe. A human will see the alert and decide. This is what saved the system during a Phase 3 secret-rotation bug — Azure returned 401 for several minutes while a corrupted credential was being fixed, and the Brain produced 9 conservative `NEEDS_REVIEW` records instead of crashing the worker.

**Audit immutability is currently versioning-based, not Object Lock.** The audit bucket has S3 Versioning, KMS encryption, blocked public access, and a 90-day Glacier transition. It does not yet have Object Lock with a retention policy. This is documented in the screenshot manifest and deferred to Phase 5 because retroactively enabling Object Lock requires either a CLI side-call against the existing bucket or a recreation; both are real work and belong in the dedicated hardening sprint, not in the middle of Phase 3 close-out.

**The buildspec is duplicated.** There's an inline buildspec in the CodeBuild project Terraform and a `buildspec.yml` file in `app/brain/`. They should match but currently the inline one is authoritative because the project is configured with `source.type = NO_SOURCE`. Phase 8 will pick one location and remove the other.

## Lessons captured during Phase 3

Each is a focused writeup in `docs/troubleshooting/`:

- [04-cve-acceptance-gnutls.md](docs/troubleshooting/04-cve-acceptance-gnutls.md) — DTLS-only CVE in a service that doesn't use DTLS; documented compensating controls and a re-evaluation cadence rather than blocking deployment on an unfixable transitive dep.
- [05-bom-fix.md](docs/troubleshooting/05-bom-fix.md) — PowerShell 5.1's `-Encoding UTF8` writes a BOM. AWS Secrets Manager stored the BOM, Python's `json.loads` rejected it, the Brain's worker thread caught the exception and logged it nowhere visible. Healthcheck stayed green while the actual work was dead.
- [06-ssm-iam-fix.md](docs/troubleshooting/06-ssm-iam-fix.md) — ECS Exec port-forwarding failed with `TargetNotConnected` even though the service flag and task flag both said exec was enabled. The brain task role was missing the four `ssmmessages:*` actions; without them, the SSM agent's process runs but never registers with the SSM service.
- [07-zip-paths-and-codebuild.md](docs/troubleshooting/07-zip-paths-and-codebuild.md) — Six small-but-time-consuming things about preparing source zips for CodeBuild from PowerShell on Windows: execution policy blocking `Compress-Archive`, `.NET ZipFile` writing backslashes, async `stop-build`, lagging ECR scan results, the one-scan-per-day quota, and Notepad's silent `.txt` extension.

## Repo structure

```
.
|-- README.md                          (this file)
|-- SCREENSHOTS-MANIFEST.md            50-screenshot capture plan
|-- app/
|   +-- brain/                         FastAPI Brain service
|       |-- Dockerfile
|       |-- buildspec.yml
|       |-- requirements.txt
|       +-- src/
|           |-- classifier.py          Azure OpenAI integration
|           |-- config.py              Config + secret loading
|           |-- db.py                  RDS connection + schema
|           |-- main.py                FastAPI app + endpoints
|           +-- worker.py              SQS poll loop
|-- docs/
|   |-- architecture/                  (placeholder for Phase 8 diagrams)
|   |-- runbooks/                      (placeholder for ops runbooks)
|   +-- troubleshooting/               numbered writeups (04, 05, 06, 07)
|-- screenshots/                       28 of 50 captured
+-- terraform/
    +-- environments/
        +-- dev/                       all dev infrastructure
```

## Working with the repo

This isn't a runnable demo for an unprivileged reader — it's a snapshot of an in-progress build. To redeploy from scratch you'd need:

- An AWS account with permissions for VPC, RDS, ECS, ECR, ALB, Lambda, EventBridge, SQS, S3, KMS, Secrets Manager, IAM, CloudWatch, Cognito, and CodeBuild.
- An Azure OpenAI resource with a deployed `gpt-4o` model.
- Health Canada portal credentials for the watcher Lambdas (the public APIs require authentication).
- Terraform 1.x and the AWS CLI, both configured against your account.

The Terraform is in `terraform/environments/dev/`. State lives in S3 with a DynamoDB lock table; the bootstrap that creates them is part of the Phase 0 work (not in this repo because that part predates the code split).

## Project context

This is project 14 in a portfolio focused on healthcare IT and MSP scenarios across the Toronto, Newfoundland, and Ohio markets. The earlier projects are at [github.com/MEEKMILEZ/azure-cloud-portfolio](https://github.com/MEEKMILEZ/azure-cloud-portfolio).
