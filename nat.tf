# Separate from the Docker host role so the NAT instance gets no ECS permissions.
resource "aws_iam_role" "nat" {
  name               = "${var.name}-nat"
  assume_role_policy = data.aws_iam_policy_document.instance_assume_role.json
}

# The NAT instance has no SSH key, so shell access is via SSM Session Manager.
resource "aws_iam_role_policy_attachment" "nat_ssm" {
  role       = aws_iam_role.nat.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "nat" {
  name = "${var.name}-nat"
  role = aws_iam_role.nat.name
}

resource "aws_security_group" "nat" {
  name        = "${var.name}-nat"
  description = "Allow outbound traffic from the private subnet"
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.name}-nat"
  }
}

resource "aws_vpc_security_group_ingress_rule" "nat_from_private" {
  security_group_id = aws_security_group.nat.id
  description       = "All traffic from the private subnet"
  cidr_ipv4         = var.private_subnet_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "nat_all" {
  security_group_id = aws_security_group.nat.id
  description       = "All outbound, for forwarded traffic"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# Gives the private instances outbound access to install packages and pull images.
resource "aws_instance" "nat" {
  ami                    = data.aws_ssm_parameter.al2023_ami.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.nat.id]
  iam_instance_profile   = aws_iam_instance_profile.nat.name

  associate_public_ip_address = true

  # The instance forwards traffic that isn't addressed to it.
  source_dest_check = false

  metadata_options {
    http_endpoint = "enabled"
    http_tokens   = "required"
  }

  root_block_device {
    volume_type = "gp3"
    encrypted   = true
  }

  user_data_replace_on_change = true
  user_data                   = <<-EOT
    #!/bin/bash
    set -euxo pipefail
    dnf install -y iptables-services
    systemctl enable --now iptables
    echo "net.ipv4.ip_forward=1" > /etc/sysctl.d/90-nat.conf
    sysctl -p /etc/sysctl.d/90-nat.conf
    # The interface name varies by instance type.
    iface=$(ip route show default | awk '{print $5; exit}')
    iptables -t nat -A POSTROUTING -o "$iface" -j MASQUERADE
    # The iptables-services default rules reject forwarded traffic.
    iptables -F FORWARD
    iptables-save > /etc/sysconfig/iptables
  EOT

  tags = {
    Name = "${var.name}-nat"
  }

  # The package install at boot needs the route to the internet gateway.
  depends_on = [aws_route_table_association.public]

  # A new AMI release shouldn't replace the instance and cut outbound access.
  lifecycle {
    ignore_changes = [ami]
  }
}
