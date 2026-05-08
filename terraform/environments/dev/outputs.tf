output "vpc_id" {
  value = aws_vpc.main.id
}

output "vpc_cidr" {
  value = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  value = aws_subnet.private[*].id
}

output "data_subnet_ids" {
  value = aws_subnet.data[*].id
}

output "alb_security_group_id" {
  value = aws_security_group.alb.id
}

output "ecs_security_group_id" {
  value = aws_security_group.ecs_tasks.id
}

output "rds_security_group_id" {
  value = aws_security_group.rds.id
}

output "flow_logs_log_group" {
  value = aws_cloudwatch_log_group.vpc_flow_logs.name
}

output "kms_key_arn" {
  value = aws_kms_key.main.arn
}

output "kms_key_alias" {
  value = aws_kms_alias.main.name
}

output "db_secret_arn" {
  value     = aws_secretsmanager_secret.db_master.arn
  sensitive = true
}

output "db_secret_name" {
  value = aws_secretsmanager_secret.db_master.name
}

output "db_address" {
  value = aws_db_instance.main.address
}

output "db_port" {
  value = aws_db_instance.main.port
}

output "db_name" {
  value = aws_db_instance.main.db_name
}

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_arn" {
  value = aws_cognito_user_pool.main.arn
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}
output "sqs_ingestion_url" {
  value = aws_sqs_queue.ingestion.url
}

output "sqs_ingestion_arn" {
  value = aws_sqs_queue.ingestion.arn
}

output "watcher_state_table" {
  value = aws_dynamodb_table.watcher_state.name
}

output "watcher_recalls_arn" {
  value = aws_lambda_function.watcher_recalls.arn
}

output "watcher_medeffect_arn" {
  value = aws_lambda_function.watcher_medeffect.arn
}

output "watcher_shortages_arn" {
  value = aws_lambda_function.watcher_shortages.arn
}