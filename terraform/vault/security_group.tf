# NLB
resource "aws_security_group" "nlb" {
  name        = format("%s-nlb", local.name)
  description = "Security group for the Vault NLB"
  vpc_id      = data.aws_vpc.selected.id

  ingress {
    description     = "Allow to access to the Vault API through the NLB, only from the VPN"
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
}

resource "aws_security_group_rule" "allow_8200" {
  description              = "Allow to access to the Vault API"
  type                     = "ingress"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nlb.id
  source_security_group_id = aws_security_group.vault.id
}


# Autoscaling group
resource "aws_security_group" "vault" {
  name        = format("%s-asg", local.name)
  description = "Vault ASG security group"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(
    { Name = local.name },
    var.tags,
  )
}

resource "aws_security_group_rule" "vault_internal_api" {
  description       = "Allow Vault nodes to reach other on port 8200 for API"
  security_group_id = aws_security_group.vault.id
  type              = "ingress"
  from_port         = 8200
  to_port           = 8200
  protocol          = "tcp"
  self              = true
}

resource "aws_security_group_rule" "vault_internal_raft" {
  description       = "Allow Vault nodes to communicate on port 8201 for replication traffic, request forwarding, and Raft gossip"
  security_group_id = aws_security_group.vault.id
  type              = "ingress"
  from_port         = 8201
  to_port           = 8201
  protocol          = "tcp"
  self              = true
}

resource "aws_security_group_rule" "vault_network_lb_ingress" {
  description       = "Allow specified CIDRs access to load balancer and nodes on port 8200"
  security_group_id = aws_security_group.vault.id
  type              = "ingress"
  from_port         = 8200
  to_port           = 8200
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.selected.cidr_block]
}

resource "aws_security_group_rule" "vault_outbound" {
  description       = "Allow Vault nodes to send outbound traffic"
  security_group_id = aws_security_group.vault.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}
