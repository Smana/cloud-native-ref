---
title: Decisions
weight: 60
description: Architecture decision records — what was chosen, and what it was chosen over.
lastVerified: 2026-08-27
---

Architecture decision records for the choices that would otherwise need
re-litigating every time someone asks "why not X instead?" — what was chosen,
what it was chosen over, and the trade-off that made the difference.

An ADR records the "why" behind a decision, not just the "what": the context
that forced a choice, the options considered, and the consequences accepted.
Specs MUST comply with the [platform constitution]({{< relref "/docs/reference/platform-constitution.md" >}})
and MAY reference an ADR for context on a technology choice; a constitution
amendment requires an ADR to document the change.

## The principles behind the picks

**Prefer the boring option, except where boring means unsupported.** Most
choices here are conventional. The exceptions are deliberate, and each has a
record below.

**Prefer an operator with a CRD to a Helm chart with a values file.** A CRD is
an API that other things can compose against; a values file is a configuration
blob that only its own chart understands.

**Prefer open source without a licence cliff.** Several records below are about
avoiding a rug-pull rather than about technical merit.

**Pay for a choice once.** Where a component is load-bearing it is worth being
deliberate; where it is replaceable it is not worth agonising over.

## When a choice needs a record

A technology choice with a rejected alternative requires an ADR before merge.
If you can name what it was chosen over, write the record. If nothing credible
competed, it is an installation and not a decision — say so in the pull request
rather than leaving it unsaid. Version bumps, chart-value changes and
single-file fixes never need one.

## The records

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001]({{< relref "/docs/decisions/0001-use-kcl-for-crossplane-compositions.md" >}}) | Use KCL for Crossplane Compositions | Accepted | 2024-09-29 |
| [0002]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}}) | Use EKS Pod Identity over IRSA | Accepted | 2024-04-15 |
| [0003]({{< relref "/docs/decisions/0003-vllm-production-stack-over-kserve.md" >}}) | Use vLLM Production Stack over KServe + llm-d for v1 LLM Platform | Accepted | 2026-04-30 |
| [0004]({{< relref "/docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md" >}}) | Use Amazon S3 Files for LLM Model Weights Storage | Accepted | 2026-05-01 |
| [0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}) | GKE Standard with self-managed Cilium (not Dataplane V2, not Autopilot) | Accepted | 2026-08-18 |
| [0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}}) | GKE node auto-provisioning (ComputeClass) over Karpenter on GCP | Accepted | 2026-08-18 |
| [0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}) | Cloud abstraction boundaries — cloud-shaped platform APIs, neutral developer APIs | Accepted | 2026-08-18 |
| [0008]({{< relref "/docs/decisions/0008-flux-over-argocd.md" >}}) | Use Flux for GitOps reconciliation | Accepted | 2026-08-21 |
| [0009]({{< relref "/docs/decisions/0009-cilium-over-vpc-cni.md" >}}) | Use Cilium instead of the AWS VPC CNI | Accepted | 2026-08-21 |
| [0010]({{< relref "/docs/decisions/0010-victoriametrics-over-prometheus.md" >}}) | Use VictoriaMetrics rather than Prometheus | Accepted | 2026-08-21 |
| [0011]({{< relref "/docs/decisions/0011-openbao-over-vault.md" >}}) | Use OpenBao rather than HashiCorp Vault | Accepted | 2026-08-21 |
| [0012]({{< relref "/docs/decisions/0012-crossplane-and-opentofu.md" >}}) | Use Crossplane and OpenTofu, split at the Kubernetes boundary | Accepted | 2026-08-21 |
| [0013]({{< relref "/docs/decisions/0013-tailscale-over-bastion.md" >}}) | Use Tailscale for private access rather than a bastion | Accepted | 2026-08-21 |
| [0014]({{< relref "/docs/decisions/0014-opentofu-over-terraform.md" >}}) | Use OpenTofu rather than Terraform | Accepted | 2026-08-21 |
| [0015]({{< relref "/docs/decisions/0015-gateway-api-over-ingress-nginx.md" >}}) | Use Gateway API rather than Ingress | Accepted | 2026-08-21 |
| [0016]({{< relref "/docs/decisions/0016-kyverno-over-gatekeeper.md" >}}) | Use Kyverno for admission policy | Accepted | 2026-08-21 |
| [0017]({{< relref "/docs/decisions/0017-multi-cloud-dns-naming.md" >}}) | Multi-cloud DNS naming — cloud-agnostic public, cloud-pinned private | Accepted | 2026-08-23 |
| [0018]({{< relref "/docs/decisions/0018-per-cloud-opentofu-state.md" >}}) | Per-cloud OpenTofu state — GCP state in GCS, AWS state in S3 | Accepted | 2026-08-25 |
| [0019]({{< relref "/docs/decisions/0019-cross-cloud-dns-federation.md" >}}) | Cross-cloud DNS federation — GKE workloads assume an AWS role for Route53 | Accepted | 2026-08-25 |
| [0020]({{< relref "/docs/decisions/0020-harbor-gcs-workload-identity.md" >}}) | Harbor on GCS — native driver with Workload Identity, not S3-compatible HMAC | Accepted | 2026-08-26 |
| [0021]({{< relref "/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md" >}}) | Cloud Storage FUSE for LLM model weights on GCP | Accepted | 2026-08-26 |
| [0022]({{< relref "/docs/decisions/0022-single-identity-provider-across-clouds.md" >}}) | One identity provider across both clouds, hosted on AWS and named by a variable | Superseded by [0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) | 2026-08-27 |
| [0023]({{< relref "/docs/decisions/0023-portable-secret-store-names.md" >}}) | Secret store keys use a name grammar both clouds accept | Accepted | 2026-08-27 |
| [0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) | The identity provider is deployable on either cloud, defaulting to AWS | Accepted | 2026-08-27 |
| [0025]({{< relref "/docs/decisions/0025-cloud-managed-secret-stores.md" >}}) | Cloud-managed secret stores as the store of record, OpenBao scoped to the PKI | Accepted | 2026-08-27 |
| [0026]({{< relref "/docs/decisions/0026-headlamp-auth-proxy-on-gke.md" >}}) | Headlamp authenticates behind an auth proxy on GKE, not against the cluster | Accepted | 2026-08-28 |
| [0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}}) | AWS is the primary cloud, and cross-cloud singletons live there | Accepted | 2026-08-29 |

Starting a new one? Copy the [template]({{< relref "/docs/decisions/template.md" >}}).
