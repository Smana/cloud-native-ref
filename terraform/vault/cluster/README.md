# Vault Cluster

Deploy a Vault instance following HashiCorp's best practices. Complete these steps in order:

1. **Server Certificates**: Prepare certificates first. You can provide yours or use the guide: [Public Key Infrastructure (PKI): Requirements](./docs/pki_requirements.md).

2. **Vault Instance Setup**: Start your Vault instance. See [Getting Started](./docs/getting_started.md) for instructions.

3. **Configure Vault**: After setting up the cluster, configure it. Switch to the [management](../management/README.md) directory for PKI, roles, etc.

## 💪 High availability

⚠️ You can choose between two modes when creating a Vault instance: `dev`  and `ha` (default: `dev`). Here are the differences between these modes:

|                    | Dev            |     HA        |
|--------------------|----------------|---------------|
| Number of nodes    |        1       |       5       |
| Disk type          |      hdd       |      ssd      |
| Vault storage type |      file      |     raft      |
| Instance type(s)   |    t3.micro    |   mixed (lower-price)    |
| Capacity type      |   on-demand    |     spot      |

In designing our production environment for HashiCorp Vault, I opted for a balance between performance and reliability. Key architectural decisions include:

1. **Raft Protocol for Cluster Reliability**: Utilizing the Raft protocol, recognized for its robustness in distributed systems, to ensure cluster reliability in a production environment.

2. **Five-Node Cluster Configuration**: Following best practices for fault tolerance and availability, this setup significantly reduces the risk of service disruption.

3. **Ephemeral Node Strategy with SPOT Instances**: This approach provides operational flexibility and cost efficiency. The use of SPOT instances aligns with our goal of optimizing costs, despite potential node availability volatility.

4. **Data Storage on RAID0 Array**: Prioritizing performance, RAID0 arrays offer faster data access. The Raft protocol and a robust backup/restore strategy help mitigate the lack of redundancy in RAID0.

5. **Vault Auto-Unseal Feature**: Configured to accommodate the ephemeral nature of nodes, ensuring minimal downtime and manual intervention.

This architecture balances performance, cost-efficiency, and resilience, embracing the dynamic nature of cloud resources for operational flexibility.

## 🔒 Security Considerations

* Keep the Root CA offline.
* Use hardened AMIs, such as those built with [this project](https://github.com/konstruktoid/hardened-images) from @konstruktoid. An Ubuntu AMI from Canonical is used by default.
* Disable SSM once the cluster is operational and an Identity provider is configured.
* Implement MFA for authentication.


<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_cloudinit"></a> [cloudinit](#requirement\_cloudinit) | ~> 2.3 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_cloudinit"></a> [cloudinit](#provider\_cloudinit) | ~> 2.3 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_vault_asg"></a> [vault\_asg](#module\_vault\_asg) | terraform-aws-modules/autoscaling/aws | ~> 7.3 |

## Resources

| Name | Type |
|------|------|
| [aws_iam_instance_profile.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile) | resource |
| [aws_iam_role.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.vault-kms-unseal](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_iam_role_policy_attachment.ec2_read_only](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_iam_role_policy_attachment.ssm](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy_attachment) | resource |
| [aws_kms_key.vault](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key) | resource |
| [aws_launch_template.dev](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_launch_template.ha](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template) | resource |
| [aws_lb.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb) | resource |
| [aws_lb_listener.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_listener) | resource |
| [aws_lb_target_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb_target_group) | resource |
| [aws_route53_record.nlb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record) | resource |
| [aws_security_group.nlb](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group.vault](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group) | resource |
| [aws_security_group_rule.allow_8200](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.vault_internal_api](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.vault_internal_raft](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.vault_network_lb_ingress](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_security_group_rule.vault_outbound](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group_rule) | resource |
| [aws_ami.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ami) | data source |
| [aws_ecr_authorization_token.token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecr_authorization_token) | data source |
| [aws_iam_policy_document.vault-kms-unseal](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_route53_zone.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_security_group.tailscale](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/security_group) | data source |
| [aws_subnets.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [cloudinit_config.vault_cloud_init](https://registry.terraform.io/providers/hashicorp/cloudinit/latest/docs/data-sources/config) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_ami_filter"></a> [ami\_filter](#input\_ami\_filter) | List of maps used to create the AMI filter for the action runner AMI. | `map(list(string))` | <pre>{<br>  "name": [<br>    "ubuntu/images/hvm-ssd/ubuntu-lunar-23.04-amd64-server-*"<br>  ]<br>}</pre> | no |
| <a name="input_ami_owner"></a> [ami\_owner](#input\_ami\_owner) | Owner ID of the AMI | `string` | `"099720109477"` | no |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | The domain name for which the certificate should be issued | `string` | n/a | yes |
| <a name="input_enable_ssm"></a> [enable\_ssm](#input\_enable\_ssm) | If true, allow to connect to the instances using AWS Systems Manager | `bool` | `false` | no |
| <a name="input_env"></a> [env](#input\_env) | The environment of the Vault cluster | `string` | n/a | yes |
| <a name="input_leader_tls_servername"></a> [leader\_tls\_servername](#input\_leader\_tls\_servername) | One of the shared DNS SAN used to create the certs use for mTLS | `string` | n/a | yes |
| <a name="input_mode"></a> [mode](#input\_mode) | Vault cluster mode (default dev, meaning a single node) | `string` | `"dev"` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the resources created for this Vault cluster | `string` | `"vault"` | no |
| <a name="input_prometheus_node_exporter_enabled"></a> [prometheus\_node\_exporter\_enabled](#input\_prometheus\_node\_exporter\_enabled) | If set to true install and start a prometheus node exporter | `bool` | `false` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS Region | `string` | `"eu-west-3"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of tags to add to all resources | `map(string)` | `{}` | no |
| <a name="input_vault_data_path"></a> [vault\_data\_path](#input\_vault\_data\_path) | Directory where Vault's data will be stored in an EC2 instance | `string` | `"/opt/vault/data"` | no |

## Outputs

No outputs.
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
