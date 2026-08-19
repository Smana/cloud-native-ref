resource "aws_lb" "this" {
  name               = local.name
  internal           = true
  load_balancer_type = "network"
  subnets            = data.aws_subnets.private.ids

  # AWS only accepts security groups on an NLB at creation time, so adding this
  # replaces the load balancer. The Route53 alias in route53.tf follows the new
  # one automatically.
  security_groups = [aws_security_group.nlb.id]

  enable_deletion_protection = false
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
