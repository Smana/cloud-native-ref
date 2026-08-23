# Access model
# ------------
# Everything reaching the OpenBao API goes through the NLB, and the NLB now
# actually has this security group attached — it previously did not, so these
# rules enforced nothing at all and the only real perimeter was a blanket
# VPC-CIDR rule on the instance SG.
#
# Be precise about what that did and did not buy, because it is easy to
# overclaim:
#
#   - The instance SG is genuinely tighter. It now admits 8200 from the NLB's
#     security group and from itself, nothing else. Port 8201 — the raft
#     cluster port — is no longer reachable from pods at all, where the old
#     rule spanned 8200-8201 across the whole VPC and pod CIDR. That is the
#     real narrowing.
#   - Pods can still reach the API on 8200. `nlb_from_vpc` below admits the
#     same CIDR list the deleted instance rule used, which includes the
#     secondary pod CIDR. The hop moved from the instance to the NLB; the
#     reachability did not change. This is NOT a "pod-CIDR bypass removed".
#
# Nor could it be: cert-manager and the snapshot CronJob are pods and
# legitimately need 8200. At the network layer every pod looks alike, and this
# stack is ordered *before* /opentofu/aws/eks/init, so there is no EKS node
# security group to name instead. What actually distinguishes an authorised pod
# from any other is AppRole authentication and the per-workload
# CiliumNetworkPolicy — not this security group.
#
# Two classes of client:
#   - operators, arriving over Tailscale via the subnet router
#   - in-cluster workloads (cert-manager, the snapshot CronJob)
#
# MIGRATING AN EXISTING DEPLOYMENT: revoke the legacy inline rule first.
# ---------------------------------------------------------------------
# The Tailscale ingress used to be an inline `ingress` block on the security
# group below; it is now the standalone `nlb_from_tailscale` resource. A fresh
# deploy is unaffected. Re-applying over a deployment created by the older code
# fails, once, with:
#
#   Error: InvalidPermission.Duplicate: the specified rule
#   "peer: sg-…, TCP, from port: 8200, to port: 8200, ALLOW" already exists
#     with aws_security_group_rule.nlb_from_tailscale
#
# No `moved` block fixes this and no dependency ordering avoids it. An inline
# block has no state address to move *from*, and with the block simply deleted
# from the config the provider plans no rule change on the group at all — the
# plan shows `aws_security_group.nlb will be updated in-place` for tags only —
# so it never revokes what it created inline. The old rule and the new resource
# then describe the same AWS rule, and the create collides.
#
# `ingress = []` would revoke it, but the provider forbids mixing inline blocks
# with aws_security_group_rule and the two would fight on every subsequent
# apply. So the one-time remedy is out of band, before the apply:
#
#   aws ec2 describe-security-group-rules --region <region> \
#     --filters Name=group-id,Values=<nlb-sg-id> \
#     --query "SecurityGroupRules[?!IsEgress && FromPort==\`8200\`].[SecurityGroupRuleId,Description]" \
#     --output text
#   aws ec2 revoke-security-group-ingress --region <region> \
#     --group-id <nlb-sg-id> --security-group-rule-ids <the legacy rule id>
#
# Access is not interrupted: `nlb_from_vpc` below admits the whole VPC CIDR,
# and the Tailscale subnet router is an EC2 instance inside it. Verified during
# the 2026-08-19 migration — the API answered 200 throughout the revoke.

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
