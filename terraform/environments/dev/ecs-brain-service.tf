data "aws_secretsmanager_secret" "azure_openai" {
  name = "regops-sentinel-dev-azure-openai-1a8df723"
}

resource "aws_iam_role" "ecs_task_execution" {
  name = "${local.name_prefix}-ecs-exec-role-${local.full_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ecs_task_execution_extras" {
  name = "${local.name_prefix}-ecs-exec-extras-${local.full_suffix}"
  role = aws_iam_role.ecs_task_execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.main.arn
      },
      {
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue"]
        Resource = [
          aws_secretsmanager_secret.db_master.arn,
          data.aws_secretsmanager_secret.azure_openai.arn
        ]
      }
    ]
  })
}

resource "aws_iam_role" "brain_task" {
  name = "${local.name_prefix}-brain-task-role-${local.full_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "brain_task" {
  name = "${local.name_prefix}-brain-task-policy-${local.full_suffix}"
  role = aws_iam_role.brain_task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ]
        Resource = aws_sqs_queue.ingestion.arn
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          aws_secretsmanager_secret.db_master.arn,
          data.aws_secretsmanager_secret.azure_openai.arn
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey"
        ]
        Resource = aws_kms_key.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.audit.arn,
          "${aws_s3_bucket.audit.arn}/*"
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:ca-central-1:575751781190:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ssmmessages:CreateControlChannel",
          "ssmmessages:CreateDataChannel",
          "ssmmessages:OpenControlChannel",
          "ssmmessages:OpenDataChannel"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "brain" {
  name              = "/aws/ecs/${local.name_prefix}-brain-${local.full_suffix}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_ecs_task_definition" "brain" {
  family                   = "${local.name_prefix}-brain-${local.full_suffix}"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"
  memory                   = "1024"
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.brain_task.arn

  container_definitions = jsonencode([
    {
      name      = "brain"
      image     = "${aws_ecr_repository.brain.repository_url}:latest"
      essential = true
      portMappings = [
        {
          containerPort = 8000
          hostPort      = 8000
          protocol      = "tcp"
        }
      ]
      environment = [
        { name = "AWS_REGION", value = "ca-central-1" },
        { name = "ENVIRONMENT", value = var.environment },
        { name = "LOG_LEVEL", value = "INFO" },
        { name = "SQS_QUEUE_URL", value = aws_sqs_queue.ingestion.url },
        { name = "S3_AUDIT_BUCKET", value = aws_s3_bucket.audit.id },
        { name = "DB_SECRET_ARN", value = aws_secretsmanager_secret.db_master.arn },
        { name = "AZURE_OPENAI_SECRET_ARN", value = data.aws_secretsmanager_secret.azure_openai.arn },
        { name = "AUDIT_KMS_KEY_ARN", value = aws_kms_key.main.arn },
          { name = "COGNITO_APP_CLIENT_IDS", value = "${aws_cognito_user_pool_client.web.id},${aws_cognito_user_pool_client.cli.id}" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.brain.name
          awslogs-region        = "ca-central-1"
          awslogs-stream-prefix = "brain"
        }
      }
      healthCheck = {
        command     = ["CMD-SHELL", "curl -f http://localhost:8000/health || exit 1"]
        interval    = 30
        timeout     = 10
        retries     = 3
        startPeriod = 60
      }
    }
  ])

  tags = {
    Name = "${local.name_prefix}-brain-${local.full_suffix}"
    Tier = "compute"
  }
}

resource "aws_ecs_service" "brain" {
  name            = "${local.name_prefix}-brain-${local.full_suffix}"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.brain.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.ecs_tasks.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.brain.arn
    container_name   = "brain"
    container_port   = 8000
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_minimum_healthy_percent = 50
  deployment_maximum_percent         = 200

  health_check_grace_period_seconds = 90

  tags = {
    Name = "${local.name_prefix}-brain-${local.full_suffix}"
    Tier = "compute"
  }

  lifecycle {
    ignore_changes = [desired_count, task_definition]
  }
}