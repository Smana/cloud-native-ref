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
  subnet_router_name         = "ogenki"
  tailnet                    = "smainklh@gmail.com"
  // api_key                    = "tskey-api-<REDACTED>" # Generated in Tailscale Admin console. Sensitive value that should be defined using `export TF_VAR_tailscale_api_key=<key>`
  prometheus_enabled         = true
  ssm_enabled                = true
  overwrite_existing_content = true # Be careful it will replace the existing ACLs
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
