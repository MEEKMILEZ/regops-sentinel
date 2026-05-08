resource "aws_db_subnet_group" "main" {
  name        = "${local.name_prefix}-db-subnet-${local.full_suffix}"
  description = "RDS subnet group for RegOps Sentinel ${var.environment} data tier"
  subnet_ids  = aws_subnet.data[*].id

  tags = {
    Name = "${local.name_prefix}-db-subnet-${local.full_suffix}"
    Tier = "data"
  }
}

resource "aws_db_parameter_group" "main" {
  name        = "${local.name_prefix}-pg-params-${local.full_suffix}"
  family      = "postgres16"
  description = "RegOps Sentinel PostgreSQL parameter group"

  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }

  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  tags = {
    Name = "${local.name_prefix}-pg-params-${local.full_suffix}"
  }
}

resource "aws_db_instance" "main" {
  identifier = "${local.name_prefix}-db-${local.full_suffix}"

  engine               = "postgres"
  engine_version       = var.db_engine_version
  instance_class       = var.db_instance_class
  parameter_group_name = aws_db_parameter_group.main.name

  allocated_storage     = var.db_allocated_storage
  max_allocated_storage = var.db_max_allocated_storage
  storage_type          = "gp3"
  storage_encrypted     = true
  kms_key_id            = aws_kms_key.main.arn

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db_master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false

  multi_az          = var.db_multi_az
  apply_immediately = true

  backup_retention_period = var.db_backup_retention_days
  backup_window           = "06:00-07:00"
  maintenance_window      = "sun:07:00-sun:08:00"

  performance_insights_enabled          = true
  performance_insights_kms_key_id       = aws_kms_key.main.arn
  performance_insights_retention_period = 7
  enabled_cloudwatch_logs_exports       = ["postgresql", "upgrade"]

  deletion_protection      = var.db_deletion_protection
  skip_final_snapshot      = true
  copy_tags_to_snapshot    = true
  delete_automated_backups = true

  auto_minor_version_upgrade = true

  tags = {
    Name = "${local.name_prefix}-db-${local.full_suffix}"
    Tier = "data"
  }

  depends_on = [
    aws_secretsmanager_secret_version.db_master
  ]
}

resource "aws_secretsmanager_secret_version" "db_master_with_endpoint" {
  secret_id = aws_secretsmanager_secret.db_master.id
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db_master.result
    engine   = "postgres"
    host     = aws_db_instance.main.address
    port     = aws_db_instance.main.port
    dbname   = var.db_name
  })

  depends_on = [aws_db_instance.main]
}