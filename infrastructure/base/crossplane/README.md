# Crossplane Configuration

## Writing and Pushing Functions

We have chosen [KCL (Kusion Configuration Language)](https://github.com/crossplane-contrib/function-kcl) to write most of the logic in our Crossplane compositions. These functions are packaged as OCI artifacts. For this repository, we use ephemeral OCI registries because we frequently destroy and recreate the platform. However, for production environments, more persistent solutions should be considered.

Here is an example for creating and pushing a composition for an RDS instance:

```console
# KCL modules moved to https://github.com/Smana/crossplane-configuration (apis/<api>/kcl)
kcl mod init rdsinstance
```

After writing the code, we can render the output directly from the module directory using the command

```console
cd rdsinstance
kcl run -Y settings-example.yam
```

Then you can push it to an OCI registry as follows:

```console
cd rdsinstance
kcl mod push oci://ttl.sh/ogenki-cnref/rdsinstance:v0.0.1-24h
```

Here we're using [TTL.sh](https://ttl.sh/) and the OCI artifact will be available for 24 hours, as specified in the tag. You can then reference it in your Crossplane composition:

```yaml
...
spec:
...
    pipeline:
...
        - step: rds
          functionRef:
              name: function-kcl
          input:
              apiVersion: krm.kcl.dev/v1alpha1
              kind: KCLRun
              spec:
                  target: Resources
                  source: oci://ttl.sh/ogenki-cnref/rdsinstance:v0.0.1-24h
```

## Validating a composition

**Compositions are not in this repository.** They live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration) and ship here
as a Configuration package — see `configuration-aws/configuration-packages.yaml` for the pinned version.
Render, test and validate them there with `task check`; then bump the pin here.

What this directory still owns is the cluster's side of the wiring, and it is split by cloud
because a `Provider` and a `ManagedResourceActivationPolicy` are cluster-scoped:

| Directory | Cloud | Contents |
|---|---|---|
| `controller/` | both | The Crossplane chart. Nothing cloud-specific. |
| `functions/` | both | Function packages, version-pinned. Shared so the two clouds cannot drift. |
| `providers-aws/` | AWS | 5 provider packages, `aws-config` runtime config, activation policy, extra RBAC. |
| `configuration-aws/` | AWS | ProviderConfig (`PodIdentity`), `eks-environment`, the Configuration package pin. |
| `providers-gcp/` | GCP | `provider-gcp-cloudplatform`, `gcp-config` runtime config, activation policy. |
| `configuration-gcp/` | GCP | ProviderConfig (`InjectedIdentity` + `projectID`), `gke-environment`, the Configuration package pin. |

Both clouds pin their Configuration package by version. Bumping either one is a **two-PR cutover
with `prune: disabled` on the first** whenever the XRDs it ships already exist on the cluster:
a package *adopts* existing XRDs and preserves their uids, but Flux prune deletes them in the gap,
and deleting an XRD destroys every claim it owns (#1774 / #1778).

The GCP pin was introduced without that dance because no `GCPWorkloadIdentity` XRD or claim had ever
existed on any cluster — nothing to adopt, nothing to destroy. That exemption is specific to a first
install, and does not carry to the next cluster or the next bump.
