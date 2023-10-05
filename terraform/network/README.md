# Network and VPN server


## Provision a Tailscale subnet router

### What is a subnet router?

### Prerequisites
* Create a Tailscale account
* Generate an auth key

Create the `variables.tfvars` file

```hcl
env    = "dev"
region = "eu-west-3"

tailscale = {
  name     = "ogenki"
  auth_key = "tskey-auth-..."
}

tags = {
  project = "demo-secured-eks"
  owner   = "Smana"
}
```

ℹ️ The tags are important here as they are used later on to provision the EKS cluster

### Apply

You can check that the instance has successfully joined the `tailnet` by running this command

```console
tailscale status
100.118.83.67   ogenki               smainklh@    linux   -
100.67.5.143    ip-10-0-10-77        smainklh@    linux   active; relay "par", tx 9881456 rx 45693984
```

Then disable key expiry for this subnet router.