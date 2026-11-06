data "aws_ssm_parameter" "ecs_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2023/recommended/image_id"
}

data "aws_iam_policy_document" "instance_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.name}-instance"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role.json
}

# The instances have no public IP or SSH key, so shell access is via SSM Session Manager.
resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "instance_ecs" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceforEC2Role"
}

resource "aws_iam_instance_profile" "instance" {
  name = "${var.name}-instance"
  role = aws_iam_role.instance.name
}

resource "aws_security_group" "instance" {
  name        = "${var.name}-instance"
  description = "Allow HTTP from the load balancer"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-instance"
  }
}

resource "aws_vpc_security_group_ingress_rule" "instance_from_alb" {
  security_group_id            = aws_security_group.instance.id
  description                  = "HTTP from the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_egress_rule" "instance_all" {
  security_group_id = aws_security_group.instance.id
  description       = "All outbound, for the ECS API and image pulls"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_launch_template" "docker_host" {
  name_prefix   = "${var.name}-docker-host-"
  image_id      = data.aws_ssm_parameter.ecs_ami.value
  instance_type = var.instance_type

  vpc_security_group_ids = [aws_security_group.instance.id]

  iam_instance_profile {
    arn = aws_iam_instance_profile.instance.arn
  }

  # A hop limit of 1 keeps bridge-networked containers away from the instance role's credentials.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.root_volume_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    set -euxo pipefail
    echo "ECS_CLUSTER=${aws_ecs_cluster.main.name}" >> /etc/ecs/ecs.config
    dnf install -y amazon-ssm-agent
    systemctl enable --now amazon-ssm-agent
  EOT
  )
}

resource "aws_autoscaling_group" "docker_host" {
  name                = "${var.name}-docker-host"
  min_size            = var.asg_min_size
  max_size            = var.asg_max_size
  vpc_zone_identifier = [aws_subnet.private.id]

  # Not "ELB": ECS replaces tasks that fail ALB health checks, and a bad image
  # shouldn't make the ASG replace healthy hosts in a loop.
  health_check_type = "EC2"

  launch_template {
    id      = aws_launch_template.docker_host.id
    version = aws_launch_template.docker_host.latest_version
  }

  tag {
    key                 = "Name"
    value               = "${var.name}-docker-host"
    propagate_at_launch = true
  }

  # The instances need the NAT route and IAM permissions to register with ECS.
  depends_on = [
    aws_route_table_association.private,
    aws_iam_role_policy_attachment.instance_ecs,
  ]
}

resource "aws_autoscaling_policy" "cpu" {
  name                      = "${var.name}-cpu-target-tracking"
  autoscaling_group_name    = aws_autoscaling_group.docker_host.name
  policy_type               = "TargetTrackingScaling"
  estimated_instance_warmup = 120

  target_tracking_configuration {
    target_value = var.asg_cpu_target

    customized_metric_specification {
      namespace   = "AWS/ECS"
      metric_name = "CPUUtilization"
      statistic   = "Average"

      metric_dimension {
        name  = "ClusterName"
        value = aws_ecs_cluster.main.name
      }

      metric_dimension {
        name  = "ServiceName"
        value = aws_ecs_service.web.name
      }
    }
  }
}

resource "aws_sns_topic" "alerting" {
  name = "alerting"
}

# Watches host CPU, as a check independent of the ECS metric the scaling policy tracks.
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.name}-docker-host-cpu-high"
  alarm_description   = "Average Docker host CPU is above ${var.asg_cpu_alarm_threshold}%."
  namespace           = "AWS/EC2"
  metric_name         = "CPUUtilization"
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = var.asg_cpu_alarm_threshold
  period              = 300 # The instances report at 5-minute resolution.
  evaluation_periods  = 2
  alarm_actions       = [aws_sns_topic.alerting.arn]

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.docker_host.name
  }
}
