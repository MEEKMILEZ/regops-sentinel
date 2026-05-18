# =====================================================================
# AWS Config (Phase 5 Security Hardening, screenshot #41)
# =====================================================================
#
# AWS Config continuously records the configuration of every supported
# resource in this account and stores a complete change history. This
# is the audit trail at the resource-configuration layer, distinct
# from CloudTrail (API-call audit) and application-layer audit blobs.
#
# Storage decision: Config logs go to a DEDICATED bucket
# (regops-sentinel-dev-config-1a8df723), NOT the audit bucket. AWS
# Config does not support Object Lock with default retention on its
# delivery bucket - documented at:
#   https://docs.aws.amazon.com/config/latest/developerguide/manage-delivery-channel.html
# The audit bucket has Object Lock GOVERNANCE with 1-day default
# retention (Phase 5D), so it's incompatible. Rather than weaken the
# audit bucket's immutability guarantees, Config gets its own bucket.
#
# Scope decision: recorder + delivery channel only. No conformance
# pack. A conformance pack would add ~$8-15/month for rule
# evaluations; deferred to a customer-specific production deployment.
#
# Cost with recorder only: ~$1-2/month at this project's resource
# count.
# =====================================================================


# ---------------------------------------------------------------------
# Dedicated Config bucket
# ---------------------------------------------------------------------
# Standard hardening: KMS-encrypted, versioned, public access blocked,
# Bucket Key enabled. NO Object Lock - that's the whole point of the
# bucket existing separately from the audit bucket.
resource "aws_s3_bucket" "config" {
  bucket        = "${local.name_prefix}-config-${local.full_suffix}"
  force_destroy = false

  tags = {
    Name = "${local.name_prefix}-config-${local.full_suffix}"
    Tier = "audit"
  }
}

resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}


# ---------------------------------------------------------------------
# Bucket policy granting AWS Config write access to its own bucket.
# Two statements per the AWS documented pattern:
# https://docs.aws.amazon.com/config/latest/developerguide/s3-bucket-policy.html
# ---------------------------------------------------------------------
resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSConfigAclCheck"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
      },
      {
        Sid    = "AWSConfigWrite"
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/575751781190/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      }
    ]
  })
}


# ---------------------------------------------------------------------
# IAM role for the Config recorder. Uses the modern AWS_ConfigRole
# managed policy (AWSConfigRole was deprecated 2022).
# ---------------------------------------------------------------------
resource "aws_iam_role" "config_recorder" {
  name = "${local.name_prefix}-config-recorder-${local.full_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "config.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-config-recorder-${local.full_suffix}"
    Tier = "iam"
  }
}

resource "aws_iam_role_policy_attachment" "config_recorder_managed" {
  role       = aws_iam_role.config_recorder.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

# Inline policy for S3 write + KMS use. References the Config bucket
# (not the audit bucket).
resource "aws_iam_role_policy" "config_recorder_s3_write" {
  name = "${local.name_prefix}-config-recorder-s3-write-${local.full_suffix}"
  role = aws_iam_role.config_recorder.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "s3:GetBucketAcl"
        Resource = aws_s3_bucket.config.arn
      },
      {
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "${aws_s3_bucket.config.arn}/AWSLogs/575751781190/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl" = "bucket-owner-full-control"
          }
        }
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
        ]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}


# ---------------------------------------------------------------------
# The recorder itself.
# ---------------------------------------------------------------------
resource "aws_config_configuration_recorder" "main" {
  name     = "${local.name_prefix}-config-recorder-${local.full_suffix}"
  role_arn = aws_iam_role.config_recorder.arn

  recording_group {
    all_supported                 = true
    include_global_resource_types = true
  }
}


# ---------------------------------------------------------------------
# Delivery channel - points at the dedicated Config bucket.
# No s3_key_prefix needed since the bucket is dedicated; Config will
# write directly under AWSLogs/<account-id>/Config/...
# ---------------------------------------------------------------------
resource "aws_config_delivery_channel" "main" {
  name           = "${local.name_prefix}-config-delivery-${local.full_suffix}"
  s3_bucket_name = aws_s3_bucket.config.id
  s3_kms_key_arn = aws_kms_key.main.arn

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [
    aws_config_configuration_recorder.main,
    aws_s3_bucket_policy.config,
    aws_iam_role_policy.config_recorder_s3_write,
    aws_iam_role_policy_attachment.config_recorder_managed,
  ]
}


# ---------------------------------------------------------------------
# Start the recorder.
# ---------------------------------------------------------------------
resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}


output "config_recorder_name" {
  value       = aws_config_configuration_recorder.main.name
  description = "Name of the AWS Config recorder"
}

output "config_bucket_name" {
  value       = aws_s3_bucket.config.id
  description = "Dedicated S3 bucket where Config writes snapshots"
}
