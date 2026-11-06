data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# Separate from the Docker host role so the bastion gets no ECS permissions.
resource "aws_iam_role" "bastion" {
  name               = "${var.name}-bastion"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role.json
}

# SSH is off by default, so shell access is normally via SSM Session Manager.
resource "aws_iam_role_policy_attachment" "bastion_ssm" {
  role       = aws_iam_role.bastion.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "bastion" {
  name = "${var.name}-bastion"
  role = aws_iam_role.bastion.name
}

resource "aws_security_group" "bastion" {
  name        = "${var.name}-bastion"
  description = "No inbound, access is via SSM Session Manager"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-bastion"
  }
}

resource "aws_vpc_security_group_ingress_rule" "bastion_ssh" {
  for_each = var.bastion_ssh_enabled ? toset(var.bastion_ssh_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.bastion.id
  description       = "SSH from an allowed address"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

# The key is generated outside Terraform, because a key generated here would put
# the private key in state, which pull request workflows can read.
resource "aws_key_pair" "bastion_ssh" {
  count = var.bastion_ssh_enabled ? 1 : 0

  # A generated name makes a new key replace the instance, which only reads the
  # key at first boot.
  key_name_prefix = "${var.name}-bastion-ssh-"
  public_key      = var.bastion_ssh_public_key
}

resource "aws_vpc_security_group_egress_rule" "bastion_https" {
  security_group_id = aws_security_group.bastion.id
  description       = "HTTPS, for the SSM endpoints and package updates"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "bastion_http" {
  security_group_id            = aws_security_group.bastion.id
  description                  = "HTTP to the load balancer"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_instance" "bastion" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.bastion.id]
  iam_instance_profile   = aws_iam_instance_profile.bastion.name
  key_name               = var.bastion_ssh_enabled ? aws_key_pair.bastion_ssh[0].key_name : null

  # Session Manager reaches AWS over the internet gateway, which needs a public IP.
  associate_public_ip_address = true

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  tags = {
    Name = "${var.name}-bastion"
  }

  # A new AMI release shouldn't replace the instance and end open sessions.
  lifecycle {
    ignore_changes = [ami]
  }
}

# The ALB is only reachable from the bastion, so the check has to run there. The
# command fails unless the site returns HTTP 200.
resource "aws_ssm_document" "site_check" {
  name            = "${var.name}-site-check"
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Confirm the site returns HTTP 200 through the load balancer."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "checkSite"
        inputs = {
          runCommand = [
            "status=$(curl --silent --show-error --output /dev/null --write-out '%%{http_code}' --max-time 10 http://${aws_lb.main.dns_name}/)",
            "echo \"HTTP $status\"",
            "[ \"$status\" = \"200\" ]",
          ]
        }
      }
    ]
  })
}
