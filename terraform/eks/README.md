# Control plane EKS cluster

* Create a management EKS cluster in a single zone
* Use SPOT instances
* Use AL2023 AMI
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
repository_name = "demo-cloud-native-ref"

tags = {
  GithubRepo = "demo-cloud-native-ref"
  GithubOrg  = "Smana"
}
```

3. Apply with `tofu apply -var-file variables.tfvars`


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
