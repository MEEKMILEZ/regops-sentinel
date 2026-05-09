resource "aws_iam_role" "codebuild_brain" {
  name = "${local.name_prefix}-codebuild-brain-role-${local.full_suffix}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "codebuild_brain" {
  name = "${local.name_prefix}-codebuild-brain-policy-${local.full_suffix}"
  role = aws_iam_role.codebuild_brain.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:ca-central-1:575751781190:*"
      },
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      },
      {
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
          "ecr:GetDownloadUrlForLayer"
        ]
        Resource = aws_ecr_repository.brain.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:Encrypt",
          "kms:DescribeKey"
        ]
        Resource = aws_kms_key.main.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket"
        ]
        Resource = [
          aws_s3_bucket.codebuild_artifacts.arn,
          "${aws_s3_bucket.codebuild_artifacts.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_s3_bucket" "codebuild_artifacts" {
  bucket        = "${local.name_prefix}-codebuild-${local.full_suffix}"
  force_destroy = true

  tags = {
    Name = "${local.name_prefix}-codebuild-${local.full_suffix}"
    Tier = "artifacts"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "codebuild_artifacts" {
  bucket = aws_s3_bucket.codebuild_artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.main.arn
    }
  }
}

resource "aws_s3_bucket_public_access_block" "codebuild_artifacts" {
  bucket                  = aws_s3_bucket.codebuild_artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_codebuild_project" "brain" {
  name          = "${local.name_prefix}-brain-build-${local.full_suffix}"
  description   = "Builds Brain Docker image and pushes to ECR with vulnerability scanning"
  service_role  = aws_iam_role.codebuild_brain.arn
  build_timeout = 30

  artifacts {
    type = "NO_ARTIFACTS"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/amazonlinux2-x86_64-standard:5.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"
    privileged_mode             = true

    environment_variable {
      name  = "AWS_DEFAULT_REGION"
      value = "ca-central-1"
    }
    environment_variable {
      name  = "AWS_ACCOUNT_ID"
      value = "575751781190"
    }
    environment_variable {
      name  = "ECR_REPO_URL"
      value = aws_ecr_repository.brain.repository_url
    }
    environment_variable {
      name  = "IMAGE_TAG"
      value = "latest"
    }
  }

  source {
    type      = "NO_SOURCE"
    buildspec = file("${path.module}/../../../app/brain/buildspec.yml")
  }

  encryption_key = aws_kms_key.main.arn

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.codebuild_brain.name
    }
  }

  tags = {
    Name = "${local.name_prefix}-brain-build-${local.full_suffix}"
    Tier = "ci-cd"
  }
}

resource "aws_cloudwatch_log_group" "codebuild_brain" {
  name              = "/aws/codebuild/${local.name_prefix}-brain-build-${local.full_suffix}"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}