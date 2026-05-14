# GuardDuty - AWS's managed threat detection service.
#
# Why we have this:
# - Healthcare-flavoured workloads in a regulated industry require
#   continuous threat monitoring as a default control. GuardDuty
#   inspects CloudTrail management events, VPC Flow Logs, and DNS query
#   logs to surface compromised credentials, port scans, anomalous S3
#   access, malicious IPs, and so on. No agent install required.
#
# Cost: free for the first 30 days per region per account, then usage-
# based. For a workload this size (single ECS service, three Lambdas,
# one ALB), expect a few CAD per month. Cheap insurance for a portfolio
# project that wants to demonstrate production hygiene.
#
# What gets monitored once the detector exists:
# - CloudTrail (management events) - enabled by default
# - VPC Flow Logs - enabled by default
# - DNS logs - enabled by default
# - S3 protection - enabled explicitly below; surfaces suspicious S3
#   access patterns against the audit bucket and other tenant data
# - EKS / Malware Protection / RDS Login Events / Lambda are paid add-
#   ons; we leave them off for cost reasons but they're one-line opt-ins.

resource "aws_guardduty_detector" "main" {
  enable = true

  # Findings publish frequency. FIFTEEN_MINUTES is the lowest setting,
  # which means findings hit CloudWatch Events / EventBridge within 15
  # min of detection. The other options are ONE_HOUR and SIX_HOURS.
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  datasources {
    s3_logs {
      enable = true
    }
  }

  tags = {
    Name = "${local.name_prefix}-guardduty-${local.full_suffix}"
    Tier = "security"
  }
}

output "guardduty_detector_id" {
  description = "GuardDuty detector id for this region"
  value       = aws_guardduty_detector.main.id
}
