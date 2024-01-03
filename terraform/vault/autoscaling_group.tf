module "vault_asg" {
  source  = "terraform-aws-modules/autoscaling/aws"
  version = "~> 7.3"

  # Autoscaling group
  name = local.name

  ignore_desired_capacity_changes = true

  desired_capacity = var.mode == "dev" ? 1 : 5
  min_size         = var.mode == "dev" ? 1 : 5
  max_size         = var.mode == "dev" ? 1 : 5

  vpc_zone_identifier = data.aws_subnets.private.ids
  # service_linked_role_arn = aws_iam_service_linked_role.autoscaling.arn

  # Traffic source attachment
  create_traffic_source_attachment = true
  traffic_source_identifier        = aws_lb_target_group.this.arn
  traffic_source_type              = "elbv2"

  # Launch template
  launch_template_name        = local.name
  launch_template_description = "Vault cluster launch template"
  update_default_version      = true

  image_id  = data.aws_ami.this.id
  user_data = data.cloudinit_config.vault_cloud_init.rendered
  # instance_type = "t3.micro"

  ebs_optimized     = true
  enable_monitoring = true

  iam_instance_profile_arn = aws_iam_instance_profile.this.arn

  metadata_options = {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 32
    instance_metadata_tags      = "enabled"
  }

  security_groups = [aws_security_group.vault.id]

  use_mixed_instances_policy = true
  mixed_instances_policy = {
    instances_distribution = {
      on_demand_base_capacity                  = 0
      on_demand_percentage_above_base_capacity = 10
      spot_allocation_strategy                 = "capacity-optimized"
    }
    override = [
      {
        instance_requirements = {
          cpu_manufacturers   = ["amd"]
          local_storage_types = ["ssd"]
          memory_gib_per_vcpu = {
            min = 2
            max = 4
          }
          memory_mib = {
            min = 2048
          },
          vcpu_count = {
            min = 2
            max = 4
          }
        }
      }
    ]
  }
  instance_requirements = {

    burstable_performance   = "excluded"
    excluded_instance_types = ["t*"]
    instance_generations    = ["current"]
    local_storage_types     = ["ssd", "hdd"]

    memory_gib_per_vcpu = {
      min = 4
      max = 16
    }

    memory_mib = {
      min = 24
      max = 128
    }

    network_interface_count = {
      min = 1
      max = 16
    }

    vcpu_count = {
      min = 2
      max = 96
    }
  }

  tags = merge(
    var.tags, local.tags
  )
}
