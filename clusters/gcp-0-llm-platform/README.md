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
  provisions `g2` + `nvidia-l4` on spot, applied by the always-on `infrastructure`
  Kustomization in `clusters/gcp-0/`. There is nothing GPU-capacity-related left for this umbrella
  to gate — the LLM apps just consume a ComputeClass that exists regardless of whether this
  umbrella is suspended.
- **No `runtimeclass-nvidia` child.** That exists on `aws-0` only because Bottlerocket's NVIDIA AMI
  advertises `nvidia.com/gpu` through kubelet natively and crashloops the upstream device plugin —
  the RuntimeClass is a workaround so the scheduler still has something to map
  `runtimeClassName: nvidia` onto. GKE manages GPU drivers itself and needs no
  `runtimeClassName` at all (see the header comment in `infrastructure/gcp-0/computeclass/gpu-l4.yaml`)
  — there is nothing this child would even be gating.

## Status: the blocker is closed, but this has never actually run

Two things once stopped this platform from serving correctly on `gcp-0`. **Both are now closed.**
What remains is not a gap but an absence of evidence: no part of this has been exercised on a live
GKE cluster. Resuming is a validation run, not a routine enable.

- ~~**Serving pods cannot read the weights bucket.**~~ **CLOSED at the pinned version.**
  The constraint itself is real and unchanged: the Cloud Storage FUSE CSI driver authenticates as
  the *mounting pod's own* Kubernetes ServiceAccount via Workload Identity Federation for GKE, not
  the node's default identity. So each `InferenceService` claim's serving ServiceAccount needs its
  own read-only `GCPWorkloadIdentity` — the role AWS's per-claim read-only EPI plays. This README
  previously said the composition had no GCP support for that. It does, in
  `crossplane-configuration` **v0.4.5, the version already pinned** in
  `infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml`. Read back from
  that tag's own golden fixture (`tests/golden/inferenceservice-gcp.yaml`), a claim renders:

  ```yaml
  kind: ServiceAccount                       # per-claim, namespace llm
    name: xplane-<model>
  kind: Deployment
    serviceAccountName: xplane-<model>       # the serving pod runs as it
  kind: GCPWorkloadIdentity
    name: xplane-<model>-gcs-read
    bucketRoles:
      - bucket: <project>-ogenki-llm-models
        role: roles/storage.objectViewer     # read-only, scoped to this bucket
    serviceAccount:
      name: xplane-<model>
  ```

  No pin bump is needed. **This is a static check against the pinned package, not a cluster
  result** — the mount has never been performed on a running GKE node, and that is exactly what a
  first resume tests.
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

It still ships suspended, because four L4s and a multi-gigabyte HuggingFace preload should be a
deliberate act rather than a default. But the reason is now cost, not breakage.

**What to watch on the first resume**, in the order it can fail:

1. The `GCPWorkloadIdentity` per claim reaches `Synced=True Ready=True` — the binding exists.
2. The serving pod actually mounts the bucket. A failure here is the FUSE identity path, and it
   surfaces as the pod stuck mounting, not as anything naming Workload Identity.
3. vLLM reads the weights and reports the model ready.

A first resume that gets past (2) is the thing this README could not previously promise.

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
