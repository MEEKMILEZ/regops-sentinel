terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }

  backend "s3" {
    bucket         = "regops-sentinel-tfstate-1a8df723"
    key            = "environments/dev/terraform.tfstate"
    region         = "ca-central-1"
    dynamodb_table = "regops-sentinel-tflock-1a8df723"
    encrypt        = true
  }
}