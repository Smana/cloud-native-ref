
# tflint-ignore: terraform_unused_declarations
data "aws_ecr_authorization_token" "token" {}

data "aws_vpc" "selected" {
  filter {
    name   = "tag:project"
    values = ["demo-cloud-native-ref"]
  }
  filter {
    name   = "tag:owner"
    values = ["Smana"]
  }
  filter {
    name   = "tag:environment"
    values = ["dev"]
  }
}


data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.selected.id]
  }
  filter {
    name   = "tag:Name"
    values = ["vpc-${var.region}-${var.env}-private-*"]
  }
}

data "aws_security_group" "tailscale" {
  filter {
    name   = "tag:project"
    values = ["demo-cloud-native-ref"]
  }

  filter {
    name   = "tag:owner"
    values = ["Smana"]
  }

  filter {
    name   = "tag:environment"
    values = [var.env]
  }
  filter {
    name   = "tag:app"
    values = ["tailscale"]
  }
}

data "aws_ami" "this" {
  most_recent = "true"

  dynamic "filter" {
    for_each = var.ami_filter
    content {
      name   = filter.key
      values = filter.value
    }
  }

  owners = [var.ami_owner]
}

data "cloudinit_config" "vault_cloud_init" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-init-config.yaml"
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/scripts/cloudinit-config.yaml",
      {},
    )
  }

  part {
    filename     = "init-vault.sh"
    content_type = "text/x-shellscript"
    content = templatefile(
      "${path.module}/scripts/startup_script.sh",
      {
        "region"                = var.region
        "env"                   = var.env
        "prom_exporter_enabled" = var.prometheus_node_exporter_enabled
        "enable_ssm"            = var.enable_ssm
      },
    )
  }
}
