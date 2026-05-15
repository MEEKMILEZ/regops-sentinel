# =====================================================================
# Phase 9: GitHub Actions OIDC -> AWS auto-deploy
# =====================================================================
#
# Lets GitHub Actions assume an IAM role using a short-lived JWT signed
# by GitHub itself - no long-lived AWS access keys stored in the repo.
#
# Industry standard pattern documented at:
#   https://docs.github.com/en/actions/deployment/security-hardening-your-deployments/configuring-openid-connect-in-amazon-web-services
#   https://aws.amazon.com/blogs/security/use-iam-roles-to-connect-github-actions-to-actions-in-aws/
#
# Trust boundary (the most security-critical part of this file):
#   The role can be assumed ONLY by GitHub Actions workflows running
#   on the MEEKMILEZ/regops-sentinel repository, ONLY on the main
#   branch, AND only with the standard sts.amazonaws.com audience.
#   Any one of those checks failing means STS will reject the request.
#
# What the role can do once assumed (in the inline policy below):
#   - ECR: push docker images to the brain repository
#   - ECS: update the brain service to roll the new task definition
#   - S3:  upload Lambda zip artifacts to the codebuild bucket (for
#          future digest Lambda code updates)
#
# What the role CANNOT do (deliberately):
#   - Create or destroy infrastructure (no iam:*, ec2:*, rds:*, etc.)
#   - Read secrets (no secretsmanager:GetSecretValue)
#   - Touch other AWS accounts
# =====================================================================


# ---------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------
variable "github_owner" {
  type        = string
  description = "GitHub owner/org that owns the repo"
  default     = "MEEKMILEZ"
}

variable "github_repo" {
  type        = string
  description = "GitHub repo name (without owner prefix)"
  default     = "regops-sentinel"
}

variable "github_oidc_branch" {
  type        = string
  description = "Git branch that's allowed to assume the deploy role"
  default     = "main"
}


# ---------------------------------------------------------------------
# OIDC identity provider
# ---------------------------------------------------------------------
# AWS calls this an "OIDC provider" but really it's a trust anchor: it
# tells AWS to validate JWTs whose `iss` claim matches the URL below.
#
# Note on thumbprint: as of late 2023 AWS added GitHub Actions as a
# trusted root CA, so the thumbprint value here is no longer used at
# runtime - but the terraform-aws-provider still requires the field.
# The well-known GitHub Actions thumbprint is below; if GitHub rotates
# their cert without AWS updating their root CA list, this would need
# refreshing. AWS docs:
#   https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_providers_create_oidc_verify-thumbprint.html
resource "aws_iam_openid_connect_provider" "github_actions" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${local.name_prefix}-github-actions-oidc-${local.full_suffix}"
    Tier = "iam"
  }
}


# ---------------------------------------------------------------------
# Deploy role - what GitHub Actions assumes
# ---------------------------------------------------------------------
resource "aws_iam_role" "github_actions_deploy" {
  name = "${local.name_prefix}-github-actions-deploy-${local.full_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = aws_iam_openid_connect_provider.github_actions.arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          # Confirms the JWT was intended for AWS STS, not some other
          # consumer. Without this, a token issued for a different
          # purpose could be replayed against AWS.
          StringEquals = {
            "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
          }
          # Confirms the workflow is running on our specific repo's
          # main branch. The :sub claim format is:
          #   repo:OWNER/REPO:ref:refs/heads/BRANCH
          # for branch-triggered workflows.
          StringLike = {
            "token.actions.githubusercontent.com:sub" = "repo:${var.github_owner}/${var.github_repo}:ref:refs/heads/${var.github_oidc_branch}"
          }
        }
      }
    ]
  })

  # Default session is 1 hour. CI workflows finish in <10 min so we
  # don't need more, and shorter sessions mean a leaked token has
  # less time to be useful.
  max_session_duration = 3600

  tags = {
    Name = "${local.name_prefix}-github-actions-deploy-${local.full_suffix}"
    Tier = "iam"
  }
}


# ---------------------------------------------------------------------
# Deploy role permissions
# ---------------------------------------------------------------------
# Scoped to the resources this project actually has - ECR repo by name,
# ECS service by name, S3 bucket by name. Resource:"*" only where AWS
# does not support resource-level perms (ecr:GetAuthorizationToken).
resource "aws_iam_role_policy" "github_actions_deploy" {
  name = "${local.name_prefix}-github-actions-deploy-policy-${local.full_suffix}"
  role = aws_iam_role.github_actions_deploy.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ECR auth - service-wide, not resource-scoped (AWS limitation).
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        # ECR push - scoped to the brain repo only.
        Sid    = "EcrPushBrain"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:CompleteLayerUpload",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart",
          "ecr:DescribeRepositories",
          "ecr:DescribeImages",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.brain.arn
      },
      {
        # ECS - update the brain service and inspect task definitions.
        # RegisterTaskDefinition has to be Resource:"*" because the
        # ARN for the about-to-be-created revision is unknown.
        Sid    = "EcsDeployBrain"
        Effect = "Allow"
        Action = [
          "ecs:RegisterTaskDefinition",
          "ecs:DescribeTaskDefinition",
          "ecs:DeregisterTaskDefinition",
        ]
        Resource = "*"
      },
      {
        Sid    = "EcsUpdateBrainService"
        Effect = "Allow"
        Action = [
          "ecs:UpdateService",
          "ecs:DescribeServices",
          "ecs:ListTasks",
          "ecs:DescribeTasks",
        ]
        Resource = [
          aws_ecs_service.brain.id,
          aws_ecs_cluster.main.arn,
          "arn:aws:ecs:ca-central-1:575751781190:task/${aws_ecs_cluster.main.name}/*",
        ]
      },
      {
        # iam:PassRole is required so ECS can run tasks as the task
        # roles. Without this, RegisterTaskDefinition would fail with
        # "User is not authorized to perform iam:PassRole".
        Sid    = "PassEcsTaskRoles"
        Effect = "Allow"
        Action = ["iam:PassRole"]
        Resource = [
          aws_iam_role.brain_task.arn,
          aws_iam_role.ecs_task_execution.arn,
        ]
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "ecs-tasks.amazonaws.com"
          }
        }
      },
      {
        # S3 - upload Lambda zip artifacts (future digest code updates).
        # Scoped to one bucket; no Delete perms.
        Sid    = "S3UploadArtifacts"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.codebuild_artifacts.arn,
          "${aws_s3_bucket.codebuild_artifacts.arn}/*",
        ]
      },
      {
        # KMS decrypt - needed to read the S3 bucket's encrypted objects
        # (codebuild artifacts bucket is encrypted with the project KMS
        # key).
        Sid      = "KmsDecryptArtifacts"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.main.arn
      },
    ]
  })
}


# ---------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------
output "github_actions_oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.github_actions.arn
  description = "ARN of the GitHub Actions OIDC provider"
}

output "github_actions_deploy_role_arn" {
  value       = aws_iam_role.github_actions_deploy.arn
  description = "ARN of the role GitHub Actions assumes for deploys. Paste into .github/workflows/brain-ci.yml as role-to-assume."
}
