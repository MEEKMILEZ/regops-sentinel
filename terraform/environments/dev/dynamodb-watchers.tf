resource "aws_dynamodb_table" "watcher_state" {
  name         = "${local.name_prefix}-watcher-state-${local.full_suffix}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "watcher_name"

  attribute {
    name = "watcher_name"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.main.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  tags = {
    Name = "${local.name_prefix}-watcher-state-${local.full_suffix}"
    Tier = "data"
  }
}