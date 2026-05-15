# SNS topic for CloudWatch alarm notifications.
#
# Phase 6A wires alarms to publish here; Phase 7 will add an SES-based
# email subscription so the on-call rotation gets paged. Today the
# topic exists, alarms publish to it, but no subscribers means
# notifications fan out nowhere. That is intentional - getting alarms
# wrong (false positives, alarm-fatigue thresholds) is much worse than
# getting them late, so we tune them silently first.
#
# Encrypted at rest with the project KMS key. The aws/sns managed key
# would work but using our customer-managed key keeps key usage in one
# auditable place (we already have aws_kms_key.main).

resource "aws_sns_topic" "alarms" {
  name              = "${local.name_prefix}-alarms-${local.full_suffix}"
  kms_master_key_id = aws_kms_key.main.id

  tags = {
    Name        = "${local.name_prefix}-alarms-${local.full_suffix}"
    Environment = var.environment
    Purpose     = "CloudWatch alarm notifications"
  }
}

# Allow CloudWatch alarms to publish to this topic. Default SNS topic
# policy only allows the topic owner; alarms need an explicit grant.
resource "aws_sns_topic_policy" "alarms_cloudwatch_publish" {
  arn = aws_sns_topic.alarms.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudWatchAlarmsToPublish"
        Effect = "Allow"
        Principal = {
          Service = "cloudwatch.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.alarms.arn
        Condition = {
          ArnLike = {
            "aws:SourceArn" = "arn:aws:cloudwatch:ca-central-1:${data.aws_caller_identity.current.account_id}:alarm:${local.name_prefix}-*"
          }
        }
      }
    ]
  })
}

# aws_caller_identity is read elsewhere; declare here as a data source
# only if not already present. The codebuild file may also need it -
# Terraform is fine with duplicate `data` blocks across files as long
# as the names match.
data "aws_caller_identity" "current" {}

output "alarms_sns_topic_arn" {
  description = "SNS topic ARN that CloudWatch alarms publish to"
  value       = aws_sns_topic.alarms.arn
}