# Control plane EKS cluster

* Create a management EKS cluster in a single zone
* Use SPOT instances
* Use Bottlerocket AMI
* Install and configure Karpenter
* Install and configure Flux
* Write a secret that contains the cluster's specific variables that will be used with Flux. (please refer to [variables substitutions](https://fluxcd.io/flux/components/kustomize/kustomization/#post-build-variable-substitution))
* Deploy Cilium

## Prerequisites

The Flux installation process is based on a Github App and, in our example, a secret must be pull from AWS secrets manager.
Here's how to prepare the secret:

1. Create a Json file containing the required information as described in [flux documentation](https://fluxcd.io/flux/components/source/gitrepositories/#github).
  ```console
  jq -n --arg key "$(cat your-githubapp.private-key.pem)" '{githubAppID: "<app_id>", githubAppInstallationID: "<installation_id>", githubAppPrivateKey: $key}' > flux-ghapp.Json
  ```

2. Create the AWS Secret manager resource
  ```console
  aws secretsmanager create-secret --name github/flux-app --description "FluxCD Github App" --region eu-west-3 --secret-string file://flux-ghapp.json
  ```

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
kubectl delete epi --all-namespaces --all && sleep 30 && \
tofu destroy --var-file variables.tfvars
```
