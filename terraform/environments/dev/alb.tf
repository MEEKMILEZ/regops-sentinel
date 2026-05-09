resource "aws_lb" "brain" {
  name               = "rgops-brain-alb-${local.full_suffix}"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  drop_invalid_header_fields = true
  enable_deletion_protection = false

  tags = {
    Name = "${local.name_prefix}-brain-alb-${local.full_suffix}"
    Tier = "public"
  }
}

resource "aws_lb_target_group" "brain" {
  name        = "rgops-brain-tg-${local.full_suffix}"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "ip"

  health_check {
    enabled             = true
    path                = "/health"
    port                = "traffic-port"
    protocol            = "HTTP"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  deregistration_delay = 30

  tags = {
    Name = "${local.name_prefix}-brain-tg-${local.full_suffix}"
  }
}

resource "aws_lb_listener" "brain_http" {
  load_balancer_arn = aws_lb.brain.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.brain.arn
  }

  tags = {
    Name = "${local.name_prefix}-brain-listener-http-${local.full_suffix}"
  }
}