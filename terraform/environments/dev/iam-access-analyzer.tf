# =====================================================================
# IAM Access Analyzer (Phase 5 Security Hardening, screenshot #43)
# =====================================================================
#
# AWS Access Analyzer continuously monitors resource-based policies
# (IAM roles, S3 buckets, KMS keys, Lambda functions, SQS queues, and
# Secrets Manager secrets) for unintended external access. It's free
# at the account scope. Documented at:
#   https://docs.aws.amazon.com/IAM/latest/UserGuide/what-is-access-analyzer.html
#
# Two analyzer types exist: ACCOUNT (scans this account only) and
# ORGANIZATION (scans across an AWS Organizations org). This project
# uses a single account, so ACCOUNT is the correct choice; ORGANIZATION
# would require AWS Organizations + delegated admin setup.
#
# Findings are visible in the IAM console under Access Analyzer. For a
# clean dev environment with no intentional cross-account or public
# access, the expected finding count is zero.
# =====================================================================

resource "aws_accessanalyzer_analyzer" "main" {
  analyzer_name = "${local.name_prefix}-access-analyzer-${local.full_suffix}"
  type          = "ACCOUNT"

  tags = {
    Name = "${local.name_prefix}-access-analyzer-${local.full_suffix}"
    Tier = "iam"
  }
}

output "access_analyzer_arn" {
  value       = aws_accessanalyzer_analyzer.main.arn
  description = "ARN of the account-scoped IAM Access Analyzer"
}
