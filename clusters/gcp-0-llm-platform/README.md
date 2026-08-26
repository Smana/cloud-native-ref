# LLM Platform — opt-in Flux umbrella (GCP)

The 6 child Flux Kustomizations in this directory are aggregated by the umbrella at
`../gcp-0/llm-platform.yaml`. This directory is a **sibling** of `clusters/gcp-0/` — not a
sub-path — so that `flux-system` (which recursively syncs `clusters/gcp-0/`) does not
auto-discover the children and bypass the umbrella's `spec.suspend: true` gate. The umbrella
defaults to `spec.suspend: true`, so none of these children — and therefore none of the
LLM-platform resources — are created on a fresh cluster.

GCP analogue of `clusters/aws-0-llm-platform/`. See [ADR-0021](../../website/content/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md)
for why the weights path differs from `aws-0`.

| Child Kustomization | Path | Resources |
|---|---|---|
| `envoy-gateway` | `infrastructure/base/envoy-gateway` | Envoy Gateway controller (provides the GatewayClass `envoy-ai-gateway` consumes) |
| `envoy-ai-gateway` | `infrastructure/base/envoy-ai-gateway` | Envoy AI Gateway: AIGatewayRoute → AIServiceBackend → per-model `Backend`, direct — no proxy hop. Also carries the `EnvoyPatchPolicy` that inserts the Semantic Router ext_proc filter |
| `vllm-semantic-router` | `infrastructure/base/vllm-semantic-router` | Iris router HelmRelease (`MoM` virtual model + cascade decisions[]) |
| `llm-platform-apps` | `apps/gcp-0/llm` | 4 InferenceService claims + the GCS bucket + static PV/PVC (ADR-0021) |
| `llm-platform-security-wi` | `security/gcp-0/llm-models-preload` | `xplane-llm-models-preload` `GCPWorkloadIdentity` — write access to the bucket for the preload Job only |
| `llm-platform-promptfoo` | `tooling/base/promptfoo` | Nightly Promptfoo eval CronJob — gated under the LLM umbrella so it doesn't fire when SR is suspended |

## Two absences, not oversights

- **No `gpu-nodepools` child.** `infrastructure/gcp-0/computeclass/gpu-l4.yaml` already
  provisions `g2` + `nvidia-l4` on spot (workstream 4), applied by the always-on `infrastructure`
  Kustomization in `clusters/gcp-0/`. There is nothing GPU-capacity-related left for this umbrella
  to gate — the LLM apps just consume a ComputeClass that exists regardless of whether this
  umbrella is suspended.
- **No `runtimeclass-nvidia` child.** That exists on `aws-0` only because Bottlerocket's NVIDIA AMI
  advertises `nvidia.com/gpu` through kubelet natively and crashloops the upstream device plugin —
  the RuntimeClass is a workaround so the scheduler still has something to map
  `runtimeClassName: nvidia` onto. GKE manages GPU drivers itself and needs no
  `runtimeClassName` at all (see the header comment in `infrastructure/gcp-0/computeclass/gpu-l4.yaml`)
  — there is nothing this child would even be gating.

## Known gap: enabling this today does not fully work

This ships suspended, and **that is a real gate, not a formality.** Two things originally stopped the
platform from serving traffic correctly. **One is now closed** (KEDA, below); one remains, and it is
the blocking one:

- **Serving pods cannot read the weights bucket.** The Cloud Storage FUSE CSI driver
  authenticates as the *mounting pod's own* Kubernetes ServiceAccount via Workload Identity
  Federation for GKE, not the node's default identity (confirmed against Google's driver docs and
  this repo's own `GCPWorkloadIdentity` composition — see
  `security/gcp-0/llm-models-preload/workloadidentity.yaml`'s header). Each InferenceService
  claim's serving ServiceAccount therefore needs its own read-only `GCPWorkloadIdentity`
  (`roles/storage.objectViewer`, scoped to this bucket) — the same role AWS's per-claim read-only
  EPI plays, rendered by the `InferenceService` composition. **The composition has no GCP support
  for this yet.** Until it does, a resumed platform preloads weights fine (the shared preload
  identity in this directory covers that) but vLLM pods fail to mount the bucket for reading.
- ~~**KEDA is not installed on `gcp-0`.**~~ **CLOSED.** `infrastructure/gcp-0/kustomization.yaml`
  now pulls `../base/keda` — the same shared base `aws-0` uses, verified cloud-neutral first (no
  IRSA, no IAM roles, no ARNs, and its CiliumNetworkPolicy addresses `toEntities: kube-apiserver`
  rather than a CIDR). The `InferenceService` composition's per-claim `ScaledObject` (SPEC-001) has
  a controller to reconcile it.

  One difference from `aws-0` worth knowing: `gcp-0`'s `infrastructure` Kustomization does **not**
  health-check KEDA's HelmRelease, where `aws-0`'s does. It health-checks nothing today, and adding
  a check for KEDA alone would make the whole path block on it — a KEDA failure would wedge
  everything downstream, including resources that do not use it. Worth revisiting when the umbrella
  is actually resumed.

A README that lists how to enable something without saying it will not work is worse than one
that says nothing — so: **do not resume `llm-platform` on `gcp-0` until the serving-pod identity
gap above is closed.** That one needs GCP support in the `InferenceService` composition
(`Smana/crossplane-configuration`) and a pin bump here; it cannot be fixed in this repository.

## Enable

```bash
flux resume kustomization llm-platform -n flux-system
```

After resume, watch the children come up:

```bash
flux get kustomizations -n flux-system | grep llm-platform
```

Unlike `aws-0`, there is no separate OpenTofu opt-in stack to release first — the weights bucket
and its preload identity are Crossplane claims applied by this same umbrella
(`llm-platform-apps`, `llm-platform-security-wi`), not a Terraform-managed filesystem. This
umbrella is the whole opt-in surface. Enabling it provisions real GPU spot capacity
(`g2` + `nvidia-l4`, see `infrastructure/gcp-0/computeclass/gpu-l4.yaml`) the moment an
InferenceService claim schedules a pod — this is not free.

## Disable (preserve cluster state)

```bash
flux suspend kustomization llm-platform -n flux-system
```

Suspend stops reconciliation but does **not** delete in-cluster resources — children, vLLM pods,
GPU nodes, etc. all stay until explicitly removed.

## Full teardown

```bash
flux suspend kustomization llm-platform -n flux-system
flux delete kustomization \
  llm-platform-apps llm-platform-security-wi envoy-ai-gateway envoy-gateway \
  vllm-semantic-router llm-platform-promptfoo \
  -n flux-system --silent
```

**Data preserved** (orphan policy on the Crossplane `Bucket` MR — see `apps/gcp-0/llm/gcs-bucket.yaml`,
same reasoning as `security/gcp-0/openbao-snapshot/gcs-bucket.yaml`): the
`<project_id>-ogenki-llm-models` bucket holding the HuggingFace model weights. To remove it
intentionally, use the `gcloud` CLI.
