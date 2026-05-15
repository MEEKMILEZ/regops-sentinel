variable "project_name" {
  type    = string
  default = "regops-sentinel"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "suffix" {
  type    = string
  default = "1a8df723"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "azs" {
  type    = list(string)
  default = ["ca-central-1a", "ca-central-1b"]
}

variable "public_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.1.0/24", "10.20.2.0/24"]
}

variable "private_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.11.0/24", "10.20.12.0/24"]
}

variable "data_subnet_cidrs" {
  type    = list(string)
  default = ["10.20.21.0/24", "10.20.22.0/24"]
}

variable "single_nat_gateway" {
  type    = bool
  default = true
}

variable "db_instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "db_allocated_storage" {
  type    = number
  default = 20
}

variable "db_max_allocated_storage" {
  type    = number
  default = 100
}

variable "db_engine_version" {
  type    = string
  default = "16.13"
}

variable "db_name" {
  type    = string
  default = "regops"
}

variable "db_username" {
  type    = string
  default = "regops_admin"
}

variable "db_multi_az" {
  type    = bool
  default = true
}

variable "db_backup_retention_days" {
  type    = number
  default = 7
}

variable "db_deletion_protection" {
  type    = bool
  default = false
}
# =====================================================================
# Phase 7: digest Lambda variables
# =====================================================================
# Recipient list is a comma-separated string of email addresses. They
# must all be SES-verified while the account is in sandbox mode.
variable "digest_recipients" {
  type        = string
  description = "Comma-separated list of email recipients for the weekly digest"
  default     = "paschalnnenna@hotmail.com"
}

# The "From:" address for the digest email. Must be a verified SES
# sender identity in the same region as the Lambda. In sandbox mode
# this address ALSO has to be in the recipient list of verified
# identities (SES requires both sides verified in sandbox).
variable "digest_from_address" {
  type        = string
  description = "SES-verified email address used as the From: on digests"
  default     = "paschalnnenna@hotmail.com"
}
