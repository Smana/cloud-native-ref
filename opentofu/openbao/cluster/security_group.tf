# NLB
resource "aws_security_group" "nlb" {
  name        = format("%s-nlb", local.name)
  description = "Security group for the OpenBao NLB"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "Allow to access to the OpenBao API through the NLB, only from the VPN"
    from_port       = 8200
    to_port         = 8200
    protocol        = "tcp"
    security_groups = [data.aws_security_group.tailscale.id]
  }

  # Standard outbound rule
  egress {
    description = "Allow the NLB to communicate with the Instances"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [data.aws_vpc.selected.cidr_block]
  }

  lifecycle {
    ignore_changes = [ingress]
  }
}

resource "aws_security_group_rule" "allow_8200" {
  description              = "Allow to access to the OpenBao API"
  type                     = "ingress"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nlb.id
  source_security_group_id = aws_security_group.openbao.id
}

# Autoscaling group
resource "aws_security_group" "openbao" {
  name        = format("%s-asg", local.name)
  description = "OpenBao ASG security group"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(
    { Name = local.name },
    var.tags,
  )
}

resource "aws_security_group_rule" "openbao_internal_api" {
  description       = "Allow OpenBao nodes to reach other on port 8200 for API"
  security_group_id = aws_security_group.openbao.id
  type              = "ingress"
  from_port         = 8200
  to_port           = 8200
  protocol          = "tcp"
  self              = true
}

resource "aws_security_group_rule" "openbao_internal_raft" {
  description       = "Allow OpenBao nodes to communicate on port 8201 for replication traffic, request forwarding, and Raft gossip"
  security_group_id = aws_security_group.openbao.id
  type              = "ingress"
  from_port         = 8201
  to_port           = 8201
  protocol          = "tcp"
  self              = true
}

resource "aws_security_group_rule" "openbao_network_ingress" {
  description       = "Allow specified CIDRs access to nodes on port 8200 and 8201"
  security_group_id = aws_security_group.openbao.id
  type              = "ingress"
  from_port         = 8200
  to_port           = 8201
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.selected.cidr_block]
}

resource "aws_security_group_rule" "openbao_node_exporter" {
  description       = "Allow Prometheus to scrape the node exporter"
  security_group_id = aws_security_group.openbao.id
  type              = "ingress"
  from_port         = 9100
  to_port           = 9100
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.selected.cidr_block]
}

#trivy:ignore:AVD-AWS-0104
resource "aws_security_group_rule" "openbao_outbound" {
  description       = "Allow OpenBao nodes to send outbound traffic"
  security_group_id = aws_security_group.openbao.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}
