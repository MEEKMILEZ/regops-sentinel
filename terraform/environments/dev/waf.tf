# WAF v2 Web ACL for the Brain ALB.
#
# The Brain ALB is internet-facing (HTTP:80) which means anyone on the
# internet can reach it directly. Cognito JWT verification on the Brain
# side is the application-layer defence, but for production hygiene we
# also want an edge filter that drops common attacks before they ever
# reach an ECS task. That's what this Web ACL does.
#
# Strategy:
# - Use AWS Managed Rule groups, not hand-rolled rules. They're free
#   (within reasonable WCU budgets), maintained by AWS, and updated as
#   new threat patterns emerge. Three rule groups gives us a solid
#   minimum-viable production posture.
# - Mode = COUNT not BLOCK for the first deploy. That means matching
#   requests are logged but still pass through. We watch the CloudWatch
#   metrics for a few days, confirm no false positives against our own
#   traffic, then flip to BLOCK in a follow-up commit.
# - Capacity (WCU = Web ACL Capacity Units) is a budget AWS enforces.
#   Each rule has a published WCU cost; total can't exceed 1500 by
#   default. CommonRuleSet=700, KnownBadInputs=200, IpRep=25 -> 925.
#   Well under limit.
#
# Scope = REGIONAL is required for ALB association (CLOUDFRONT is only
# for CloudFront distributions and must be created in us-east-1).
#
# What gets blocked when we flip to BLOCK mode:
# - SQL injection, XSS, common web exploits (CommonRuleSet)
# - Log4j patterns, malformed requests, known bad signatures (KnownBadInputs)
# - Requests from known-bad source IPs maintained by AWS (IpReputation)

resource "aws_wafv2_web_acl" "brain_alb" {
  name        = "${local.name_prefix}-brain-alb-acl-${local.full_suffix}"
  description = "Edge protection for the Brain ALB. AWS Managed Rules in COUNT mode for initial deploy."
  scope       = "REGIONAL"

  default_action {
    allow {}
  }

  # Rule 1: AWS Managed - Common Rule Set
  # Covers OWASP Top 10 patterns: SQLi, XSS, RFI/LFI, generic protocol
  # abuse. The largest single rule group (700 WCU) and the highest-value
  # one. Currently in COUNT mode so we can review false positives before
  # flipping to block.
  rule {
    name     = "AWS-AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesCommonRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 2: AWS Managed - Known Bad Inputs
  # Catches known-malformed request patterns, Log4Shell, malicious
  # User-Agents, etc. Lower WCU (200) and high signal-to-noise; safe to
  # leave on BLOCK by default but we keep COUNT for consistency in this
  # initial deploy.
  rule {
    name     = "AWS-AWSManagedRulesKnownBadInputsRuleSet"
    priority = 2

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesKnownBadInputsRuleSet"
      sampled_requests_enabled   = true
    }
  }

  # Rule 3: AWS Managed - Amazon IP Reputation List
  # AWS-curated list of IPs associated with bots, scanners, and known
  # malicious sources. 25 WCU. Strong filter for noise traffic before
  # it ever hits an evaluation rule.
  rule {
    name     = "AWS-AWSManagedRulesAmazonIpReputationList"
    priority = 3

    override_action {
      count {}
    }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesAmazonIpReputationList"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "AWSManagedRulesAmazonIpReputationList"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name_prefix}-brain-alb-acl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${local.name_prefix}-brain-alb-acl-${local.full_suffix}"
    Tier = "security"
  }
}

# Associate the Web ACL with the Brain ALB. The ALB ARN comes from the
# existing aws_lb resource defined in alb.tf.
resource "aws_wafv2_web_acl_association" "brain_alb" {
  resource_arn = aws_lb.brain.arn
  web_acl_arn  = aws_wafv2_web_acl.brain_alb.arn
}

output "waf_brain_alb_acl_arn" {
  description = "ARN of the WAF Web ACL protecting the Brain ALB"
  value       = aws_wafv2_web_acl.brain_alb.arn
}
