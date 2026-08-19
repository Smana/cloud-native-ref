# Access model
# ------------
# Everything reaching the OpenBao API goes through the NLB, and the NLB now
# actually has this security group attached (it previously did not, so these
# rules enforced nothing and the real perimeter was the blanket VPC-CIDR rule
# on the instance SG below - which let every pod in the cluster talk to the
# API directly).
#
# Two classes of client:
#   - operators, arriving over Tailscale via the subnet router
#   - in-cluster workloads (cert-manager, the snapshot CronJob), arriving from
#     the pod CIDR
#
# The pod CIDR has to be expressed as a CIDR rather than the EKS node security
# group: terramate orders this stack *before* /opentofu/eks/init, so that group
# does not exist yet.

resource "aws_security_group" "nlb" {
  name        = format("%s-nlb", local.name)
  description = "Security group for the OpenBao NLB"
  vpc_id      = data.aws_vpc.selected.id

  tags = merge(
    { Name = format("%s-nlb", local.name) },
    var.tags,
  )
}

resource "aws_security_group_rule" "nlb_from_tailscale" {
  description              = "OpenBao API through the NLB, from the Tailscale subnet router"
  type                     = "ingress"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  security_group_id        = aws_security_group.nlb.id
  source_security_group_id = data.aws_security_group.tailscale.id
}

resource "aws_security_group_rule" "nlb_from_vpc" {
  description       = "OpenBao API through the NLB, from in-cluster workloads (pod CIDR) and the VPC"
  type              = "ingress"
  from_port         = 8200
  to_port           = 8200
  protocol          = "tcp"
  security_group_id = aws_security_group.nlb.id
  cidr_blocks       = distinct([for assoc in data.aws_vpc.selected.cidr_block_associations : assoc.cidr_block if assoc.state == "associated"])
}

resource "aws_security_group_rule" "nlb_to_instances" {
  description              = "Allow the NLB to reach the OpenBao instances"
  type                     = "egress"
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

# The target group sets preserve_client_ip = false (load_balancer.tf), so
# instances see the NLB's private addresses rather than the original client.
# That is what lets this rule name a security group instead of re-stating every
# client CIDR.
resource "aws_security_group_rule" "openbao_api_from_nlb" {
  description              = "OpenBao API, from the NLB only"
  type                     = "ingress"
  from_port                = 8200
  to_port                  = 8200
  protocol                 = "tcp"
  security_group_id        = aws_security_group.openbao.id
  source_security_group_id = aws_security_group.nlb.id
}

# retry_join's auto_join discovers peers via ec2:DescribeInstances and dials
# their private IPs on 8200 directly, not through the NLB.
resource "aws_security_group_rule" "openbao_internal_api" {
  description       = "Allow OpenBao nodes to reach each other on port 8200 for raft auto_join"
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

# Scraped by VictoriaMetrics pods, which carry pod-CIDR addresses. Same
# stack-ordering constraint as above - no EKS security group to reference yet.
resource "aws_security_group_rule" "openbao_node_exporter" {
  description       = "Allow Prometheus from VPC CIDRs (primary + secondary) to scrape the node exporter"
  security_group_id = aws_security_group.openbao.id
  type              = "ingress"
  from_port         = 9100
  to_port           = 9100
  protocol          = "tcp"
  cidr_blocks       = distinct([for assoc in data.aws_vpc.selected.cidr_block_associations : assoc.cidr_block if assoc.state == "associated"])
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
