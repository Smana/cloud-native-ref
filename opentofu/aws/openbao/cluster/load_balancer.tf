# One private subnet per AZ, resolved individually so each can carry a fixed
# address below.
data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

# Changing `subnets` to `subnet_mapping` forces a new NLB -- this is the
# riskiest apply in Stage 1. OpenTofu's default order is destroy-then-create:
# listener down, NLB down, NLB up, listener up, then the Route53 alias
# updates. That is a MULTI-MINUTE OpenBao API outage plus stale DNS for the
# alias record's cache lifetime, during which cert-manager cannot issue, the
# snapshot CronJob fails, and OpenBaoDown fires. Do not run this during a
# certificate renewal, and take a snapshot first -- except on the very first
# such apply, where you cannot, because the node is still on the `file`
# backend until it reboots onto Raft.
#
# Do NOT add create_before_destroy to fix the outage: a target group cannot be
# associated with two load balancers, so it would deadlock the apply. The
# target group and listener re-attach correctly as written -- the TG is not
# force-replaced and the ASG references it by an unchanged ARN.
resource "aws_lb" "this" {
  name               = local.name
  internal           = true
  load_balancer_type = "network"

  # Fixed IPs are only useful if every one of them works, and by default they
  # would not. NLB cross-zone load balancing is DISABLED unless asked for: an
  # NLB node then serves only targets registered in its own AZ and DROPS
  # traffic when it has none. subnet_mapping below enables three AZs, but
  # `dev` runs one instance, in whichever AZ the ASG picked -- so two of the
  # three addresses would blackhole, and which one worked would change on
  # every instance replacement. That is exactly the instability these fixed
  # addresses exist to remove.
  #
  # It is invisible on the DNS path, which is why this is easy to miss:
  # AWS drops target-less AZs from the NLB's own DNS answer, and the Route53
  # alias evaluates target health. The fixed-IP path has no such fallback --
  # security/base/openbao-endpoint/remote pins ONE literal address.
  #
  # Cost is cross-zone data processing, which at OpenBao API volume is noise.
  enable_cross_zone_load_balancing = true

  # Fixed private IPs, not AWS-assigned. A remote cluster reaches this OpenBao
  # through a Tailscale egress Service annotated with one of these addresses
  # (security/base/openbao-endpoint/remote), and that annotation must survive
  # a rebuild of this stack. cidrhost(-6) is the sixth address from the top of
  # each /20: AWS reserves the first four and the last one, and EKS assigns
  # from the pool at random, so a high fixed address is the least likely to
  # collide.
  #
  # If creation fails with "address already in use", the usual cause is the
  # PREVIOUS load balancer's ENI not yet released after a destroy -- wait and
  # re-apply, the address comes back. Change the offset only if a long-lived
  # ENI genuinely holds it, and treat that as a contract change: the remote
  # cluster's openbao_target_ip has to move with it.
  dynamic "subnet_mapping" {
    for_each = data.aws_subnet.private
    content {
      subnet_id            = subnet_mapping.value.id
      private_ipv4_address = cidrhost(subnet_mapping.value.cidr_block, -6)
    }
  }

  # AWS only accepts security groups on an NLB at creation time, so adding this
  # replaces the load balancer. The Route53 alias in route53.tf follows the new
  # one automatically.
  security_groups = [aws_security_group.nlb.id]

  # Deliberately off. This platform is torn down and reprovisioned on every
  # test, and deletion protection would make `terramate script run destroy`
  # fail. Turn it on for any deployment meant to stay up.
  enable_deletion_protection = false

  # No access_logs block on purpose: AWS only emits NLB access logs for a TLS
  # listener, and "the logs contain information about TLS requests only". This
  # listener is plain TCP (OpenBao terminates its own TLS), so the feature would
  # produce empty buckets. The modern alternative is the NLB's CloudWatch Logs
  # integration, which is worth evaluating separately if connection-level
  # auditing is wanted - but the higher-value gap is that OpenBao itself has no
  # audit device enabled, which is where secret-access auditing belongs.
}

resource "aws_lb_target_group" "this" {
  name     = local.name
  port     = 8200
  protocol = "TCP"
  vpc_id   = data.aws_vpc.selected.id

  # Client IP preservation is on by default for instance targets, which would
  # force the instance security group to allow every client CIDR rather than
  # just the NLB's group. Turning it off buys a much tighter instance SG; the
  # cost is that OpenBao sees NLB addresses as the peer, which makes the
  # AppRole token_bound_cidrs setting less meaningful than it looks (it was
  # already a pair of /16s covering the whole VPC and pod range).
  preserve_client_ip = false

  # A bare TCP check cannot tell a working node from one serving a broken TLS
  # handshake. The query parameters deliberately flatten standby, uninitialised
  # and sealed into 200: this check drives ASG instance replacement, so it must
  # answer "is the process serving?" and nothing more. Making a sealed node
  # unhealthy here would mean a KMS outage seals every node and the ASG then
  # terminates the entire cluster. Seal and leadership state are alerting
  # concerns - see observability/base/.../vmrules/openbao.yaml.
  health_check {
    protocol            = "HTTPS"
    port                = "traffic-port"
    path                = "/v1/sys/health?standbyok=true&uninitcode=200&sealedcode=200&drsecondarycode=200&performancestandbyok=true"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
}

resource "aws_lb_listener" "this" {
  load_balancer_arn = aws_lb.this.arn
  port              = 8200
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this.arn
  }
}
