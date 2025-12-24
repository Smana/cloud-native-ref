# Network and VPN server

This module deploys several things:

* Base network resources: VPC, subnets
* **Pod subnets** with secondary CIDR (100.64.0.0/16) for Cilium ENI prefix delegation
* A Route53 private zone
* A Tailscale [Subnet Router](https://tailscale.com/kb/1019/subnets) for secure access to private resources

## Network Architecture

```
VPC: 10.0.0.0/16 (primary CIDR)
├── Private Subnets (nodes): 10.0.0.0/20, 10.0.16.0/20, 10.0.32.0/20
├── Public Subnets: 10.0.48.0/24, 10.0.49.0/24, 10.0.50.0/24
└── Intra Subnets (control plane): 10.0.52.0/24, 10.0.53.0/24, 10.0.54.0/24

Secondary CIDR: 100.64.0.0/16 (CG-NAT space for pods)
└── Pod Subnets: 100.64.0.0/18, 100.64.64.0/18, 100.64.128.0/18
    (16,384 IPs per AZ with prefix delegation)
```

**Why Secondary CIDR for Pods?**
- Separates node IPs from pod IPs for clearer network management
- Uses CG-NAT space (100.64.0.0/10) to avoid conflicts
- Enables Cilium ENI prefix delegation (/28 = 16 IPs per allocation)
- Provides massive pod density without IP exhaustion

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
