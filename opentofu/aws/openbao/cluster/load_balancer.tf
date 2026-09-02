# One private subnet per AZ, resolved individually so each can carry a fixed
# address below.
data "aws_subnet" "private" {
  for_each = toset(data.aws_subnets.private.ids)
  id       = each.value
}

resource "aws_lb" "this" {
  name               = local.name
  internal           = true
  load_balancer_type = "network"

  # Fixed private IPs, not AWS-assigned. A remote cluster reaches this OpenBao
  # through a Tailscale egress Service annotated with one of these addresses
  # (security/base/openbao-endpoint/remote), and that annotation must survive
  # a rebuild of this stack. cidrhost(-6) is the sixth address from the top of
  # each /20: AWS reserves the first four and the last one, and EKS assigns
  # from the pool at random, so a high fixed address is the least likely to
  # collide. If creation fails with "address already in use", pick -7.
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
