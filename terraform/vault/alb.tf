module "alb" {
  source  = "terraform-aws-modules/alb/aws"
  version = "~> 9.0"

  name = local.name

  vpc_id  = data.aws_vpc.selected.id
  subnets = data.aws_subnets.private.ids

  # For example only
  enable_deletion_protection = false

  # Security Group
  security_group_ingress_rules = {
    all_http = {
      from_port   = 80
      to_port     = 80
      ip_protocol = "tcp"
      cidr_ipv4   = "0.0.0.0/0"
    }
  }
  security_group_egress_rules = {
    all = {
      ip_protocol = "-1"
      cidr_ipv4   = data.aws_vpc.selected.cidr_block
    }
  }

  listeners = {
    ex_http = {
      port     = 80
      protocol = "HTTP"

      forward = {
        target_group_key = replace(local.name, "-", "_")
      }
    }
  }

  target_groups = {
    replace(local.name, "-", "_") = {
      backend_protocol                  = "HTTP"
      backend_port                      = 80
      target_type                       = "instance"
      deregistration_delay              = 5
      load_balancing_cross_zone_enabled = true

      # There's nothing to attach here in this definition.
      # The attachment happens in the ASG module above
      create_attachment = false
    }
  }

  tags = var.tags
}
