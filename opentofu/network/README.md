# Network and VPN server

This module deploys several things:

* Base network resources: VPC, subnets
* A route53 private zone
* A Tailscale [Subnet Router](https://tailscale.com/kb/1019/subnets) in order to access to securely access to private resources

## Prerequisites

* Create a Tailscale account
* Generate an API key

Create the `variables.tfvars` file

```hcl
env                 = "dev"
region              = "eu-west-3"
private_domain_name = "priv.cloud.ogenki.io"

tailscale = {
  subnet_router_name = "ogenki"
  tailnet            = "smainklh@gmail.com"
  api_key            = "tskey-api-<REDACTED>" # Generated in Tailscale Admin console
  prometheus_enabled = true
  enable_ssm        = true
}

tags = {
  project = "cloud-native-ref"
  owner   = "Smana"
}

```

ℹ️ The tags are important here as they are used later on to provision the EKS cluster

## Apply

```console
cd terraform/network
tofu init
tofu apply --var-file variables.tfvars
```

You can check that the instance has successfully joined the `tailnet` by running this command

```console
tailscale status
100.118.83.67   ogenki               smainklh@    linux   -
100.67.5.143    ip-10-0-10-77        smainklh@    linux   active; relay "par", tx 9881456 rx 45693984
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.5 |
| <a name="requirement_tailscale"></a> [tailscale](#requirement\_tailscale) | ~> 0.18 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_tailscale"></a> [tailscale](#provider\_tailscale) | ~> 0.18 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_tailscale_subnet_router"></a> [tailscale\_subnet\_router](#module\_tailscale\_subnet\_router) | Smana/tailscale-subnet-router/aws | 1.1.0 |
| <a name="module_vpc"></a> [vpc](#module\_vpc) | terraform-aws-modules/vpc/aws | ~> 5.0 |
| <a name="module_zones"></a> [zones](#module\_zones) | terraform-aws-modules/route53/aws//modules/zones | ~> 4.0 |

## Resources

| Name | Type |
|------|------|
| [tailscale_acl.this](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/acl) | resource |
| [tailscale_dns_nameservers.this](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/dns_nameservers) | resource |
| [tailscale_dns_search_paths.this](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/dns_search_paths) | resource |
| [tailscale_dns_split_nameservers.ec2](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/dns_split_nameservers) | resource |
| [tailscale_dns_split_nameservers.private](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/dns_split_nameservers) | resource |
| [tailscale_tailnet_key.this](https://registry.terraform.io/providers/tailscale/tailscale/latest/docs/resources/tailnet_key) | resource |
| [aws_availability_zones.available](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/availability_zones) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_env"></a> [env](#input\_env) | The environment of the VPC | `string` | n/a | yes |
| <a name="input_private_domain_name"></a> [private\_domain\_name](#input\_private\_domain\_name) | Route53 domain name for private records | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | AWS Region | `string` | `"eu-west-3"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of tags to add to all resources | `map(string)` | `{}` | no |
| <a name="input_tailscale"></a> [tailscale](#input\_tailscale) | n/a | `map(any)` | <pre>{<br>  "api_key": "",<br>  "prometheus_enabled": false,<br>  "subnet_router_name": "",<br>  "tailnet": ""<br>}</pre> | no |
| <a name="input_vpc_cidr"></a> [vpc\_cidr](#input\_vpc\_cidr) | The IPv4 CIDR block for the VPC | `string` | `"10.0.0.0/16"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_intra_subnets"></a> [intra\_subnets](#output\_intra\_subnets) | List of IDs of intra subnets |
| <a name="output_private_subnets"></a> [private\_subnets](#output\_private\_subnets) | List of IDs of private subnets |
| <a name="output_public_subnets"></a> [public\_subnets](#output\_public\_subnets) | List of IDs of public subnets |
| <a name="output_tailscale_security_group_id"></a> [tailscale\_security\_group\_id](#output\_tailscale\_security\_group\_id) | value |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | The ID of the VPC |
<!-- END_TF_DOCS -->
