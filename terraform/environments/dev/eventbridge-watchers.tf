resource "aws_cloudwatch_event_rule" "watcher_recalls" {
  name                = "${local.name_prefix}-watcher-recalls-schedule-${local.full_suffix}"
  description         = "Trigger recalls watcher every 30 minutes"
  schedule_expression = "rate(30 minutes)"

  tags = {
    Name = "${local.name_prefix}-watcher-recalls-schedule-${local.full_suffix}"
  }
}

resource "aws_cloudwatch_event_target" "watcher_recalls" {
  rule      = aws_cloudwatch_event_rule.watcher_recalls.name
  target_id = "recalls-lambda"
  arn       = aws_lambda_function.watcher_recalls.arn
}

resource "aws_lambda_permission" "watcher_recalls_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridgeRecalls"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watcher_recalls.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.watcher_recalls.arn
}

resource "aws_cloudwatch_event_rule" "watcher_medeffect" {
  name                = "${local.name_prefix}-watcher-medeffect-schedule-${local.full_suffix}"
  description         = "Trigger MedEffect watcher every 30 minutes"
  schedule_expression = "rate(30 minutes)"

  tags = {
    Name = "${local.name_prefix}-watcher-medeffect-schedule-${local.full_suffix}"
  }
}

resource "aws_cloudwatch_event_target" "watcher_medeffect" {
  rule      = aws_cloudwatch_event_rule.watcher_medeffect.name
  target_id = "medeffect-lambda"
  arn       = aws_lambda_function.watcher_medeffect.arn
}

resource "aws_lambda_permission" "watcher_medeffect_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridgeMedeffect"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watcher_medeffect.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.watcher_medeffect.arn
}

resource "aws_cloudwatch_event_rule" "watcher_shortages" {
  name                = "${local.name_prefix}-watcher-shortages-schedule-${local.full_suffix}"
  description         = "Trigger shortages watcher every 30 minutes"
  schedule_expression = "rate(30 minutes)"

  tags = {
    Name = "${local.name_prefix}-watcher-shortages-schedule-${local.full_suffix}"
  }
}

resource "aws_cloudwatch_event_target" "watcher_shortages" {
  rule      = aws_cloudwatch_event_rule.watcher_shortages.name
  target_id = "shortages-lambda"
  arn       = aws_lambda_function.watcher_shortages.arn
}

resource "aws_lambda_permission" "watcher_shortages_eventbridge" {
  statement_id  = "AllowExecutionFromEventBridgeShortages"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.watcher_shortages.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.watcher_shortages.arn
}