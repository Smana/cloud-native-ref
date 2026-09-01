---
title: Add a cloud provider
weight: 30
description: ADR-0007's rule made operational — what a new provider must implement, and what must not change.
lastVerified: 2026-08-27
---

The platform runs on AWS **and GCP**, and the second cloud was an addition
rather than a rewrite. What made that possible is a single rule, and the
discipline to apply it consistently.

This page is no longer a plan. Everything below has been through one full
round — see [Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}})
for what the result actually looks like, including where the rule cost
something.

## The rule

**Platform-facing APIs stay cloud-shaped. Developer-facing APIs stay
cloud-neutral.** The line is drawn by audience, not by layer —
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
records the reasoning, including the rejected option: one neutral abstraction
over both.

## What a new provider must implement

| Layer | What is needed | Why it is cloud-shaped |
|---|---|---|
| Network | VPC-equivalent, subnets, private DNS zone, VPN reachability | Topology and naming differ fundamentally |
| Cluster | Managed Kubernetes with a CNI you control | The bootstrap sequence is provider-specific |
| Identity | Workload-to-cloud-API binding | Trust policy shapes are not interchangeable |
| Secrets store | Somewhere ESO can read from | Provider-specific auth |
| Node autoscaling | Karpenter or the provider's equivalent | Not every cloud has a production-ready Karpenter |

Each gets its own OpenTofu stack and its own section in the documentation. GCP
filled every row: `opentofu/gcp/network`, `gke/{init,configure}`,
`GCPWorkloadIdentity`, Google Secret Manager, and Node Auto-Provisioning with
ComputeClasses. The decisions behind each are
[ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}),
[ADR-0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}})
and [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}).

Two rows carried a surprise worth passing on. **Node autoscaling** is the
clearest vindication of the table: Karpenter has no production-ready GCP
provider, so the row had to be filled by something else entirely rather than
ported. And **DNS** is the row the table does not have — it turned out not to be
cleanly per-cloud at all, because the public zone must stay in one place for
Let's Encrypt to resolve a challenge. That is
[ADR-0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}}),
and it is the one place the platform accepted a deliberate cross-cloud
dependency.

## The variable contract a new cloud must satisfy

Each cloud's `configure` stack publishes a ConfigMap in `flux-system` that every
Flux Kustomization substitutes from. The keys both clouds define are the real
portability interface — **a manifest in `base/` may only read one of these**:

| Key | Example (`aws-0` / `gcp-0`) |
|---|---|
| `cluster_name` | `aws-0` / `gcp-0` |
| `cluster_endpoint` | the API server host |
| `region` | `eu-west-3` / `europe-west4` |
| `environment` | `dev` |
| `storage_class` | `gp3` / `standard-rwo` |
| `private_domain_name` | `priv.aws.ogenki.io` / `priv.gcp.ogenki.io` |
| `public_domain_name` | `cloud.ogenki.io` / `gcp.cloud.ogenki.io` |
| `identity_provider_url` | where ZITADEL actually lives ([ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}})) |
| `openbao_cidr` | the CIDR holding OpenBao's internal endpoint |
| `openbao_snapshot_secret` | secret-store key, per-cloud grammar ([ADR-0023]({{< relref "/docs/decisions/0023-portable-secret-store-names.md" >}})) |
| `llm_hf_token_secret` | as above |
| `route53_public_zone_id` | the one public zone both clouds write to ([ADR-0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}})) |

Everything else each stack publishes is **cloud-shaped and stays in that cloud's
overlays** — `aws_account_id`, `oidc_provider_arn`, `vpc_id`, `karpenter_queue_name`
on one side; `project_id`, `project_number`, `workload_pool`, `pod_cidr` on the
other. A third cloud adds its own such keys freely; it must supply every key in
the table above.

The table is derived, not authoritative. To regenerate it from the stacks
themselves:

```python
# python3, from the repo root
import importlib.util
spec = importlib.util.spec_from_file_location("cs", "scripts/flux-schema/check-substitution.py")
cs = importlib.util.module_from_spec(spec); spec.loader.exec_module(cs)
aws, gcp = map(set, (cs.configmap_keys("eks-aws-0-vars"), cs.configmap_keys("gke-gcp-0-vars")))
print(sorted(aws & gcp))          # the portability interface
print(sorted(aws ^ gcp))          # cloud-shaped, stays in overlays
```

{{< callout type="warning" >}}
**Flux substitutes an undefined variable to the empty string.** A `base/`
manifest reading a key your cloud does not define does not fail — it renders a
hostname with a hole in it. `scripts/flux-schema/check-substitution.py` runs in
CI against this: it reads each cluster's real keys from the `flux_cluster_vars`
resource in `opentofu/*/configure/kubernetes.tf` and fails when a Kustomization
applies a variable **its own cluster** never defines.

Note the limit of that check — it is per-cluster, not an intersection. A
manifest in `base/` that reads an AWS-only key still passes for as long as only
`aws-0` references the directory; the failure surfaces the day a second cluster
wires it up. Keeping `base/` to the table above is a convention, not yet a gate.
{{< /callout >}}

## What gains a sibling, not a field

When an API is genuinely cloud-shaped, add a **sibling XRD** rather than a
discriminated union: `EPI` for AWS, `GCPWorkloadIdentity` for GCP, both
consumed internally by the developer-facing compositions.
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
works the case through `EPI`, whose central field — inline AWS IAM JSON — has
no neutral form.

## Where the cloud list is enumerated

Three places name the clouds explicitly, and a new lane has to appear in all
three or it half-works:

| Place | What it drives |
|---|---|
| `global.stack_cloud` in `opentofu/config.tm.hcl` | which lane a stack belongs to, from its tags |
| `--tm-check` in `scripts/tm-provisioner.sh` | whether `TM_CLOUD` selects that lane |
| `KNOWN_CLOUDS` in `scripts/validate-idp-topology.sh` | which values `primary_cloud` may take |

The third is the one that surprises: a new lane that is *not* primary must also
have `spec.suspend: true` on its own `clusters/<cluster>/security/zitadel.yaml`,
or the topology check fails — the identity provider is a primary-cloud
singleton ([ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}})),
so a third cloud consumes it rather than running its own.

## What must not change

`App` and `SQLInstance` claims are developer-facing and stay neutral. The
same claim should mean the same thing on either cloud.

That does not mean nothing underneath changes — the S3 bucket becomes a GCS
bucket and the IAM role becomes a workload identity binding. It means the
*claim* does not, so an application team's manifests are not a per-cloud
artifact. `App` holds this today: the same claim renders an S3 bucket plus an
`EPI` on one cloud and a GCS bucket plus a `GCPWorkloadIdentity` on the other.

{{< callout type="info" >}}
**A neutral claim is a promise the compositions have to keep — and
`SQLInstance` now keeps it.** Until crossplane-configuration v0.4.0 its GCP
Composition deliberately failed evaluation rather than composing nothing — the
right interim failure mode, since a claim that cannot be honoured should say
so at reconcile time. Both clouds now render from the same KCL module,
differing only in where barman writes its backups (Cloud Storage rather than
S3) and the identity that writes them, and the CloudNativePG operator runs on
both clusters from the same base — dashboards included.
{{< /callout >}}

Where a genuinely cloud-specific knob is unavoidable, it belongs in a
clearly-marked optional sub-block, not spread through the API.

## The test to apply

Before adding an abstraction, ask who reads it: a platform engineer
configuring one cloud gets a cloud-shaped API, an application developer who
should not care gets a neutral one.
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
spells out the test — and why an API that only looks neutral fails worse than
one that is visibly cloud-specific.

## Reading on

- [Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}})
  — the AWS/GCP result of applying this rule, service by service
- [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}) — how
  the [AWS]({{< relref "/docs/platform/foundations/aws.md" >}}) and
  [GCP]({{< relref "/docs/platform/foundations/gcp.md" >}}) stacks are
  structured, and where a sibling would slot in
- [Developer platform]({{< relref "/docs/platform/developer-platform/_index.md" >}})
  — the neutral APIs that must keep working unchanged
