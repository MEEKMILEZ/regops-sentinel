resource "aws_s3_bucket" "audit" {
  bucket = "${local.name_prefix}-audit-${local.full_suffix}"
  # Phase 5D: flipped from true. The audit log is the regulatory record
  # of record; nuking it should never be a single-command operation.
  force_destroy = false

  tags = {
    Name = "${local.name_prefix}-audit-${local.full_suffix}"
    Tier = "audit"
  }

  # Object Lock is enabled out-of-band via the AWS CLI (see
  # apply-phase-5d-audit-hardening-v3.ps1) because the AWS Terraform
  # provider's object_lock_enabled argument forces bucket replacement
  # on existing buckets. Retention rules are managed by the
  # aws_s3_bucket_object_lock_configuration resource below.
  lifecycle {
    ignore_changes = [object_lock_configuration]
  }
}

resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "transition-to-glacier"
    status = "Enabled"

    filter {
      prefix = "audit/"
    }

    transition {
      days          = 90
      storage_class = "GLACIER"
    }

    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }
  }
}

# Phase 5D: Object Lock retention policy for the audit bucket.
#
# GOVERNANCE mode + 1-day retention is the demo-environment config.
# Production deployment for a real tenant would set this to COMPLIANCE
# mode + the customer's required retention period (typically 7 years
# for FDA records, 6 years for Health Canada CMDR Section 60).
#
# GOVERNANCE mode allows authorised IAM principals with the
# s3:BypassGovernanceRetention permission to override locks - the right
# balance for a demo: real protection, reversible if needed. COMPLIANCE
# mode cannot be overridden by anyone, including AWS root, until
# retention expires.
resource "aws_s3_bucket_object_lock_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 1
    }
  }
}
