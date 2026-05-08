provider "aws" {
  region  = "ca-central-1"
  profile = "regops-sentinel"

  default_tags {
    tags = {
      Project     = "RegOps-Sentinel"
      Environment = "dev"
      ManagedBy   = "Terraform"
      Owner       = "meek"
    }
  }
}
