resource "aws_lb" "this" {
  name               = local.name
  internal           = true
  load_balancer_type = "network"
  subnets            = data.aws_subnets.private.ids

  enable_deletion_protection = false
}

resource "aws_lb_target_group" "this" {
  name     = local.name
  port     = 8200
  protocol = "TCP"
  vpc_id   = data.aws_vpc.selected.id

  health_check {
    protocol = "TCP"
    port     = "traffic-port"
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
