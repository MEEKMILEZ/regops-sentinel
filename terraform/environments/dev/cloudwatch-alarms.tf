# CloudWatch alarms for the RegOps Sentinel stack.
#
# Phase 6A. All alarms publish to aws_sns_topic.alarms when they enter
# ALARM state and when they return to OK state. The SNS topic has no
# subscribers yet - Phase 7 will wire SES email subscriptions. Alarms
# tune silently first to avoid false-positive pager fatigue.
#
# Threshold philosophy:
#   - "Page" thresholds = severity high enough to wake someone up.
#     These are configured tight (e.g. ALB 5xx >1% means real user
#     impact). Designed for SRE-style on-call rotation.
#   - "Ticket" thresholds = capacity/cost signals that should not
#     wake anyone but need attention this week (e.g. RDS storage <2GB,
#     KMS request rate trending up). These are looser.
#
# Each alarm follows the four-signals SRE pattern (latency, traffic,
# errors, saturation) per the Google SRE book. We do not have a
# saturation signal for every component (e.g. SQS has no native CPU);
# we use proxies like queue depth and message age.
#
# Naming: ${local.name_prefix}-${signal}-${component}-${suffix} so the
# SNS topic policy's ArnLike condition (alarm:regops-sentinel-*) covers
# all of them.

# =========================================================
# Brain (ALB + ECS) - user-facing service
# =========================================================

# --- Page: ALB target 5xx error rate > 1% over 5 min ---
# Real user impact. 1% over 5 min = enough volume that it is not a
# single fluke; tight enough to catch a real regression in minutes.
resource "aws_cloudwatch_metric_alarm" "alb_target_5xx_rate" {
  alarm_name        = "${local.name_prefix}-alb-target-5xx-rate-${local.full_suffix}"
  alarm_description = "Brain (ECS targets behind ALB) returning >1% 5xx responses over 5 min. Likely brain bug or DB issue."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "error_rate"
    expression  = "IF(requests > 100, 100 * errors / requests, 0)"
    label       = "5xx error rate (%)"
    return_data = true
  }

  metric_query {
    id = "errors"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "HTTPCode_Target_5XX_Count"
      period      = 300
      stat        = "Sum"
      dimensions = {
        LoadBalancer = local.dashboard_alb_name_suffix
      }
    }
  }

  metric_query {
    id = "requests"
    metric {
      namespace   = "AWS/ApplicationELB"
      metric_name = "RequestCount"
      period      = 300
      stat        = "Sum"
      dimensions = {
        LoadBalancer = local.dashboard_alb_name_suffix
      }
    }
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# --- Page: ECS service has fewer than 1 running task for 2 min ---
# Service down. The desired count is 1 (dev), production would set
# this to expect = desired_count - 1 or similar.
resource "aws_cloudwatch_metric_alarm" "ecs_brain_no_tasks" {
  alarm_name        = "${local.name_prefix}-ecs-brain-no-tasks-${local.full_suffix}"
  alarm_description = "Brain ECS service has zero running tasks for 2+ minutes. Service is DOWN."

  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  threshold           = 1
  treat_missing_data  = "breaching"

  metric_name = "RunningTaskCount"
  namespace   = "ECS/ContainerInsights"
  period      = 60
  statistic   = "Average"

  dimensions = {
    ServiceName = local.dashboard_ecs_service
    ClusterName = local.dashboard_ecs_cluster
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# --- Page: ALB target response time p99 > 5 seconds over 5 min ---
# User-perceptible latency. p99 catches the long tail without alarming
# on every single slow request. 5s is loose for dev; tighten in prod.
resource "aws_cloudwatch_metric_alarm" "alb_p99_latency" {
  alarm_name        = "${local.name_prefix}-alb-p99-latency-${local.full_suffix}"
  alarm_description = "Brain p99 latency > 5s for 5 min. DB lock, GPT-4o slowdown, or memory pressure are common causes."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_name        = "TargetResponseTime"
  namespace          = "AWS/ApplicationELB"
  period             = 300
  extended_statistic = "p99"

  dimensions = {
    LoadBalancer = local.dashboard_alb_name_suffix
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# =========================================================
# Pipeline (SQS + RDS) - backbone
# =========================================================

# --- Page: any message in the DLQ ---
# DLQ messages mean the brain failed to process an ingested signal 3+
# times (the redrive policy). Every single message is worth a human
# look; do not let DLQ accumulate silently.
resource "aws_cloudwatch_metric_alarm" "sqs_dlq_any_message" {
  alarm_name        = "${local.name_prefix}-sqs-dlq-any-${local.full_suffix}"
  alarm_description = "Ingestion DLQ has 1+ messages. A brain consumer failed to process an ingested signal."

  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_name = "ApproximateNumberOfMessagesVisible"
  namespace   = "AWS/SQS"
  period      = 300
  statistic   = "Maximum"

  dimensions = {
    QueueName = local.dashboard_sqs_dlq
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# --- Page: SQS oldest message > 5 min ---
# Backlog forming. With 1 brain task and ~30s per signal at GPT-4o
# latency, 5 min of accumulation means consumption has stopped or
# slowed dramatically.
resource "aws_cloudwatch_metric_alarm" "sqs_oldest_message_age" {
  alarm_name        = "${local.name_prefix}-sqs-oldest-message-age-${local.full_suffix}"
  alarm_description = "Ingestion SQS oldest message > 5 min. Brain consumer is stuck or scaling under traffic."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 300
  treat_missing_data  = "notBreaching"

  metric_name = "ApproximateAgeOfOldestMessage"
  namespace   = "AWS/SQS"
  period      = 300
  statistic   = "Maximum"

  dimensions = {
    QueueName = local.dashboard_sqs_queue
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# --- Ticket: RDS CPU > 80% for 10 min ---
# Capacity signal. Not a page (RDS can handle bursts), but a week-out
# capacity-planning signal that this instance class may be undersized.
resource "aws_cloudwatch_metric_alarm" "rds_cpu_sustained" {
  alarm_name        = "${local.name_prefix}-rds-cpu-sustained-${local.full_suffix}"
  alarm_description = "RDS CPU > 80% for 10+ min. Capacity planning signal; consider upsizing or adding a read replica."

  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  threshold           = 80
  treat_missing_data  = "notBreaching"

  metric_name = "CPUUtilization"
  namespace   = "AWS/RDS"
  period      = 300
  statistic   = "Average"

  dimensions = {
    DBInstanceIdentifier = local.dashboard_rds_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# --- Ticket: RDS free storage < 2 GB ---
# Capacity signal with operational urgency. Running out of storage
# breaks writes; 2 GB gives a week+ of headroom in our growth profile.
resource "aws_cloudwatch_metric_alarm" "rds_low_storage" {
  alarm_name        = "${local.name_prefix}-rds-low-storage-${local.full_suffix}"
  alarm_description = "RDS free storage < 2 GB. Plan a storage increase this week."

  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 1
  threshold           = 2147483648 # 2 GiB in bytes
  treat_missing_data  = "notBreaching"

  metric_name = "FreeStorageSpace"
  namespace   = "AWS/RDS"
  period      = 300
  statistic   = "Average"

  dimensions = {
    DBInstanceIdentifier = local.dashboard_rds_id
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# =========================================================
# Watchers (Lambda) - source ingestion
# =========================================================

# --- Page: any watcher errored in the last 30 min ---
# Lambda errors mean the regulator's site changed, the network
# flapped, or the watcher code has a bug. Any of these is a real
# signal worth a human look.
resource "aws_cloudwatch_metric_alarm" "watcher_errors" {
  for_each = local.dashboard_watcher_names

  alarm_name        = "${local.name_prefix}-watcher-${each.key}-errors-${local.full_suffix}"
  alarm_description = "Watcher ${each.key} Lambda has 1+ errors in the last 30 min. Check the function's CloudWatch logs."

  comparison_operator = "GreaterThanOrEqualToThreshold"
  evaluation_periods  = 1
  threshold           = 1
  treat_missing_data  = "notBreaching"

  metric_name = "Errors"
  namespace   = "AWS/Lambda"
  period      = 1800
  statistic   = "Sum"

  dimensions = {
    FunctionName = each.value
  }

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]

  tags = local.alarm_tags
}

# Shared tags applied to every alarm. Pulled into a local so changes
# propagate to all alarms in one place.
locals {
  alarm_tags = {
    Name        = "regops-sentinel-alarm"
    Environment = var.environment
    Phase       = "6A"
  }
}

output "cloudwatch_alarm_names" {
  description = "Names of all CloudWatch alarms in the stack"
  value = concat(
    [
      aws_cloudwatch_metric_alarm.alb_target_5xx_rate.alarm_name,
      aws_cloudwatch_metric_alarm.ecs_brain_no_tasks.alarm_name,
      aws_cloudwatch_metric_alarm.alb_p99_latency.alarm_name,
      aws_cloudwatch_metric_alarm.sqs_dlq_any_message.alarm_name,
      aws_cloudwatch_metric_alarm.sqs_oldest_message_age.alarm_name,
      aws_cloudwatch_metric_alarm.rds_cpu_sustained.alarm_name,
      aws_cloudwatch_metric_alarm.rds_low_storage.alarm_name,
    ],
    [for w in aws_cloudwatch_metric_alarm.watcher_errors : w.alarm_name]
  )
}