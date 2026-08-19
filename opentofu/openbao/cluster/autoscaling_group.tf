resource "aws_launch_template" "dev" {
  name_prefix            = "${local.name}-dev-"
  description            = "Launch template for development mode"
  image_id               = data.aws_ami.this.id
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.openbao.id]
  user_data              = base64encode(data.cloudinit_config.openbao_cloud_init.rendered)
  ebs_optimized          = true
  # The ASG launches from the template's default version; without this, user_data
  # or AMI changes only bump the latest version and never reach new instances.
  update_default_version = true
  monitoring {
    enabled = true
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      local.tags
    )
  }
}


resource "aws_launch_template" "ha" {
  name_prefix            = "${local.name}-ha-"
  description            = "Launch template for high-availability mode"
  image_id               = data.aws_ami.this.id
  vpc_security_group_ids = [aws_security_group.openbao.id]
  user_data              = base64encode(data.cloudinit_config.openbao_cloud_init.rendered)
  ebs_optimized          = true
  update_default_version = true
  monitoring {
    enabled = true
  }
  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }
  instance_requirements {
    burstable_performance = "excluded"
    instance_generations  = ["current"]
    local_storage_types   = ["ssd"]
    memory_gib_per_vcpu {
      min = 0.5
      max = 8
    }
    memory_mib {
      min = 1024
      max = 8192
    }
    network_interface_count {
      min = 1
      max = 4
    }
    vcpu_count {
      min = 1
      max = 12
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      var.tags,
      local.tags
    )
  }
}


module "openbao_asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 9.0"

  name                            = local.name
  ignore_desired_capacity_changes = true
  desired_capacity                = var.mode == "dev" ? 1 : 5
  min_size                        = var.mode == "dev" ? 1 : 5
  max_size                        = var.mode == "dev" ? 1 : 5
  vpc_zone_identifier             = data.aws_subnets.private.ids

  traffic_source_attachments = {
    ex-alb = {
      traffic_source_identifier = aws_lb_target_group.this.arn
      traffic_source_type       = "elbv2"
    }
  }

  create_launch_template = false
  launch_template_id     = var.mode == "dev" ? aws_launch_template.dev.id : aws_launch_template.ha.id

  # Without this the ASG defaults to EC2 health checks, which only test that
  # the hypervisor is alive. A node whose boot script failed - a wget timeout,
  # a bad dpkg, a GPG mismatch - stays InService forever: the target group
  # drops it, the ASG never replaces it.
  health_check_type = "ELB"
  # Boot does a package upgrade, a snap install and two signed downloads before
  # OpenBao listens. Too short a grace period and the ASG kills instances
  # mid-provision, in a loop. Revisit downwards once the AMI is baked.
  health_check_grace_period = 600

  # Launch template changes (AMI, user_data) previously only reached *new*
  # instances; existing ones had to be terminated by hand.
  instance_refresh = {
    strategy = "Rolling"
    preferences = {
      # dev is a single node, so any non-zero minimum deadlocks the refresh.
      # In ha, 60% of 5 keeps 3 voters up and preserves raft quorum throughout.
      min_healthy_percentage = var.mode == "dev" ? 0 : 60
      instance_warmup        = 300
    }
  }

  ebs_optimized            = true
  enable_monitoring        = true
  iam_instance_profile_arn = aws_iam_instance_profile.this.arn

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "enabled"
  }

  security_groups = [aws_security_group.openbao.id]

  use_mixed_instances_policy = var.mode == "ha"


  # No weighted_capacity. ASG reads desired/min/max as *capacity units*, so the
  # previous weights (t3.small=2, t3.medium=1) meant desired_capacity = 5 could
  # settle anywhere between three and five instances depending on which pool
  # won - a raft cluster whose quorum size is decided by spot pricing. Equal
  # weighting makes 5 mean five nodes.
  mixed_instances_policy = var.mode == "ha" ? {
    launch_template = {
      override = [
        { instance_type = "t3.small" },
        { instance_type = "t3.medium" },
      ]
    }
    instances_distribution = {
      on_demand_allocation_strategy            = "lowest-price"
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 5
      spot_allocation_strategy                 = "lowest-price"
      spot_instance_pools                      = 3
    }
  } : null

  tags = merge(
    var.tags, local.tags
  )
}
