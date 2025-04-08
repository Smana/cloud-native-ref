
# tflint-ignore: terraform_unused_declarations
data "aws_ecr_authorization_token" "token" {}

data "aws_route53_zone" "this" {
  name         = var.domain_name
  private_zone = true
}

data "aws_vpc" "selected" {
  filter {
    name   = "tag:project"
    values = ["cloud-native-ref"]
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
    values = ["cloud-native-ref"]
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

data "aws_secretsmanager_secret" "openbao_certificates" {
  name = var.openbao_certificates_secret_name
}

data "aws_secretsmanager_secret_version" "openbao_certificates" {
  secret_id  = data.aws_secretsmanager_secret.openbao_certificates.id
  version_id = data.aws_secretsmanager_secret.openbao_certificates.version_id
}

data "cloudinit_config" "openbao_cloud_init" {
  gzip          = true
  base64_encode = true

  part {
    filename     = "cloud-init-config.yaml"
    content_type = "text/cloud-config"
    content = templatefile(
      "${path.module}/scripts/cloudinit-config.yaml",
      {
        tls_key_b64    = base64encode(data.aws_secretsmanager_secret_version.openbao_certificates.secret_string.key)
        tls_cert_b64   = base64encode(data.aws_secretsmanager_secret_version.openbao_certificates.secret_string.cert)
        tls_cacert_b64 = base64encode(data.aws_secretsmanager_secret_version.openbao_certificates.secret_string.ca)
      },
    )
  }

  part {
    filename     = "init-openbao.sh"
    content_type = "text/x-shellscript"
    content = <<-EOF
      ${templatefile(
    "${path.module}/scripts/setup-local-disks.sh",
    {
      "openbao_data_path" = var.openbao_data_path
    }
    )}
      ${templatefile(
    "${path.module}/scripts/startup_script.sh",
    {
      "region"                = var.region
      "prom_exporter_enabled" = var.prometheus_node_exporter_enabled
      "enable_ssm"            = var.enable_ssm
      "openbao_version"       = var.openbao_version
      "openbao_data_path"     = var.openbao_data_path
      "openbao_instance"      = local.tags.OpenBaoInstance
      "dev_mode"              = var.mode == "dev" ? true : false
      "leader_tls_servername" = var.leader_tls_servername
      "kms_unseal_key_id"     = aws_kms_key.openbao.id

    }
)}
      EOF
}
}
