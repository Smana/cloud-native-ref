# Control plane


* Create a VPC (intra, private and public subnets)
* Create a management EKS cluster in a single zone
* Use SPOT instances
* Use bottlerocket AMI
* Install and configure Karpenter
* Install and configure Flux
* Write a secret that contains the cluster's specific variables that will be used with Flux. (please refer to [variables substitutions](https://fluxcd.io/flux/components/kustomize/kustomization/#post-build-variable-substitution))
* Deploy Cilium

## How to apply this?

1. Edit the file `backend.tf` and put your own S3 bucket name.
2. Create a file that contains your own variables. Here's an example:

`variables.tfvars`

```hcl
env          = "dev"
cluster_name = "mycluster-0" # Generated with petname

github_owner    = "Smana"
github_token    = <REDACTED>
repository_name = "cilium-gateway-api"

tags = {
  GithubRepo = "cilium-gateway-api"
  GithubOrg  = "Smana"
}
```

3. Apply with `terraform apply -var-file variables.tfvars`


