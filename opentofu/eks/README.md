# Control plane EKS cluster

* Create a management EKS cluster in a single zone
* Use SPOT instances
* Use Amazon Linux AMI (Currently Bottlerocket doesn't work and having issues with AL2023)
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
cluster_name = "mycluster-0"

flux_sync_repository_url = "https://github.com/Smana/cloud-native-ref.git"

tags = {
  GithubRepo = "cloud-native-ref"
  GithubOrg  = "Smana"
}


karpenter_limits = {
  "default" = {
    cpu    = "20"
    memory = "64Gi"
  }
  "io" = {
    cpu    = "20"
    memory = "64Gi"
  }
}

# Optional if an external OIDC provider should be used to authenticate users
cluster_identity_providers = {
  zitadel = {
    client_id      = "702vqsrjicklgb7c5b7b50i1gc"
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}

```

3. Apply with
  :information_source: Git branch or tag in the format refs/heads/main or refs/tags/v1.0.0
   `tofu apply -var-file variables.tfvars --var=git_ref=<flux_git_ref>`


## Cleaning things up

In order to really clean everything you should follow these steps:

1. Suspend Flux reconciliations
   ```console
   flux suspend kustomization --all
   ```

2. Delete `Gateways` (These create AWS loadbalancers)
   ```console
   kubectl delete gateways --all-namespaces --all
   ```

3. Wait 3/4 minutest and delete all `IRSA` and `EPI`
   ```console
   kubectl delete irsa,epi --all-namespaces --all
   ```

4. `tofu destroy --var-file variables.tfvars`

One step:
```console
flux suspend kustomization --all && \
kubectl delete gateways --all-namespaces --all && sleep 60 && \
kubectl delete irsa,epi --all-namespaces --all && sleep 30 && \
tofu destroy --var-file variables.tfvars
```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_flux"></a> [flux](#requirement\_flux) | 1.4.0 |
| <a name="requirement_github"></a> [github](#requirement\_github) | ~> 6.0 |
| <a name="requirement_helm"></a> [helm](#requirement\_helm) | >= 2.7 |
| <a name="requirement_http"></a> [http](#requirement\_http) | >= 3.4 |
| <a name="requirement_kubectl"></a> [kubectl](#requirement\_kubectl) | >= 2.0.0 |
| <a name="requirement_kubernetes"></a> [kubernetes](#requirement\_kubernetes) | >= 2.20 |
| <a name="requirement_random"></a> [random](#requirement\_random) | ~> 3.5 |
| <a name="requirement_tls"></a> [tls](#requirement\_tls) | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | ~> 5.0 |
| <a name="provider_aws.virginia"></a> [aws.virginia](#provider\_aws.virginia) | ~> 5.0 |
| <a name="provider_helm"></a> [helm](#provider\_helm) | >= 2.7 |
| <a name="provider_http"></a> [http](#provider\_http) | >= 3.4 |
| <a name="provider_kubectl"></a> [kubectl](#provider\_kubectl) | >= 2.0.0 |
| <a name="provider_kubernetes"></a> [kubernetes](#provider\_kubernetes) | >= 2.20 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_eks"></a> [eks](#module\_eks) | terraform-aws-modules/eks/aws | ~> 20 |
| <a name="module_irsa_crossplane"></a> [irsa\_crossplane](#module\_irsa\_crossplane) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | 5.52.1 |
| <a name="module_irsa_ebs_csi_driver"></a> [irsa\_ebs\_csi\_driver](#module\_irsa\_ebs\_csi\_driver) | terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks | 5.52.1 |
| <a name="module_karpenter"></a> [karpenter](#module\_karpenter) | terraform-aws-modules/eks/aws//modules/karpenter | ~> 20.0 |

## Resources

| Name | Type |
|------|------|
| [aws_eks_pod_identity_association.karpenter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eks_pod_identity_association) | resource |
| [aws_iam_policy.crossplane_ec2](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.crossplane_eks](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.crossplane_iam](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.crossplane_kms](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [aws_iam_policy.crossplane_s3](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_policy) | resource |
| [helm_release.aws_ebs_csi_driver](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.cilium](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.flux-operator](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [helm_release.karpenter](https://registry.terraform.io/providers/hashicorp/helm/latest/docs/resources/release) | resource |
| [kubectl_manifest.flux](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.gateway_api_crds](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/manifest) | resource |
| [kubectl_manifest.karpenter](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/resources/manifest) | resource |
| [kubernetes_annotations.gp2](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/annotations) | resource |
| [kubernetes_secret.flux_system](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/secret) | resource |
| [kubernetes_storage_class_v1.gp3](https://registry.terraform.io/providers/hashicorp/kubernetes/latest/docs/resources/storage_class_v1) | resource |
| [aws_caller_identity.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_ecrpublic_authorization_token.token](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/ecrpublic_authorization_token) | data source |
| [aws_eks_cluster_auth.cluster_auth](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/eks_cluster_auth) | data source |
| [aws_secretsmanager_secret_version.github_pat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |
| [aws_security_group.tailscale](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/security_group) | data source |
| [aws_subnets.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_subnets.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/subnets) | data source |
| [aws_vpc.selected](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/vpc) | data source |
| [http_http.gateway_api_crds](https://registry.terraform.io/providers/hashicorp/http/latest/docs/data-sources/http) | data source |
| [kubectl_filename_list.flux](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/data-sources/filename_list) | data source |
| [kubectl_filename_list.karpenter_default](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/data-sources/filename_list) | data source |
| [kubectl_filename_list.karpenter_io](https://registry.terraform.io/providers/alekc/kubectl/latest/docs/data-sources/filename_list) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cilium_version"></a> [cilium\_version](#input\_cilium\_version) | Cilium cluster version | `string` | `"1.16.5"` | no |
| <a name="input_cluster_identity_providers"></a> [cluster\_identity\_providers](#input\_cluster\_identity\_providers) | Map of cluster identity provider configurations to enable for the cluster. | `any` | `{}` | no |
| <a name="input_cluster_name"></a> [cluster\_name](#input\_cluster\_name) | Name of the EKS cluster to be created | `string` | n/a | yes |
| <a name="input_cluster_version"></a> [cluster\_version](#input\_cluster\_version) | k8s cluster version | `string` | `"1.31"` | no |
| <a name="input_ebs_csi_driver_chart_version"></a> [ebs\_csi\_driver\_chart\_version](#input\_ebs\_csi\_driver\_chart\_version) | EBS CSI Driver Helm chart version | `string` | `"2.25.0"` | no |
| <a name="input_enable_flux_image_update_automation"></a> [enable\_flux\_image\_update\_automation](#input\_enable\_flux\_image\_update\_automation) | Enable Flux image update automation | `bool` | `false` | no |
| <a name="input_enable_ssm"></a> [enable\_ssm](#input\_enable\_ssm) | If true, allow to connect to the instances using AWS Systems Manager | `bool` | `false` | no |
| <a name="input_env"></a> [env](#input\_env) | The environment of the EKS cluster | `string` | n/a | yes |
| <a name="input_flux_git_ref"></a> [flux\_git\_ref](#input\_flux\_git\_ref) | Git branch or tag in the format refs/heads/main or refs/tags/v1.0.0 | `string` | n/a | yes |
| <a name="input_flux_operator_version"></a> [flux\_operator\_version](#input\_flux\_operator\_version) | Flux Operator version | `string` | `"0.12.0"` | no |
| <a name="input_flux_sync_repository_url"></a> [flux\_sync\_repository\_url](#input\_flux\_sync\_repository\_url) | The repository URL to sync with Flux | `string` | n/a | yes |
| <a name="input_gateway_api_version"></a> [gateway\_api\_version](#input\_gateway\_api\_version) | Gateway API CRDs version | `string` | `"v1.2.0"` | no |
| <a name="input_github_token_secretsmanager_id"></a> [github\_token\_secretsmanager\_id](#input\_github\_token\_secretsmanager\_id) | SecretsManager id from where to retrieve the Github Personal Access Token. (The key must be 'github-token') | `string` | `"github/flux-github-pat"` | no |
| <a name="input_iam_role_additional_policies"></a> [iam\_role\_additional\_policies](#input\_iam\_role\_additional\_policies) | Additional policies to be added to the IAM role | `map(string)` | `{}` | no |
| <a name="input_karpenter_limits"></a> [karpenter\_limits](#input\_karpenter\_limits) | Define limits for Karpenter per node pool. | <pre>map(object(<br>    {<br>      cpu    = optional(number, 50),<br>      memory = optional(string, "50Gi")<br>    }<br>    )<br>  )</pre> | n/a | yes |
| <a name="input_karpenter_version"></a> [karpenter\_version](#input\_karpenter\_version) | Karpenter version | `string` | `"1.1.1"` | no |
| <a name="input_region"></a> [region](#input\_region) | AWS Region | `string` | `"eu-west-3"` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | A map of tags to add to all resources | `map(string)` | `{}` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
