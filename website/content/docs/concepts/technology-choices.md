---
title: Technology choices
weight: 50
description: The reasoning behind each major component, and what it was chosen over.
lastVerified: 2026-08-20
---

A stack list tells you what is installed. It does not tell you what the
alternative was, or what the choice cost — which is the part worth reading
if you are deciding whether to copy any of it.

Versions are not here on purpose; they belong in
[the technology stack reference]({{< relref "/docs/reference/technology-stack.md" >}}),
where each one cites the file that pins it.

## The principles behind the picks

**Prefer the boring option, except where boring means unsupported.** Most
choices here are conventional. The exceptions are deliberate and each has a
decision record.

**Prefer an operator with a CRD to a Helm chart with a values file.** A CRD
is an API that other things can compose against; a values file is a
configuration blob that only its own chart understands.

**Prefer open source without a licence cliff.** Several picks below are
about avoiding a rug-pull rather than about technical merit.

**Pay for a choice once.** Where a component is load-bearing, it is worth
being deliberate; where it is replaceable, it is not worth agonising over.

## The decisions with records

| Choice | Over | Why | Record |
|---|---|---|---|
| KCL for compositions | patch-and-transform, Go templates | Readable conditionals and loops; testable before deploy | [ADR-0001]({{< relref "/docs/decisions/0001-use-kcl-for-crossplane-compositions.md" >}}) |
| EKS Pod Identity | IRSA | Simpler trust policies, better audit trail, no OIDC management | [ADR-0002]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}}) |
| vLLM production stack | KServe | Fewer moving parts for the serving case actually needed | [ADR-0003]({{< relref "/docs/decisions/0003-vllm-production-stack-over-kserve.md" >}}) |
| S3 Files for model weights | alternatives evaluated in the record | Access pattern and cost fit | [ADR-0004]({{< relref "/docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md" >}}) |
| GKE Standard with self-managed Cilium | Autopilot, Dataplane V2 | Keeps one CNI across clouds | [ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}) |
| ComputeClass on GCP | Karpenter | The GCP Karpenter provider is not production-ready | [ADR-0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}}) |
| Cloud-shaped platform APIs, neutral developer APIs | one abstraction for both | Portability where it pays, honesty where it doesn't | [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}) |

## The ones without records

Not every choice needed an ADR. The short reasoning:

**Flux over Argo CD.** Flux's controllers compose as CRDs and its
`dependsOn` model expresses the ordering this platform needs. Argo CD would
also have worked; this is a preference, not a verdict.

**Cilium over the VPC CNI.** eBPF datapath, kube-proxy replacement, network
policy and Gateway API from one component instead of four. The cost is real
and documented: prefix delegation interacts badly with the Gateway API L7
proxy, and WireGuard is load-bearing as a workaround rather than a
performance choice.

**VictoriaMetrics over Prometheus.** Lower resource consumption at the same
retention, and an operator with CRDs for scrape config and rules.
VictoriaLogs and VictoriaTraces then follow for consistency of query surface
and operational model.

**OpenBao over Vault.** An open-source fork after Vault's licence change.
The trade-off is a smaller ecosystem and occasional rough edges — the 2.6
line carries an open upstream deadlock that this platform works around with
serialised writes rather than a version pin.

**Crossplane over Terraform for application infrastructure.** Not because
Terraform is worse at describing cloud resources — it is better — but
because a claim reconciled by a controller is continuously enforced, while a
Terraform plan is only true at apply time. OpenTofu still owns the layers
below Kubernetes, which is why both are here.

**Tailscale over a bastion or VPN appliance.** Identity-based access with
ACL tags, no host to patch.

## Reading on

- [Technology stack]({{< relref "/docs/reference/technology-stack.md" >}}) —
  every version, with the file that pins it
- [Decisions]({{< relref "/docs/decisions/_index.md" >}}) — the full records,
  including options rejected
