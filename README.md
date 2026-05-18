# RegOps Sentinel

[![Brain CI](https://github.com/MEEKMILEZ/regops-sentinel/actions/workflows/brain-ci.yml/badge.svg)](https://github.com/MEEKMILEZ/regops-sentinel/actions/workflows/brain-ci.yml)
[![Window CI](https://github.com/MEEKMILEZ/regops-sentinel/actions/workflows/window-ci.yml/badge.svg)](https://github.com/MEEKMILEZ/regops-sentinel/actions/workflows/window-ci.yml)
[![Terraform CI](https://github.com/MEEKMILEZ/regops-sentinel/actions/workflows/terraform-ci.yml/badge.svg)](https://github.com/MEEKMILEZ/regops-sentinel/actions/workflows/terraform-ci.yml)

A regulatory intelligence platform for Canadian medical device distributors. Continuously watches Health Canada signals (recalls, drug shortages, MedEffect adverse events), classifies them with GPT-4o through Azure OpenAI, and delivers tenant-scoped alerts with an immutable audit trail.

**Status:** Built and running end-to-end on AWS. All ten phases through CI/CD auto-deploy are shipped: ingestion, classification, audit log, device catalog, obligations CRUD with audit, full-text search, immutable storage, observability, weekly regulatory digest, and keyless OIDC deploys. The screenshot manifest is at 50 of 50 captures. See the phase table below for what each phase covers.

---

## Why this exists

Medical device distributors in Canada have a problem most software doesn't address. Health Canada publishes regulatory signals across at least three feeds — the Recalls and Safety Alerts database, the Drug Shortages portal, and the MedEffect adverse event database. Compliance teams are expected to know about a Class I recall affecting their catalog within hours, not days. The current tooling for this is a mix of email subscriptions, manual portal checks, and Excel-based triage. A 4-person clinic in Mississauga and a regional health authority running 12 clinics use the same primitive workflow.

That's the pain. The opportunity is that classifying these signals — "is this a Class I or Class II event," "does this affect my product catalog," "is the urgency high enough to halt distribution today" — is exactly the kind of structured judgment a well-prompted GPT-4o handles reliably. The hard part isn't the AI; the hard part is the regulated-data plumbing around it. Multi-tenant isolation. Immutable audit. Failure modes that don't drop signals on the floor when the AI is unavailable. PHIPA and HIPAA-adjacent expectations even though the data itself is mostly public.

RegOps Sentinel is the platform that does the plumbing.

## Key capabilities

- Continuous regulatory signal ingestion from three Health Canada feeds (Recalls, Drug Shortages, MedEffect)
- GPT-4o relevance + urgency classification through Azure OpenAI, with a `NEEDS_REVIEW` fallback when the model is unavailable
- Multi-tenant data plane with JWT-scoped reads, tenant-prefixed audit storage, and zero client-supplied tenant identifiers
- Immutable regulatory audit trail in S3 (Object Lock GOVERNANCE + versioning + KMS, retention applied to backfilled records)
- Async device-catalog ingestion from real MDALL CSV exports with job-tracked progress, batched UPSERTs, and tab-close recovery
- Tenant-scoped obligations tracker with full create / edit / complete / delete + immutable obligation audit
- Cross-domain full-text search over alerts, devices, and obligations via Postgres tsvector
- Cognito sign-in with TOTP MFA enforcement and a BFF that keeps tokens server-side
- Weekly regulatory digest email delivered through EventBridge + Lambda + SES
- CloudWatch dashboard, SNS alarms, AWS Config, CloudTrail, IAM Access Analyzer, GuardDuty, and WAFv2 in COUNT mode
- OpenTelemetry instrumentation with the ADOT collector sidecar, exporting to AWS X-Ray
- Keyless CI/CD via GitHub Actions OIDC: every push to `main` builds the brain image and deploys to ECS with no stored AWS access keys

## Market context

This category exists. RegDesk, Rimsys, RegASK, Freyr RegIntel, Johner Institute, Vistaar, freya.intelligence — there's a real and growing market for "AI-powered regulatory intelligence" software in life sciences. Most of them target medical device manufacturers and pharmaceutical companies, with global multi-jurisdictional coverage. RegOps Sentinel is narrower in two specific ways:

1. **Health Canada first, not just one of many.** The deepest model of CMDR Section 60, MDL renewal cycles, and the December 2024 reporting reforms — not a global product with Canada bolted on.
2. **Distributors, not manufacturers.** Distributors hold an MDEL (Medical Device Establishment Licence) rather than an MDL per product. Their obligations are different: distribution record keeping, recall notification to downstream consignees, 24-hour reporting of Type I/II recalls under the post-Dec-2024 mandatory framework. The big global RIM platforms are built around the manufacturer workflow (submissions, approvals, post-market) — that's a different shape than what an MDEL-holding distributor actually needs day to day.

Whether this niche is large enough to be a standalone business is a separate question. As a portfolio piece it demonstrates the end-to-end skill of identifying a real category, scoping a real niche, and shipping a real working product — not novelty-claiming an empty market.

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
   |-- RDS Postgres Multi-AZ (alerts, devices, obligations,
   |                          device_upload_jobs, tsvector search
   |                          indexes - all tenant-scoped)
   +-- S3 audit bucket (Object Lock GOVERNANCE,
                        KMS-encrypted, versioned)
        |
        v
ALB (internet-facing, JWT-authenticated by FastAPI middleware)
   |-- /classify                manual classification
   |-- /alerts, /alerts/{id}    tenant-scoped alert query
   |-- /audit                   audit log listing
   |-- /devices, /devices/{id}  device catalog
   |-- /devices/upload          CSV upload (async, job-id returned)
   |-- /devices/upload/{job_id} job status (polled by the UI)
   |-- /obligations             regulatory task tracker
   |-- /search                  cross-table full-text search
   +-- /health, /health/db      liveness + DB connectivity

Window (Next.js on app server, BFF to the Brain)
   |-- Cognito sign-in (User Pool + Hosted UI, TOTP MFA enforced)
   |-- Server components fetch via BFF routes that attach the
   |   user's Cognito ID token as a Bearer header
   |-- /devices page with file-picker upload, preview modal,
   |   live progress polling, results screen, localStorage
   |   tab-resume
   +-- Dashboard widgets pulling from the real /alerts and
       /obligations endpoints (no stub data anywhere)
```

See [docs/architecture.md](docs/architecture.md) for the formal architecture diagrams (high-level system view + the alert pipeline and user-action data flows) plus the cross-cutting design rationale: trust boundaries, tenant isolation, audit immutability, observability.

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

### What the Window does

The Next.js app is a server-rendered UI sitting in front of the Brain. Users sign in through Cognito (TOTP MFA enforced). Server components fetch data via BFF route handlers that attach the user's Cognito ID token as a Bearer header before calling the Brain — the browser never sees the token. The Brain validates JWT signatures against the Cognito JWKS, extracts the `custom:tenant_id` claim, and uses it as the tenant scope for every query. There is no client-supplied tenant id at any point.

The dashboard, alerts list, alert detail page, audit log, device catalog, obligations tracker, and cross-table search are all wired to real data. No placeholder rows live in the UI; if the Brain returns zero rows the UI honestly says so.

### Device CSV upload (Phase 5B.2)

Distributors maintain a device catalog. Most of them keep it as a CSV exported from Health Canada's MDALL (Medical Device Active Licence Listing) portal. RegOps Sentinel accepts that file directly: upload it through the UI, and an async background worker parses the rows, validates against the MDR device class enum, and UPSERTs the catalog tenant-scoped.

The full path:

```
Browser file picker -> client-side size check (1 MB hard cap)
   -> POST /api/devices/upload (BFF, attaches JWT)
   -> POST /devices/upload (Brain, returns 202 + job_id)
   -> inserts device_upload_jobs row, spawns worker thread
Background worker:
   -> reads CSV, processes 5-row batches with ON CONFLICT
      DO UPDATE (UPSERT keyed on tenant_id + UDI-DI)
   -> RETURNING (xmax = 0) distinguishes inserts from updates
   -> updates the job row's counters after each batch
Browser UI:
   -> writes job_id to localStorage
   -> polls /api/devices/upload/{job_id} every 1.5s
   -> renders live progress, then complete/failed view
   -> calls router.refresh() so the table re-fetches
   -> clears localStorage on terminal status
Tab-close recovery:
   -> on mount, UI checks localStorage and refetches the
      stored job; resumes the appropriate view (in-progress,
      complete, or failed)
```

Real MDALL columns are mapped: `LICENCE_NO`, `DEVICE_NAME`, `MODEL_IDENTIFIER`, `COMPANY_NAME`, `DEVICE_CLASS`, `LICENCE_STATUS`, `UDI_DI`. Real Health Canada licence statuses are normalized: `ACTIVE` → `active`, `CANCELLED`/`EXPIRED` → `discontinued`, `SUSPENDED` → `recalled`, `PENDING` → `pending`. End-to-end smoke test: 15 rows ingested in 269 ms total.

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

The `alerts`, `devices`, `obligations`, and `device_upload_jobs` tables in RDS each carry a `tenant_id` column on every row, and every API enforces tenant scoping from the JWT's `custom:tenant_id` claim — never from request input. Cross-tenant lookups on detail endpoints return 404 (not 403) so the system doesn't leak object existence to unauthorized callers. The audit prefix is the storage-layer expression of the same boundary the application enforces.

### Immutability of the audit log

The audit bucket has S3 Object Lock enabled in GOVERNANCE mode with a 1-day default retention period, layered on top of versioning, KMS encryption, and `force_destroy = false` on the Terraform resource. All 84 historical audit blobs were backfilled with `put-object-retention` so the existing log enjoys the same protection as new writes.

Versioned-delete attempts against locked objects return:

```
An error occurred (AccessDenied) when calling the DeleteObject
operation: Access Denied because object protected by object lock.
```

That's the literal message from AWS — the audit log cannot be altered or deleted within its retention window, even by the bucket owner, even by AWS root. For a regulatory record of record, this is the actual answer to "how do you prove this hasn't been tampered with."

GOVERNANCE mode (rather than COMPLIANCE) is the demo-environment choice — it allows IAM principals with the `s3:BypassGovernanceRetention` permission to override locks, which is the right balance for a dev environment. Production deployment would set COMPLIANCE mode with the customer's required retention period (typically 7 years for FDA records, 6 years for Health Canada CMDR Section 60 obligations).

Enabling Object Lock on the existing bucket was done via an out-of-band `aws s3api put-object-lock-configuration` call rather than a Terraform-driven change. The reason: HashiCorp issue [#36529](https://github.com/hashicorp/terraform-provider-aws/issues/36529) — the AWS Terraform provider's `object_lock_enabled` argument forces bucket replacement on existing buckets, even though AWS itself supports in-place enablement via the API since November 2023. The Terraform resource for retention rules (`aws_s3_bucket_object_lock_configuration.audit`) manages the retention policy from this point forward, paired with a `lifecycle { ignore_changes = [object_lock_configuration] }` block on the bucket to prevent drift.

## Phase status

| Phase | Status |
|---|---|
| 0: Foundation Setup (IAM, billing, Terraform bootstrap, remote state) | Complete |
| 1: Core Infrastructure (VPC, RDS, Cognito, KMS, Secrets Manager) | Complete |
| 2: The Watchers (3 Lambdas, EventBridge, SQS, CloudWatch) | Complete |
| 3: The Brain (FastAPI on Fargate, Azure OpenAI, audit + alerts) | Complete |
| 4: The Window (Next.js, Cognito MFA, dashboard, alerts list + detail) | Complete |
| 5A: Audit log endpoint + UI + multi-audience JWT | Complete |
| 5B: Device catalog (read-only) | Complete |
| 5B.2-A: Device CSV upload backend (async jobs) | Complete |
| 5B.2-B: Device CSV upload UI (preview + progress + tab-resume) | Complete |
| 5C: Obligations tracker + cross-table tsvector search | Complete |
| 5C.2: Obligations create/edit UI | Pending |
| 5D: Audit bucket hardening (Object Lock + immutability proof) | Complete |
| 6A: CloudWatch dashboard + alarms + SNS topic (10 alarms, 6 metric, 4 composite) | Complete |
| 6B: X-Ray distributed tracing (OpenTelemetry + ADOT collector + AwsXRayIdGenerator + BatchSpanProcessor) | Complete |
| 7: End-to-End Demo - weekly regulatory digest email (EventBridge -> Lambda -> RDS -> SES) | Complete |
| 8: Repo and CI/CD (GitHub Actions workflows for brain, window, terraform) | Complete |
| 9: GitHub Actions OIDC keyless auto-deploy on push to main (no long-lived AWS credentials) | Complete |

Each phase has a defined screenshot manifest entry. See [SCREENSHOTS-MANIFEST.md](SCREENSHOTS-MANIFEST.md). Capture status: 50 of 50.

## What's not done

Being honest about scope rather than hiding the gaps:

- **Obligations create/edit UI** (`5C.2`). Currently the obligations tracker is read-only — you can browse the seeded set but not add or update from the UI. The backend is also read-only on this domain.
- **Email and Slack notifications** for overdue obligations. No outbound channel; users have to look at the dashboard to know.
- **Multi-tenant onboarding flow.** Two tenants (`tenant-acme-meddev` and `tenant-meditech-on`) are seeded directly into the database; a third would still need a Terraform change and manual Cognito user creation. No self-serve sign-up. Also: the SQS worker hardcodes `tenant_id = DEFAULT_TENANT` on writes (read-side tenant scoping is fully enforced from the JWT, but write-side multi-tenant routing is a known gap).
- **Audit log detail page.** You can list audit events but clicking through to a single event's JSON payload is not wired (the Brain endpoint exists; the UI page isn't built).
- **Bulk actions, filters, exports.** The tables paginate but don't filter, sort beyond default, or export to CSV/PDF.

The list above is what a hiring manager should expect to see absent. It is not an exhaustive future roadmap — a real productionization would also need billing, support docs, user management, RBAC, audit-log retention tuning per customer, and a dozen other things that aren't on this project's scope.

## Engineering decisions worth flagging

**Conservative classifier fallback.** When Azure OpenAI is unavailable, the classifier returns `NEEDS_REVIEW` at `MEDIUM` urgency rather than dropping the signal or defaulting to `NOT_RELEVANT`. A real Phase 3 incident (a corrupted secret causing 401s for several minutes) produced 9 conservative `NEEDS_REVIEW` rows instead of either silent data loss or auto-classifying unsafe signals as safe.

**Multi-audience JWT verification.** The Brain accepts JWTs from two Cognito clients in the same User Pool: the Hosted-UI client (used by the browser) and a CLI client (used by smoke tests). Auth middleware validates against either allowed audience rather than hardcoding one client ID — one User Pool, two issuer surfaces, no separate trust store.

**Async job processing for CSV upload.** A naive upload endpoint reads and ingests the file inside the request handler. The async pattern (POST returns a `job_id` immediately, client polls for status) costs a small `device_upload_jobs` table and a worker thread, and buys a real progress UI plus resilience to client disconnects mid-upload.

**Object Lock layered on top of versioning.** Object Lock alone protects writes from deletion; versioning alone lets you recover an overwritten object. Together they cover both adversarial modification and accidental deletion. Bucket policies that deny `s3:DeleteObject` are soft controls any IAM admin can edit; Object Lock retention is a hard control that requires waiting out the retention window.

**Keyless deploys via OIDC.** The GitHub Actions deploy role is assumed via OpenID Connect: GitHub mints a short-lived JWT, AWS verifies it against a trust policy that pins both audience and subject, and STS returns 1-hour temporary credentials. No `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` is stored in GitHub secrets, the repo, or anywhere else.

**Internet-facing ALB in dev, with WAF in front.** The Brain ALB is public for development convenience (testing `/classify` from a laptop without a VPN). AWS WAFv2 runs in front in COUNT mode while traffic patterns are observed; CloudWatch logs already show automated scanners probing `/mcp`, `/jsonrpc`, `/login` — all returning 404 with no information leakage. Production deployments would flip the ALB to internal-facing behind an authenticated edge.

## Lessons captured during the build

Each is a focused writeup in `docs/troubleshooting/`:

- [04-cve-acceptance-gnutls.md](docs/troubleshooting/04-cve-acceptance-gnutls.md) — DTLS-only CVE in a service that doesn't use DTLS; documented compensating controls and a re-evaluation cadence rather than blocking deployment on an unfixable transitive dep.
- [05-bom-fix.md](docs/troubleshooting/05-bom-fix.md) — PowerShell 5.1's `-Encoding UTF8` writes a BOM. AWS Secrets Manager stored the BOM, Python's `json.loads` rejected it, the Brain's worker thread caught the exception and logged it nowhere visible. Healthcheck stayed green while the actual work was dead.
- [06-ssm-iam-fix.md](docs/troubleshooting/06-ssm-iam-fix.md) — ECS Exec port-forwarding failed with `TargetNotConnected` even though the service flag and task flag both said exec was enabled. The brain task role was missing the four `ssmmessages:*` actions; without them, the SSM agent's process runs but never registers with the SSM service.
- [07-zip-paths-and-codebuild.md](docs/troubleshooting/07-zip-paths-and-codebuild.md) — Six small-but-time-consuming things about preparing source zips for CodeBuild from PowerShell on Windows: execution policy blocking `Compress-Archive`, `.NET ZipFile` writing backslashes, async `stop-build`, lagging ECR scan results, the one-scan-per-day quota, and Notepad's silent `.txt` extension.

(Additional Phase 5 lessons — multi-audience JWT, route specificity ordering, stale-source-zip deploys, Object Lock provider bug — are worth writing up but haven't been formalized yet. They're documented in the commit messages on those phases.)

## Repo structure

```
.
|-- README.md                          (this file)
|-- SCREENSHOTS-MANIFEST.md            50-screenshot capture plan (38 captured)
|-- app/
|   |-- brain/                         FastAPI Brain service
|   |   |-- Dockerfile
|   |   |-- buildspec.yml
|   |   |-- requirements.txt
|   |   |-- samples/
|   |   |   +-- sample-mdall-export.csv   15-row test fixture
|   |   +-- src/
|   |       |-- audit.py               /audit endpoint (S3 listing + JWT)
|   |       |-- auth.py                Cognito JWT verifier + middleware
|   |       |-- classifier.py          Azure OpenAI integration
|   |       |-- config.py              Config + secret loading
|   |       |-- db.py                  RDS connection + schema (alerts,
|   |       |                          devices, obligations, upload jobs,
|   |       |                          tsvector indexes)
|   |       |-- device_upload.py       Async CSV ingestion worker
|   |       |-- main.py                FastAPI app + all endpoints
|   |       +-- worker.py              SQS poll loop
|   +-- window/                        Next.js app
|       |-- src/app/(app)/             authenticated app routes
|       |-- src/app/api/               BFF route handlers
|       |-- src/components/            React components by domain
|       +-- src/lib/                   shared types, bff helper,
|                                      stats utilities
|-- apply-*.ps1                        phase-by-phase patch scripts
|-- deploy-audit-endpoint.ps1          brain deploy pipeline
|-- docs/
|   |-- architecture/                  (placeholder for Phase 8 diagrams)
|   |-- runbooks/                      (placeholder for ops runbooks)
|   +-- troubleshooting/               numbered writeups (04, 05, 06, 07)
|-- screenshots/                       38 of 50 captured
+-- terraform/
    +-- environments/
        +-- dev/                       all dev infrastructure
```


## Project context

This is project 14 in a portfolio focused on healthcare IT and MSP scenarios across the Toronto, Newfoundland, and Ohio markets. The earlier projects (01–13) are at [github.com/MEEKMILEZ/azure-cloud-portfolio](https://github.com/MEEKMILEZ/azure-cloud-portfolio).
