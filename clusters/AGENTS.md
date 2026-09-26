# Clusters — the Flux graph and the opt-in gates

Flux is the single source of truth for cluster state. Prefer a `HelmRelease` over raw manifests
wherever an upstream chart exists.

## Read the graph, do not infer it

The broad ordering is Namespaces → CRDs → Crossplane → EKS Pod Identities → Security →
Infrastructure → Observability → Applications.

**Do not copy a `dependsOn` from that chain.** The real graph is wider: Crossplane is three
sequential Kustomizations, Karpenter sits outside them, `infrastructure` depends on `karpenter` +
`eks-pod-identities` rather than on `security`, and several `flux/*` Kustomizations run in
parallel. Read `aws-0/` — or the derived graph at
[Platform → GitOps](https://cnref.ogenki.io/docs/platform/gitops/) — before wiring a new component.

**A health-checked resource merged without its namespace wedges the whole `dependsOn` tree.** Fix
the root, not the symptom.

**A source under an app directory inherits `sharding.fluxcd.io/key=apps`** and the default shard
cannot find it. Sources live under `flux-sources`.

## Variable substitution

`./scripts/ci/flux-schema/check-substitution.py` reads these Kustomizations directly and fails when
one applies a `${var}` its own cluster's ConfigMap does not define. Flux substitutes an **empty
string** for an undefined variable — schema-valid and silently wrong, so the rendered bundle looks
perfect either way. It also fails when a Kustomization applies variables with no `postBuild` wired
at all, where Flux would apply the literal `${var}`.

Each cluster's real keys come from the `flux_cluster_vars` resource in
`opentofu/*/configure/kubernetes.tf`.

A `substituteFrom` entry may name a **Secret** as well as a ConfigMap. None does today. A Secret's
keys are created in-cluster at runtime so they cannot be checked here — those variables are
**reported as a note** rather than failed, and rather than silently skipped.

## The self-hosted LLM platform — three gates on AWS

All three must be released for an end-to-end deploy, the gateway layer first. The default
`terramate script run deploy` and the default Flux reconciliation leave the cluster entirely
LLM-free.

| Layer | Gate | Release with |
|---|---|---|
| AWS (S3 Files filesystem + IAM) | `opentofu/aws/llm-platform/` tagged `opt-in` | `TM_LLM_PLATFORM_ENABLED=true terramate -C opentofu/aws/llm-platform script run deploy` |
| Kubernetes, gateway layer | `aws-0/ai-gateway.yaml`, `spec.suspend: true` | `flux resume kustomization ai-gateway -n flux-system` |
| Kubernetes, GPU models | `aws-0/llm-platform.yaml`, `spec.suspend: true` | `flux resume kustomization llm-platform -n flux-system` |

The umbrella aggregates 5 children under `aws-0-llm-platform/`, kept a **sibling** of `aws-0/` so
that `flux-system`'s recursive sync cannot auto-apply the children and bypass the umbrella suspend.
See `aws-0-llm-platform/README.md` for the child manifests and the teardown procedure.

The gateway layer — Envoy Gateway, Agent Router, the Semantic Router and the human/system Gateway
`ai-gateway` — is its own umbrella (`aws-0/ai-gateway.yaml` → `aws-0-ai-gateway/`, OD-3), CPU
only and **suspended by default**. Resume it first with
`flux resume kustomization ai-gateway -n flux-system`: `llm-platform` and `agent-platform` both
depend on it. Resuming it needs no seeding step: the Z.ai key comes from OpenBao's restored
`runlore/credentials`, and the rate-limit password is generated in-cluster (`aws-0-ai-gateway/README.md`).
Its children kept their names when they moved, so
`dependsOn` edges from `llm-platform` children still resolve. Read that README before resuming
`llm-platform` on a cluster that ran it before the move.

**Autoscaling** (composition v0.5.0+, SPEC-001): every model defaults `min=1` with a KEDA
`ScaledObject` driven by leading vLLM saturation metrics — the `running/max-num-seqs` ratio plus
`kv_cache_usage_perc`. The legacy KEDA HTTP add-on, with a proxy in the data path and a lagging
request-count trigger, is gone; AI Gateway routes directly to each vLLM Service.

### On `gcp-0` — one gate, six children, and do not resume it yet

- **One gate**, `gcp-0/llm-platform.yaml`. There is no `opentofu/gcp/llm-platform/` stack: the
  weights bucket is a Crossplane claim, not a Terraform-managed filesystem.
- **Six children.** No `gpu-nodepools` — `infrastructure/gcp-0/computeclass/gpu-l4.yaml` already
  provisions g2 + L4 on spot. No `runtimeclass-nvidia` — that exists on AWS only because
  Bottlerocket's NVIDIA AMI crashloops the upstream device plugin; GKE manages GPU drivers itself.
- **Weights come from a GCS bucket over the Cloud Storage FUSE CSI driver**, not an S3 Files POSIX
  mount. [ADR-0021](../website/content/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md)
  covers what that gives up. The mount needs the `gke-gcsfuse/volumes` annotation — without it
  there is no FUSE sidecar and the failure reads as a misleading `PermissionDenied` while IAM is
  in fact fine.

> **Both known blockers are closed; the umbrella stays suspended on cost, not breakage.** The
> per-claim read-only identity that serving pods need *is* rendered by the `InferenceService`
> composition as of `crossplane-configuration` v0.4.6, the version already pinned here. KEDA on
> `gcp-0` is also closed. **But none of it has run on a live GKE cluster** — that is a static read
> of the pinned package's golden fixture, not a cluster result. Treat the first resume as a
> validation run; `gcp-0-llm-platform/README.md` lists what to watch, in failure order.
