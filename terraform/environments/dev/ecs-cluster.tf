resource "aws_ecs_cluster" "main" {
  name = "${local.name_prefix}-cluster-${local.full_suffix}"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  configuration {
    execute_command_configuration {
      kms_key_id = aws_kms_key.main.arn
      logging    = "OVERRIDE"
      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.ecs_exec.name
      }
    }
  }

  tags = {
    Name = "${local.name_prefix}-cluster-${local.full_suffix}"
    Tier = "compute"
  }
}

resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    base              = 1
    weight            = 100
    capacity_provider = "FARGATE"
  }
}

resource "aws_cloudwatch_log_group" "ecs_exec" {
  name              = "/aws/ecs/exec/${local.name_prefix}-${local.full_suffix}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}