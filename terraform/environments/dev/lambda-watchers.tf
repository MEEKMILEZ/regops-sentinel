data "aws_secretsmanager_secret" "hpsc_creds" {
  name = "regops-sentinel-dev-hpsc-creds-1a8df723"
}

resource "aws_iam_role" "watcher_lambda" {
  name = "${local.name_prefix}-watcher-role-${local.full_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "watcher_lambda" {
  name = "${local.name_prefix}-watcher-policy-${local.full_suffix}"
  role = aws_iam_role.watcher_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:ca-central-1:575751781190:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = aws_sqs_queue.ingestion.arn
      },
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ]
        Resource = aws_dynamodb_table.watcher_state.arn
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = data.aws_secretsmanager_secret.hpsc_creds.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.main.arn
      }
    ]
  })
}

data "archive_file" "watcher_recalls" {
  type        = "zip"
  source_dir  = "${path.module}/../../../app/watchers/recalls"
  output_path = "${path.module}/build/watcher_recalls.zip"
}

data "archive_file" "watcher_medeffect" {
  type        = "zip"
  source_dir  = "${path.module}/../../../app/watchers/medeffect"
  output_path = "${path.module}/build/watcher_medeffect.zip"
}

data "archive_file" "watcher_shortages" {
  type        = "zip"
  source_dir  = "${path.module}/../../../app/watchers/shortages"
  output_path = "${path.module}/build/watcher_shortages.zip"
}

resource "aws_lambda_function" "watcher_recalls" {
  function_name    = "${local.name_prefix}-watcher-recalls-${local.full_suffix}"
  role             = aws_iam_role.watcher_lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.watcher_recalls.output_path
  source_code_hash = data.archive_file.watcher_recalls.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL       = aws_sqs_queue.ingestion.url
      WATCHER_STATE_TABLE = aws_dynamodb_table.watcher_state.name
      WATCHER_NAME        = "recalls"
    }
  }

  tags = {
    Name = "${local.name_prefix}-watcher-recalls-${local.full_suffix}"
    Tier = "ingestion"
  }
}

resource "aws_lambda_function" "watcher_medeffect" {
  function_name    = "${local.name_prefix}-watcher-medeffect-${local.full_suffix}"
  role             = aws_iam_role.watcher_lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 60
  memory_size      = 256
  filename         = data.archive_file.watcher_medeffect.output_path
  source_code_hash = data.archive_file.watcher_medeffect.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL       = aws_sqs_queue.ingestion.url
      WATCHER_STATE_TABLE = aws_dynamodb_table.watcher_state.name
      WATCHER_NAME        = "medeffect"
    }
  }

  tags = {
    Name = "${local.name_prefix}-watcher-medeffect-${local.full_suffix}"
    Tier = "ingestion"
  }
}

resource "aws_lambda_function" "watcher_shortages" {
  function_name    = "${local.name_prefix}-watcher-shortages-${local.full_suffix}"
  role             = aws_iam_role.watcher_lambda.arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = 120
  memory_size      = 256
  filename         = data.archive_file.watcher_shortages.output_path
  source_code_hash = data.archive_file.watcher_shortages.output_base64sha256

  environment {
    variables = {
      SQS_QUEUE_URL       = aws_sqs_queue.ingestion.url
      WATCHER_STATE_TABLE = aws_dynamodb_table.watcher_state.name
      WATCHER_NAME        = "shortages"
      HPSC_SECRET_ARN     = data.aws_secretsmanager_secret.hpsc_creds.arn
    }
  }

  tags = {
    Name = "${local.name_prefix}-watcher-shortages-${local.full_suffix}"
    Tier = "ingestion"
  }
}

resource "aws_cloudwatch_log_group" "watcher_recalls" {
  name              = "/aws/lambda/${aws_lambda_function.watcher_recalls.function_name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "watcher_medeffect" {
  name              = "/aws/lambda/${aws_lambda_function.watcher_medeffect.function_name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_cloudwatch_log_group" "watcher_shortages" {
  name              = "/aws/lambda/${aws_lambda_function.watcher_shortages.function_name}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}