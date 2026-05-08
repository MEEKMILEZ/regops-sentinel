resource "aws_sqs_queue" "ingestion_dlq" {
  name                      = "${local.name_prefix}-ingestion-dlq-${local.full_suffix}"
  message_retention_seconds = 1209600
  kms_master_key_id         = aws_kms_key.main.arn

  tags = {
    Name = "${local.name_prefix}-ingestion-dlq-${local.full_suffix}"
    Tier = "messaging"
  }
}

resource "aws_sqs_queue" "ingestion" {
  name                      = "${local.name_prefix}-ingestion-${local.full_suffix}"
  visibility_timeout_seconds = 300
  message_retention_seconds  = 345600
  kms_master_key_id          = aws_kms_key.main.arn

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.ingestion_dlq.arn
    maxReceiveCount     = 3
  })

  tags = {
    Name = "${local.name_prefix}-ingestion-${local.full_suffix}"
    Tier = "messaging"
  }
}