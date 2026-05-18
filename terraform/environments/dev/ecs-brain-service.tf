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
      },
      # OpenTelemetry / X-Ray trace export. The brain emits OTLP-format
      # traces to the local ADOT collector sidecar over loopback; the
      # ADOT collector then assumes this task role's credentials and
      # forwards the traces to AWS X-Ray. Without these permissions the
      # ADOT collector can run but cannot ship traces.
      {
        Effect = "Allow"
        Action = [
          "xray:PutTraceSegments",
          "xray:PutTelemetryRecords",
          "xray:GetSamplingRules",
          "xray:GetSamplingTargets",
          "xray:GetSamplingStatisticSummaries"
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
        { name = "COGNITO_APP_CLIENT_IDS", value = "${aws_cognito_user_pool_client.web.id},${aws_cognito_user_pool_client.cli.id}" },
        # OpenTelemetry: send traces over loopback (UDP/HTTP 4318) to
        # the ADOT collector sidecar in this same task. opentelemetry-distro
        # auto-configures the tracer provider + OTLP HTTP exporter from
        # this env var; no in-code wiring needed.
        { name = "OTEL_EXPORTER_OTLP_ENDPOINT", value = "http://127.0.0.1:4318" },
        # Force HTTP/protobuf - Python SDK defaults to gRPC, which silently fails against an HTTP-only endpoint.
        { name = "OTEL_EXPORTER_OTLP_PROTOCOL", value = "http/protobuf" },
          # Tells opentelemetry-distro to use the AWS X-Ray ID generator.
          # X-Ray rejects W3C-format trace IDs (Phase 6B fix).
          { name = "OTEL_PYTHON_ID_GENERATOR", value = "xray" },
        # Service name shows up as the X-Ray service in the console.
        { name = "OTEL_SERVICE_NAME", value = "regops-sentinel-brain" },
        # Resource attributes ride along on every span; useful filter
        # facets in the X-Ray UI.
        { name = "OTEL_RESOURCE_ATTRIBUTES", value = "deployment.environment=${var.environment},service.namespace=regops-sentinel" }
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
    },
    # ADOT (AWS Distro for OpenTelemetry) Collector sidecar (Phase 6B).
    #
    # Receives OTLP traces from the brain over loopback (4318/HTTP and
    # 4317/gRPC are both opened by the default config), then ships them
    # to AWS X-Ray using the task role's xray:PutTraceSegments
    # permission added above.
    #
    # The collector uses the default ECS config (--config=/etc/ecs/
    # ecs-default-config.yaml): OTLP receiver enabled, AWS X-Ray
    # exporter enabled, no sampling tweaks. Sampling rules tune in
    # the X-Ray console (Sampling Rules), not the collector config,
    # so they can change without a redeploy.
    #
    # essential=false deliberately: if the collector dies, traces are
    # lost but the brain keeps serving requests. The brain's OTel
    # exporter has a local buffer and exporter-side retry.
    {
      name      = "adot-collector"
      image     = "public.ecr.aws/aws-observability/aws-otel-collector:v0.40.0"
      essential = false
      cpu       = 64
      memory    = 256
      portMappings = [
        { containerPort = 4317, hostPort = 4317, protocol = "tcp" },
        { containerPort = 4318, hostPort = 4318, protocol = "tcp" }
      ]
      # Custom OTLP-to-X-Ray pipeline. The default ECS config wires OTLP
      # port 4318 to the METRICS pipeline only, which silently drops OTLP
      # traces. This inline config exposes 4318 to the TRACES pipeline so
      # brain's OTLP traces actually reach X-Ray.
      command = ["--config=env:AOT_CONFIG_CONTENT"]
      environment = [
        { name = "AWS_REGION", value = "ca-central-1" },
        # Custom collector config: enable OTLP -> X-Ray pipeline for
        # TRACES (the default ECS config only wires OTLP to metrics,
        # which silently drops trace data).
        {
          name  = "AOT_CONFIG_CONTENT"
          value = <<-EOT
            receivers:
              otlp:
                protocols:
                  grpc:
                    endpoint: 0.0.0.0:4317
                  http:
                    endpoint: 0.0.0.0:4318
            processors:
              batch:
                timeout: 5s
            exporters:
              awsxray:
                region: ca-central-1
            service:
              pipelines:
                traces:
                  receivers: [otlp]
                  processors: [batch]
                  exporters: [awsxray]
            EOT
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.brain.name
          awslogs-region        = "ca-central-1"
          awslogs-stream-prefix = "adot"
        }
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
  desired_count   = 1
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