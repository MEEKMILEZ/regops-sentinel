resource "aws_kms_key" "main" {
  description             = "RegOps Sentinel customer-managed key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableRootPermissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::575751781190:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "AllowAWSServicesUseOfTheKey"
        Effect = "Allow"
        Principal = {
          Service = [
            "rds.amazonaws.com",
            "secretsmanager.amazonaws.com",
            "sqs.amazonaws.com",
            "dynamodb.amazonaws.com",
            "logs.ca-central-1.amazonaws.com",
            "cloudtrail.amazonaws.com",
            "config.amazonaws.com"
          ]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:DescribeKey",
          "kms:CreateGrant"
        ]
        Resource = "*"
      }
    ]
  })

  tags = {
    Name = "${local.name_prefix}-kms-${local.full_suffix}"
  }
}

resource "aws_kms_alias" "main" {
  name          = "alias/${local.name_prefix}-${local.full_suffix}"
  target_key_id = aws_kms_key.main.key_id
}