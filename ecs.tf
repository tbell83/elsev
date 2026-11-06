resource "aws_ecs_cluster" "main" {
  name = "cluster"
}

resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/web"
  retention_in_days = 30
}

# Terraform only creates the first revision, using the image pushed during setup.
# The Container Deploy workflow registers later revisions from the newest one with
# a git hash image tag, so changes here take effect on the next deploy.
resource "aws_ecs_task_definition" "web" {
  family                   = "web"
  network_mode             = "bridge"
  requires_compatibilities = ["EC2"]

  # The service may be running the old revision, and a rollback may need it.
  skip_destroy = true

  # The ASG scales on the service's CPU metric, which is relative to this cpu
  # reservation. 1024 is all of a t2.micro, so the metric roughly matches host
  # CPU. Keep it in line with instance_type.
  container_definitions = jsonencode([
    {
      name              = "web"
      image             = "${aws_ecr_repository.webapp.repository_url}:latest"
      essential         = true
      cpu               = 1024
      memoryReservation = 256

      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        }
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.web.name
          awslogs-region        = var.region
          awslogs-stream-prefix = "web"
        }
      }
    }
  ])
}

# DAEMON runs one task on each host, so tasks follow the ASG as it scales and
# the fixed host port 80 can't conflict.
resource "aws_ecs_service" "web" {
  name                = "web"
  cluster             = aws_ecs_cluster.main.id
  task_definition     = aws_ecs_task_definition.web.arn
  launch_type         = "EC2"
  scheduling_strategy = "DAEMON"

  health_check_grace_period_seconds = 60

  load_balancer {
    target_group_arn = aws_lb_target_group.main.arn
    container_name   = "web"
    container_port   = 80
  }

  # The Container Deploy workflow owns which revision the service runs.
  lifecycle {
    ignore_changes = [task_definition]
  }

  # ECS rejects a target group that isn't attached to a load balancer yet.
  depends_on = [aws_lb_listener.http]
}
