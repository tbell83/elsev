resource "aws_security_group" "alb" {
  name        = "${var.name}-alb"
  description = "Allow HTTP from the bastion"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-alb"
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_bastion" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP from bastion"
  referenced_security_group_id = aws_security_group.bastion.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "alb_to_instances" {
  security_group_id            = aws_security_group.alb.id
  description                  = "HTTP to Docker hosts"
  referenced_security_group_id = aws_security_group.instance.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_lb" "main" {
  name                       = var.name
  load_balancer_type         = "application"
  internal                   = true
  security_groups            = [aws_security_group.alb.id]
  subnets                    = aws_subnet.public[*].id
  drop_invalid_header_fields = true
}

resource "aws_lb_target_group" "main" {
  name     = var.name
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  # A replacement task can't bind host port 80 until the old one stops draining.
  deregistration_delay = 30

  health_check {
    path    = "/"
    matcher = "200-399"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.main.arn
  }
}

# resource "aws_lb_listener_rule" "from_cloudfront" {
#   listener_arn = aws_lb_listener.http.arn
#   priority     = 1

#   action {
#     type             = "forward"
#     target_group_arn = aws_lb_target_group.main.arn
#   }

#   condition {
#     http_header {
#       http_header_name = local.origin_verify_header
#       values           = [random_password.origin_verify.result]
#     }
#   }
# }
