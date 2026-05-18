# =====================================================================
# CloudTrail (Phase 5 Security Hardening, screenshot #42)
# =====================================================================
#
# AWS CloudTrail records every API call made in this account (and all
# regions when multi-region is enabled), giving a tamper-evident audit
# log of WHO did WHAT, WHEN, and from WHERE at the infrastructure
# layer. This is distinct from the application audit blobs in
# s3://regops-sentinel-dev-audit-1a8df723/audit/tenant-X/... which
# record business-domain events (classifications, obligations,
# device uploads).
#
# Architecture decision: log CloudTrail to the existing audit bucket
# under a separate cloudtrail/ prefix rather than provisioning a new
# bucket. Same KMS encryption, same Object Lock protection, same
# versioning. Trade-off documented in the README's "Engineering
# decisions worth flagging" section.
#
# Cost: CloudTrail's first management-events trail is free for the
# account; THIS is the second trail (the AWS-default account-wide
# free trail still exists), so it runs at $2.00/month plus
# $0.10/100k events. In dev volume the data charge is negligible.
#
# References:
#   - CloudTrail user guide:
#     https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-user-guide.html
#   - Required S3 bucket policy statements:
#     https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html
#   - KMS for CloudTrail:
#     https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-kms-key-policy-for-cloudtrail.html
# =====================================================================


# ---------------------------------------------------------------------
# Bucket policy on the audit bucket - REQUIRED for CloudTrail to write.
# ---------------------------------------------------------------------
# CloudTrail's service principal (cloudtrail.amazonaws.com) is what
# actually writes log files to the bucket. By default S3 buckets deny
# all unsigned access, so we have to explicitly allow this service
# principal to write under the cloudtrail/ prefix.
#
# The two-statement pattern below is the documented AWS recommendation:
#   1. AWSCloudTrailAclCheck: lets CloudTrail call GetBucketAcl to
#      verify it can write. Without this, trail creation fails with
#      "InsufficientS3BucketPolicyException".
#   2. AWSCloudTrailWrite: lets CloudTrail put objects, but ONLY if
#      the object is being written as "bucket-owner-full-control"
#      (which is what CloudTrail does). The aws:SourceArn condition
#      pins the policy to THIS specific trail, preventing other
#      accounts' trails from writing to our bucket.
resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.audit.arn
        Condition = {
          StringEquals = {
            "aws:SourceArn" = "arn:aws:cloudtrail:ca-central-1:575751781190:trail/${local.name_prefix}-trail-${local.full_suffix}"
          }
        }
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = {
          Service = "cloudtrail.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.audit.arn}/cloudtrail/AWSLogs/575751781190/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = "arn:aws:cloudtrail:ca-central-1:575751781190:trail/${local.name_prefix}-trail-${local.full_suffix}"
          }
        }

      }
    ]
  })
}


# ---------------------------------------------------------------------
# The trail
# ---------------------------------------------------------------------
# Configuration choices:
#   - is_multi_region_trail: true. Captures API calls in all regions,
#     not just ca-central-1. Industry-standard default for compliance
#     postures - regulators want to see global activity.
#   - enable_log_file_validation: true. CloudTrail produces a digest
#     file every hour containing SHA-256 hashes of the log files
#     delivered in that window. Tampering with logs becomes detectable
#     via `aws cloudtrail validate-logs`. Documented at:
#     https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html
#   - include_global_service_events: true. Records IAM, STS, Route53,
#     CloudFront events (which are global, not regional).
#   - kms_key_id: uses the project's CMK so logs are encrypted at rest
#     with the same key that protects the audit bucket itself.
#   - Management events only (no data_resource block). Data events
#     (S3 object-level reads, Lambda invocation parameters) would be
#     prohibitively expensive at $0.10/100k - and the project's
#     application-level audit blobs already capture the data-event
#     story for business-domain operations.
resource "aws_cloudtrail" "main" {
  name           = "${local.name_prefix}-trail-${local.full_suffix}"
  s3_bucket_name = aws_s3_bucket.audit.id
  s3_key_prefix  = "cloudtrail"

  is_multi_region_trail         = true
  enable_log_file_validation    = true
  include_global_service_events = true
  enable_logging                = true

  kms_key_id = aws_kms_key.main.arn

  tags = {
    Name = "${local.name_prefix}-trail-${local.full_suffix}"
    Tier = "audit"
  }

  # The trail's bucket-write step happens at apply time, so the
  # bucket policy must already be in place when CloudTrail starts.
  depends_on = [aws_s3_bucket_policy.audit]
}


output "cloudtrail_arn" {
  value       = aws_cloudtrail.main.arn
  description = "ARN of the CloudTrail trail"
}

output "cloudtrail_bucket_prefix" {
  value       = "s3://${aws_s3_bucket.audit.id}/cloudtrail/"
  description = "S3 prefix under which CloudTrail writes log files"
}
