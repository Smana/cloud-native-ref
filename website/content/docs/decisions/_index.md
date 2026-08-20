---
title: Decisions
weight: 60
description: Architecture decision records — what was chosen, and what it was chosen over.
lastVerified: 2026-08-20
---

Architecture decision records for the choices that would otherwise need
re-litigating every time someone asks "why not X instead?" — what was chosen,
what it was chosen over, and the trade-off that made the difference.

An ADR records the "why" behind a decision, not just the "what": the context
that forced a choice, the options considered, and the consequences accepted.
Specs MUST comply with the [platform constitution]({{< relref "/docs/reference/platform-constitution.md" >}})
and MAY reference an ADR for context on a technology choice; a constitution
amendment requires an ADR to document the change.

| ADR | Title | Status | Date |
|-----|-------|--------|------|
| [0001]({{< relref "/docs/decisions/0001-use-kcl-for-crossplane-compositions.md" >}}) | Use KCL for Crossplane Compositions | Accepted | 2024-01-15 |
| [0002]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}}) | Use EKS Pod Identity over IRSA | Accepted | 2024-01-15 |
| [0003]({{< relref "/docs/decisions/0003-vllm-production-stack-over-kserve.md" >}}) | Use vLLM Production Stack over KServe + llm-d for v1 LLM Platform | Accepted | 2026-04-30 |
| [0004]({{< relref "/docs/decisions/0004-amazon-s3-files-for-model-weights-storage.md" >}}) | Use Amazon S3 Files for LLM Model Weights Storage | Accepted | 2026-05-01 |
| [0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}}) | GKE Standard with self-managed Cilium (not Dataplane V2, not Autopilot) | Accepted | 2026-08-18 |
| [0006]({{< relref "/docs/decisions/0006-nap-computeclass-over-karpenter.md" >}}) | GKE node auto-provisioning (ComputeClass) over Karpenter on GCP | Accepted | 2026-08-18 |
| [0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}) | Cloud abstraction boundaries — cloud-shaped platform APIs, neutral developer APIs | Accepted | 2026-08-18 |

Starting a new one? Copy the [template]({{< relref "/docs/decisions/template.md" >}}).
