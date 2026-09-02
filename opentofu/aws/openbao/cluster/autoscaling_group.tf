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

  # Neither template declared a root volume, so size and encryption were
  # whatever the AMI shipped. That matters most here: in dev mode the
  # single-node raft store and the server TLS private key both live on the
  # root volume.
  block_device_mappings {
    device_name = data.aws_ami.this.root_device_name
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
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

  # In ha mode the raft data lives on the instance-store RAID-0, so the root
  # volume only carries the OS, the binary and the TLS material - but it still
  # carries the TLS private key, so it is still encrypted.
  block_device_mappings {
    device_name = data.aws_ami.this.root_device_name
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
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

  # Rolling refresh in `ha` only.
  #
  # NOT in dev. dev is a single node whose raft store lives on the root
  # volume, which block_device_mappings marks delete_on_termination. A refresh
  # would terminate the only live copy; the lineage's newest snapshot brings it
  # back on the next deploy, but everything written since that snapshot is
  # lost. The triggers are routine (an AMI publish, an openbao_version bump), so
  # replacing the running dev node stays a deliberate act: take a snapshot
  # first (`openbao-config.sh pre-destroy-snapshot`), then recycle.
  instance_refresh = var.mode == "ha" ? {
    strategy = "Rolling"
    preferences = {
      # 60% of 5 keeps 3 voters up, preserving raft quorum throughout.
      min_healthy_percentage = 60
      # Must be >= health_check_grace_period. Lower, and the refresh marks a
      # replacement healthy before the ASG has begun health-checking it, then
      # moves on to the next node while the first may not have joined raft.
      instance_warmup = 600
    }
  } : null

  # `ebs_optimized`, `enable_monitoring`, `iam_instance_profile_arn`,
  # `metadata_options` and `security_groups` are NOT set here on purpose. The
  # module only applies those to a launch template it creates itself, and
  # create_launch_template = false above — the real values live on
  # aws_launch_template.dev / .ha. Keeping copies here meant maintaining dead
  # configuration and implied all of them were load-bearing; the IMDS hop limit
  # in particular was previously edited in three places when only two mattered.

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
    # Quorum must not depend on spot capacity. With base 0 all five nodes were
    # spot, so a single unavailable pool could leave raft short of the three
    # voters it needs to elect a leader — and an OpenBao that cannot elect is an
    # OpenBao that cannot issue a certificate or read a secret.
    #
    # Not theoretical: the 2026-08-19 HA bring-up failed with
    # "InsufficientInstanceCapacity - We currently do not have sufficient
    # t3.small capacity in eu-west-3b". It self-healed on retry, but nothing
    # guaranteed that.
    #
    # base 3 pins the quorum majority to on-demand and leaves the two nodes
    # above it 95% spot, so the fault tolerance a five-node cluster is supposed
    # to provide is what actually survives a pool outage. The extra cost applies
    # only in ha mode — dev mode uses one instance from the dev launch template
    # and no mixed-instances policy at all.
    instances_distribution = {
      on_demand_allocation_strategy            = "lowest-price"
      on_demand_base_capacity                  = 3
      on_demand_percentage_above_base_capacity = 5
      spot_allocation_strategy                 = "lowest-price"
      spot_instance_pools                      = 3
    }
  } : null

  tags = merge(
    var.tags, local.tags
  )
}
