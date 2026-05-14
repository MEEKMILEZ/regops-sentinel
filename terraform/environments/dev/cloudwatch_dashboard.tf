# CloudWatch dashboard - "RegOps Sentinel - Operations"
#
# Production observability for the RegOps Sentinel stack. Built around
# the four-signals pattern (latency, traffic, errors, saturation) per
# the Google SRE book, organised by service tier:
#
#   1. Brain    - ALB + ECS service, the user-facing surface
#   2. Watchers - 3 Lambda functions doing source ingestion
#   3. Pipeline - SQS ingestion queue (+ DLQ) + RDS Postgres
#   4. Audit    - S3 audit bucket write activity (compliance signal)
#
# The dashboard JSON is large but mechanical. Widget positions are on a
# 24-column grid; every row is 6 tall by default. The body is a
# JSON-encoded heredoc rather than the legacy widget DSL because the
# JSON form is what AWS uses internally and is what the AWS Console
# exports if you build a dashboard there first.
#
# Some widgets will be flat-line in a low-traffic dev environment. That
# is the honest state of the system - the dashboard is real, the metric
# pipes are wired, and as production traffic ramps up the widgets fill
# in. This is how every real production dashboard looks on day one.

locals {
  # Pull resource names from existing infra so the dashboard tracks the
  # right ARNs/names even if local.full_suffix changes.
  dashboard_alb_name_suffix = "app/${aws_lb.brain.name}/${element(split("/", aws_lb.brain.arn), 3)}"
  dashboard_ecs_cluster     = aws_ecs_cluster.main.name
  dashboard_ecs_service     = aws_ecs_service.brain.name
  dashboard_sqs_queue       = aws_sqs_queue.ingestion.name
  dashboard_sqs_dlq         = aws_sqs_queue.ingestion_dlq.name
  dashboard_rds_id          = aws_db_instance.main.id
  dashboard_audit_bucket    = aws_s3_bucket.audit.id

  dashboard_watcher_names = {
    medeffect = aws_lambda_function.watcher_medeffect.function_name
    recalls   = aws_lambda_function.watcher_recalls.function_name
    shortages = aws_lambda_function.watcher_shortages.function_name
  }
}

resource "aws_cloudwatch_dashboard" "ops" {
  dashboard_name = "${local.name_prefix}-ops-${local.full_suffix}"

  dashboard_body = jsonencode({
    widgets = [
      # =========================================================
      # SECTION HEADER: Brain
      # =========================================================
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 1
        properties = {
          markdown = "## Brain (ALB + ECS) - user-facing service"
        }
      },

      # ---- Brain widget 1: ALB requests + 4xx + 5xx ----
      {
        type   = "metric"
        x      = 0
        y      = 1
        width  = 12
        height = 6
        properties = {
          title   = "ALB - request count + errors"
          region  = "ca-central-1"
          stat    = "Sum"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "RequestCount", "LoadBalancer", local.dashboard_alb_name_suffix, { label = "Requests" }],
            [".", "HTTPCode_ELB_4XX_Count", ".", ".", { label = "4xx (ALB)" }],
            [".", "HTTPCode_Target_4XX_Count", ".", ".", { label = "4xx (target)" }],
            [".", "HTTPCode_Target_5XX_Count", ".", ".", { label = "5xx (target)" }],
          ]
        }
      },

      # ---- Brain widget 2: ALB target response time ----
      {
        type   = "metric"
        x      = 12
        y      = 1
        width  = 12
        height = 6
        properties = {
          title   = "ALB - target response time (p50, p99)"
          region  = "ca-central-1"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", local.dashboard_alb_name_suffix, { stat = "p50", label = "p50" }],
            ["...", { stat = "p99", label = "p99" }],
          ]
          yAxis = {
            left = {
              min   = 0
              label = "seconds"
            }
          }
        }
      },

      # ---- Brain widget 3: ECS CPU + memory ----
      {
        type   = "metric"
        x      = 0
        y      = 7
        width  = 12
        height = 6
        properties = {
          title   = "ECS - CPU + memory utilisation"
          region  = "ca-central-1"
          stat    = "Average"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/ECS", "CPUUtilization", "ServiceName", local.dashboard_ecs_service, "ClusterName", local.dashboard_ecs_cluster, { label = "CPU %" }],
            [".", "MemoryUtilization", ".", ".", ".", ".", { label = "Memory %" }],
          ]
          yAxis = {
            left = {
              min = 0
              max = 100
            }
          }
        }
      },

      # ---- Brain widget 4: ECS running task count ----
      {
        type   = "metric"
        x      = 12
        y      = 7
        width  = 12
        height = 6
        properties = {
          title   = "ECS - running task count"
          region  = "ca-central-1"
          stat    = "Average"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["ECS/ContainerInsights", "RunningTaskCount", "ServiceName", local.dashboard_ecs_service, "ClusterName", local.dashboard_ecs_cluster, { label = "Running tasks" }],
            [".", "DesiredTaskCount", ".", ".", ".", ".", { label = "Desired tasks" }],
          ]
        }
      },

      # =========================================================
      # SECTION HEADER: Watchers
      # =========================================================
      {
        type   = "text"
        x      = 0
        y      = 13
        width  = 24
        height = 1
        properties = {
          markdown = "## Watchers (Lambda) - source ingestion"
        }
      },

      # ---- Watcher widget 5: invocations per watcher ----
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - invocations"
          region  = "ca-central-1"
          stat    = "Sum"
          period  = 1800
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Invocations", "FunctionName", local.dashboard_watcher_names.medeffect, { label = "medeffect" }],
            ["...", local.dashboard_watcher_names.recalls, { label = "recalls" }],
            ["...", local.dashboard_watcher_names.shortages, { label = "shortages" }],
          ]
        }
      },

      # ---- Watcher widget 6: errors per watcher ----
      {
        type   = "metric"
        x      = 8
        y      = 14
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - errors"
          region  = "ca-central-1"
          stat    = "Sum"
          period  = 1800
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", local.dashboard_watcher_names.medeffect, { label = "medeffect" }],
            ["...", local.dashboard_watcher_names.recalls, { label = "recalls" }],
            ["...", local.dashboard_watcher_names.shortages, { label = "shortages" }],
          ]
        }
      },

      # ---- Watcher widget 7: duration p99 per watcher ----
      {
        type   = "metric"
        x      = 16
        y      = 14
        width  = 8
        height = 6
        properties = {
          title   = "Lambda - duration p99 (ms)"
          region  = "ca-central-1"
          period  = 1800
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", local.dashboard_watcher_names.medeffect, { stat = "p99", label = "medeffect" }],
            ["...", local.dashboard_watcher_names.recalls, { stat = "p99", label = "recalls" }],
            ["...", local.dashboard_watcher_names.shortages, { stat = "p99", label = "shortages" }],
          ]
        }
      },

      # =========================================================
      # SECTION HEADER: Pipeline
      # =========================================================
      {
        type   = "text"
        x      = 0
        y      = 20
        width  = 24
        height = 1
        properties = {
          markdown = "## Pipeline (SQS + RDS) - backbone"
        }
      },

      # ---- Pipeline widget 8: SQS queue depth ----
      {
        type   = "metric"
        x      = 0
        y      = 21
        width  = 6
        height = 6
        properties = {
          title   = "SQS - messages visible (backlog)"
          region  = "ca-central-1"
          stat    = "Maximum"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.dashboard_sqs_queue, { label = "Visible" }],
            [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { label = "In flight" }],
          ]
        }
      },

      # ---- Pipeline widget 9: SQS message age ----
      {
        type   = "metric"
        x      = 6
        y      = 21
        width  = 6
        height = 6
        properties = {
          title   = "SQS - oldest message age (s)"
          region  = "ca-central-1"
          stat    = "Maximum"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", local.dashboard_sqs_queue, { label = "Oldest age" }],
          ]
        }
      },

      # ---- Pipeline widget 10: DLQ depth (any non-zero = operator attention) ----
      {
        type   = "metric"
        x      = 12
        y      = 21
        width  = 6
        height = 6
        properties = {
          title   = "SQS DLQ - messages (non-zero = failure)"
          region  = "ca-central-1"
          stat    = "Maximum"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", local.dashboard_sqs_dlq, { label = "DLQ depth" }],
          ]
          annotations = {
            horizontal = [
              {
                value = 1
                label = "Any message = investigate"
                color = "#d62728"
              }
            ]
          }
        }
      },

      # ---- Pipeline widget 11: RDS CPU + connections ----
      {
        type   = "metric"
        x      = 18
        y      = 21
        width  = 6
        height = 6
        properties = {
          title   = "RDS - CPU + connections"
          region  = "ca-central-1"
          period  = 300
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/RDS", "CPUUtilization", "DBInstanceIdentifier", local.dashboard_rds_id, { stat = "Average", label = "CPU %" }],
            [".", "DatabaseConnections", ".", ".", { stat = "Average", label = "Connections", yAxis = "right" }],
          ]
          yAxis = {
            left  = { min = 0, max = 100, label = "CPU %" }
            right = { min = 0, label = "connections" }
          }
        }
      },

      # =========================================================
      # SECTION HEADER: Audit
      # =========================================================
      {
        type   = "text"
        x      = 0
        y      = 27
        width  = 24
        height = 1
        properties = {
          markdown = "## Audit (S3) - compliance signal"
        }
      },

      # ---- Audit widget 12: S3 audit object count ----
      {
        type   = "metric"
        x      = 0
        y      = 28
        width  = 12
        height = 6
        properties = {
          title   = "S3 audit bucket - object count"
          region  = "ca-central-1"
          stat    = "Average"
          period  = 86400
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/S3", "NumberOfObjects", "BucketName", local.dashboard_audit_bucket, "StorageType", "AllStorageTypes", { label = "Audit objects" }],
          ]
        }
      },

      # ---- Audit widget 13: audit bucket bytes stored ----
      {
        type   = "metric"
        x      = 12
        y      = 28
        width  = 12
        height = 6
        properties = {
          title   = "S3 audit bucket - bytes stored"
          region  = "ca-central-1"
          stat    = "Average"
          period  = 86400
          view    = "timeSeries"
          stacked = false
          metrics = [
            ["AWS/S3", "BucketSizeBytes", "BucketName", local.dashboard_audit_bucket, "StorageType", "StandardStorage", { label = "Standard" }],
          ]
        }
      },
    ]
  })
}

output "cloudwatch_dashboard_name" {
  description = "Name of the operations CloudWatch dashboard"
  value       = aws_cloudwatch_dashboard.ops.dashboard_name
}

output "cloudwatch_dashboard_url" {
  description = "Direct link to the operations CloudWatch dashboard"
  value       = "https://console.aws.amazon.com/cloudwatch/home?region=ca-central-1#dashboards:name=${aws_cloudwatch_dashboard.ops.dashboard_name}"
}
