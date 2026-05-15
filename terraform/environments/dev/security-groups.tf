resource "aws_security_group" "alb" {
  name        = "${local.name_prefix}-alb-sg-${local.full_suffix}"
  description = "Allow HTTPS inbound from internet to ALB"
  vpc_id      = aws_vpc.main.id
  ingress {
    description = "HTTPS from anywhere"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    description = "HTTP from anywhere for redirect to HTTPS"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${local.name_prefix}-alb-sg-${local.full_suffix}"
    Tier = "public"
  }
}

resource "aws_security_group" "ecs_tasks" {
  name        = "${local.name_prefix}-ecs-sg-${local.full_suffix}"
  description = "Allow inbound from ALB only"
  vpc_id      = aws_vpc.main.id
  ingress {
    description     = "App port from ALB"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = {
    Name = "${local.name_prefix}-ecs-sg-${local.full_suffix}"
    Tier = "private-app"
  }
}

# RDS security group. The inline ingress block defines the ECS-to-RDS
# rule that's the primary source of traffic. Phase 7's digest Lambda
# adds an additional ingress rule via aws_security_group_rule
# (lambda-digest.tf). To prevent terraform from oscillating between
# "the inline block is the only rule" and "the separate-rule is also
# present", we tell terraform to ignore changes to the ingress block
# entirely - the live AWS state is the source of truth for what
# ingress rules exist.
#
# This is the documented escape hatch from the mixing-pattern issue:
# https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule
#
# Pre-flight learning: a previous Phase 9 apply attempted to refactor
# this resource to use only separate aws_security_group_rule resources
# (no inline ingress block at all). Terraform interpreted the removal
# of the inline block as "destroy and recreate the SG", which requires
# detaching the SG from RDS ENIs. The terraform IAM user
# (meek-terraform-admin) does not have ec2:DetachNetworkInterface
# permission. Apply failed mid-flight, destroying the
# aws_security_group_rule.rds_from_digest_lambda resource. Recovery:
# revert to the inline block, add lifecycle ignore_changes, re-apply
# to recreate the destroyed rule from terraform code.
resource "aws_security_group" "rds" {
  name        = "${local.name_prefix}-rds-sg-${local.full_suffix}"
  description = "Allow PostgreSQL inbound from ECS tasks only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "PostgreSQL from ECS tasks"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.ecs_tasks.id]
  }

  # Lifecycle ignore_changes on ingress: allow other terraform files
  # (lambda-digest.tf) to add separate aws_security_group_rule
  # resources targeting this SG without terraform thinking they're
  # drift.
  lifecycle {
    ignore_changes = [ingress]
  }

  tags = {
    Name = "${local.name_prefix}-rds-sg-${local.full_suffix}"
    Tier = "data"
  }
}
