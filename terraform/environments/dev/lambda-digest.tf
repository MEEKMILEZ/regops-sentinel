# =====================================================================
# Phase 7: Weekly digest Lambda
# =====================================================================
#
# Scheduled Lambda that summarises the past week of regulatory
# activity and emails a digest via SES. Standard AWS pattern:
#
#   EventBridge cron rule -> Lambda -> RDS query -> SES SendEmail
#
# Reference architectures:
#   - https://docs.aws.amazon.com/lambda/latest/dg/services-cloudwatchevents.html
#   - https://docs.aws.amazon.com/ses/latest/dg/send-email-formatted.html
#
# Production maturity items deferred (not part of Phase 7 MVP):
#   - DynamoDB subscribers table (currently a comma-separated env var)
#   - Multi-tenant fan-out (currently runs against one tenant)
#   - RDS Proxy for connection pooling (one connection per invocation)
#   - SES production-access request (currently in sandbox, 200/day)
#   - Lambda Layer for psycopg (currently bundled in deployment zip)
# =====================================================================


# ---------------------------------------------------------------------
# Lambda deployment package
# ---------------------------------------------------------------------
# Reference the pre-built deployment package in S3. Terraform doesn't
# build it - we keep the build in a separate PowerShell step so it
# only runs when code changes, not on every plan.
locals {
  digest_lambda_s3_key = "digest-lambda/digest-${local.full_suffix}.zip"
}


# ---------------------------------------------------------------------
# CloudWatch log group
# ---------------------------------------------------------------------
# Lambda auto-creates /aws/lambda/<name> if absent, but defining it
# explicitly lets us set retention and KMS encryption upfront.
resource "aws_cloudwatch_log_group" "digest_weekly" {
  name              = "/aws/lambda/${local.name_prefix}-digest-weekly-${local.full_suffix}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn

  tags = {
    Name = "${local.name_prefix}-digest-weekly-${local.full_suffix}"
    Tier = "compute"
  }
}


# ---------------------------------------------------------------------
# IAM execution role
# ---------------------------------------------------------------------
resource "aws_iam_role" "digest_weekly" {
  name = "${local.name_prefix}-digest-weekly-role-${local.full_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${local.name_prefix}-digest-weekly-role-${local.full_suffix}"
    Tier = "iam"
  }
}

# AWS-managed policy for basic Lambda + VPC networking permissions.
# Includes: CloudWatch logs write, ENI create/describe/delete for VPC
# networking. Documented as the standard role for VPC-attached
# Lambda: https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html
resource "aws_iam_role_policy_attachment" "digest_weekly_vpc" {
  role       = aws_iam_role.digest_weekly.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# Inline policy for the Lambda's own work: read DB secret, send email,
# decrypt log group encryption key.
resource "aws_iam_role_policy" "digest_weekly" {
  name = "${local.name_prefix}-digest-weekly-policy-${local.full_suffix}"
  role = aws_iam_role.digest_weekly.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadDbSecret"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret",
        ]
        Resource = aws_secretsmanager_secret.db_master.arn
      },
      {
        Sid    = "DecryptSecretAndLogs"
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
        ]
        Resource = aws_kms_key.main.arn
      },
      {
        Sid      = "SendEmailViaSES"
        Effect   = "Allow"
        Action   = ["ses:SendEmail", "ses:SendRawEmail"]
        Resource = "*"
        # SES doesn't support resource-level perms on SendEmail
        # in most regions; the From address is enforced by SES
        # itself rejecting unverified identities.
      },
    ]
  })
}


# ---------------------------------------------------------------------
# Security group for the Lambda's VPC ENIs
# ---------------------------------------------------------------------
# Outbound only: to RDS on 5432, and to anywhere on 443 (Secrets
# Manager, SES API endpoints, both reached via the NAT gateway).
resource "aws_security_group" "digest_weekly" {
  name        = "${local.name_prefix}-digest-weekly-sg-${local.full_suffix}"
  description = "Egress-only SG for the weekly digest Lambda"
  vpc_id      = aws_vpc.main.id

  egress {
    description     = "Postgres to RDS"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.rds.id]
  }

  egress {
    description = "HTTPS to AWS APIs (Secrets Manager, SES)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${local.name_prefix}-digest-weekly-sg-${local.full_suffix}"
    Tier = "network"
  }
}

# Allow the Lambda SG to talk to RDS on 5432. This is the other
# side of the egress rule above - RDS SG explicitly accepts traffic
# from this SG.
resource "aws_security_group_rule" "rds_from_digest_lambda" {
  type                     = "ingress"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = aws_security_group.rds.id
  source_security_group_id = aws_security_group.digest_weekly.id
  description              = "Postgres ingress from digest Lambda"
}


# ---------------------------------------------------------------------
# Lambda function
# ---------------------------------------------------------------------
resource "aws_lambda_function" "digest_weekly" {
  function_name = "${local.name_prefix}-digest-weekly-${local.full_suffix}"
  role          = aws_iam_role.digest_weekly.arn

  s3_bucket = aws_s3_bucket.codebuild_artifacts.id
  s3_key    = local.digest_lambda_s3_key

  handler = "handler.lambda_handler"
  runtime = "python3.12"

  # 512 MiB - generous for a small handler with psycopg overhead.
  # Lambda CPU scales with memory, so this also speeds up cold start.
  memory_size = 512

  # 60s is comfortable for ~4 DB queries + 1 SES SendEmail call.
  # Default 3s is too short for VPC-attached Lambda cold starts.
  timeout = 60

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.digest_weekly.id]
  }

  environment {
    variables = {
      DB_SECRET_ARN     = aws_secretsmanager_secret.db_master.arn
      DB_HOST           = aws_db_instance.main.address
      DB_NAME           = aws_db_instance.main.db_name
      DB_PORT           = tostring(aws_db_instance.main.port)
      SES_FROM_ADDRESS  = var.digest_from_address
      SES_REGION        = "ca-central-1"
      DIGEST_RECIPIENTS = var.digest_recipients
      DIGEST_TENANT_ID  = "tenant-acme-meddev"
      LOG_LEVEL         = "INFO"
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.digest_weekly,
    aws_iam_role_policy_attachment.digest_weekly_vpc,
    aws_iam_role_policy.digest_weekly,
  ]

  tags = {
    Name = "${local.name_prefix}-digest-weekly-${local.full_suffix}"
    Tier = "compute"
  }
}


# ---------------------------------------------------------------------
# EventBridge schedule rule
# ---------------------------------------------------------------------
# Cron syntax in EventBridge: `cron(minute hour day-of-month month
# day-of-week year)`. Note: day-of-month OR day-of-week, never both
# (use `?` for the unused one).
#
# Schedule: Mondays at 13:00 UTC = 8:00 AM Toronto in winter / 9:00
# AM in summer. Standard "Monday morning briefing" cadence.
resource "aws_cloudwatch_event_rule" "digest_weekly" {
  name                = "${local.name_prefix}-digest-weekly-schedule-${local.full_suffix}"
  description         = "Triggers the weekly regulatory digest Lambda every Monday at 13:00 UTC"
  schedule_expression = "cron(0 13 ? * MON *)"
  state               = "ENABLED"

  tags = {
    Name = "${local.name_prefix}-digest-weekly-schedule-${local.full_suffix}"
    Tier = "scheduling"
  }
}

resource "aws_cloudwatch_event_target" "digest_weekly" {
  rule      = aws_cloudwatch_event_rule.digest_weekly.name
  target_id = "digest-weekly-lambda"
  arn       = aws_lambda_function.digest_weekly.arn
}

resource "aws_lambda_permission" "digest_weekly_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.digest_weekly.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.digest_weekly.arn
}


# ---------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------
output "digest_lambda_name" {
  value       = aws_lambda_function.digest_weekly.function_name
  description = "Name of the weekly digest Lambda function"
}

output "digest_schedule_expression" {
  value       = aws_cloudwatch_event_rule.digest_weekly.schedule_expression
  description = "Cron expression for the digest schedule"
}
