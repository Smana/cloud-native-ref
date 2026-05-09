# Plan: Self-Hosted LLM Platform with Cascade Routing

**Spec**: [SPEC-NNN](spec.md)
**Status**: draft
**Last updated**: 2026-04-26

> The **plan** covers *HOW* to deliver the spec. It may evolve during implementation (unlike `spec.md`, which freezes after approval). Append-only `clarifications.md` is where decisions are durable. This is a **phased plan** per [`docs/specs/PHASED.md`](../PHASED.md): the design and phase map live here; per-phase task detail lives under [`phases/<N-name>/plan.md`](phases/).

---

## Phases

| Phase | Scope | Depends on | Issue | Status |
|-------|-------|------------|-------|--------|
| 1-gpu-foundation     | New `gpu-l4` Karpenter NodePool + Bottlerocket Accelerated EC2NodeClass + EBS-snapshot warmup pipeline + smoke verification | — | TBD | ⏸ pending |
| 2-inference-stack    | HelmReleases (KEDA, vLLM Production Stack, vLLM Semantic Router) ordered behind Flux dependency hierarchy | 1-gpu-foundation | TBD | ⏸ pending |
| 3-composition        | New KCL composition `XInferenceService` (XRD + composition + main_test.k + README + examples) | 2-inference-stack, 4a-storage-base | TBD | ⏸ pending |
| 4a-storage-base      | S3 bucket `xplane-llm-models` (Crossplane Bucket + Versioning + PublicAccessBlock) + IAM scope (read EPI rendered per-claim by Phase 3 composition; shared writable EPI for preload) | — | TBD | ⏸ pending |
| 4b-s3-files          | **Amazon S3 Files** FileSystem + AccessPoint + IAM role over the bucket from 4a — provisioned via OpenTofu (`opentofu/llm-platform/`) until Upbound `provider-upjet-aws` v2.6+ ships native CRDs (per ADR-0004). Outputs propagate to `eks-environment` Crossplane EnvironmentConfig. Adds the `s3-files-csi-driver` HelmRelease under `infrastructure/base/`. | 4a-storage-base | TBD | ⏸ pending |
| 5-fleet-routing      | Four `XInferenceService` claims (Phi-4 Mini, Qwen3-8B, DeepSeek-R1-Distill-Qwen3-8B, LlamaGuard 3-1B) + Semantic Router config + Tailscale HTTPRoute. Each claim references the S3 Files-backed PVC for `/models`. | 3-composition, 4b-s3-files | TBD | ⏸ pending |
| 6-ui                 | OpenWebUI via existing `App` XR + ExternalSecret + HTTPRoute + CiliumNetworkPolicy | 5-fleet-routing | TBD | ⏸ pending |
| 7-eval-guardrails-cost | Promptfoo CronJob + LlamaGuard post-filter integration + Grafana dashboards (overview, routing, cost) + VMRules (SLO + cost) | 5-fleet-routing | TBD | ⏸ pending |

> Per PHASED.md §"GitHub issues": one issue per phase, labelled `phase:<N-name>`, all `Depends on` the parent spec issue. Parent stays open until all phase PRs merge.

---

## Design

### 1. API / Interface — `XInferenceService`

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: XInferenceService
metadata:
  name: xplane-qwen3-8b
  namespace: llm-platform
spec:
  # Model identity (required)
  model:
    repository: Qwen/Qwen3-8B            # HF model ID
    revision: main                       # commit / tag for reproducibility
    quantization: fp8                    # fp16 | fp8 | awq | gptq
    contextWindow: 32768

  # GPU resources (required)
  gpu:
    count: 1                             # nvidia.com/gpu request
    minVRAM: 16Gi                        # used to constrain Karpenter instance choice

  # Routing metadata (consumed by Semantic Router config)
  routing:
    tier: medium                         # small | medium | large
    specialty: general                   # general | code | math | guardrail | multilingual

  # Scaling (KEDA + Karpenter)
  scaling:
    minReplicas: 0                       # 0 → KEDA scale-to-zero enabled
    maxReplicas: 3
    scaleToZeroIdleSeconds: 600
    scaleUpQueueDepthThreshold: 4        # vllm:num_requests_waiting

  # Cache (LMCache)
  cache:
    kvOffload:
      enabled: true                      # CPU spillover for long contexts
    prefixCache:
      enabled: true                      # Persist common prefixes

  # Networking — reuses existing Tailscale Gateway
  route:
    enabled: false                       # Per-model HTTPRoute usually unnecessary;
                                         # the Semantic Router exposes the public-facing route
    parentGateway: platform-tailscale-general
    namespace: infrastructure
    hostname: ""                         # only used when enabled

  # Storage — S3 Files-backed PVC (per ADR-0004)
  weightsFileSystem:
    name: llm-models-fs                   # logical name; resolves to the S3 Files
                                          # FileSystem provisioned by Phase 4b
                                          # (env config exposes its ID + DNS)
    prefix: ""                            # default = full-bucket scope; per-model
                                          # AccessPoint can scope further

  # Optional secrets
  externalSecrets:
    huggingfaceToken:
      remoteRef: /platform/llm/hf_token  # AWS Secrets Manager path
```

### 2. Resources rendered per `XInferenceService` claim

| Resource | Condition | Notes |
|----------|-----------|-------|
| `Deployment` (vLLM container) | Always | `nvidia.com/gpu` request + GPU toleration; mounts the S3 Files PVC at `/models` (no init-container, no local copy — see ADR-0004) |
| `PersistentVolumeClaim` (S3 Files) | Always | Bound to a `StorageClass` provisioned by `s3-files-csi-driver`; resolves to `weightsFileSystem.name` from Phase 4b |
| `Service` (ClusterIP) | Always | Internal port 8000 (vLLM OpenAI server) |
| `KEDA ScaledObject` | When `scaling.minReplicas == 0` | Triggers: HTTP request rate + `vllm:num_requests_waiting` Prometheus query |
| `HorizontalPodAutoscaler` | When `scaling.minReplicas > 0` | CPU-based fallback to keep behavior consistent with `App` XR |
| `HTTPRoute` | When `route.enabled` | Otherwise traffic is reached only via Semantic Router |
| `VMServiceScrape` | Always | Scrapes `:8000/metrics` (vLLM Prometheus exposition) |
| `CiliumNetworkPolicy` | Always | Default-deny + explicit allow: ingress from `vllm-semantic-router` / `promptfoo`; egress: kube-dns (with `rules.dns: matchPattern '*'` for L7 inspection), S3 Files mount target, AWS Secrets Manager (`*.secretsmanager.eu-west-3.amazonaws.com`), `169.254.170.23/32:80` (EKS Pod Identity Agent), `huggingface.co` API only when preload runs (no Xet CDN — weights live in S3 Files) |
| `EPI` (composite) | When `weightsFileSystem` set | Scoped read on the S3 Files FileSystem (replaces the `s3:GetObject` scope from the pre-ADR-0004 design). No bucket-level S3 IAM needed at the per-claim level — bucket access flows through the FileSystem role. |
| `ExternalSecret` | When `externalSecrets.*` present | One per declared secret, refresh interval 1h (matches cert-manager pattern) |
| `VMRule` | Always | Per-model SLO alerts: queue-depth, error-rate, cold-start budget |
| `Job` (preload) | When `model.preload.enabled` and `weightsFileSystem` set | One-shot per `<repo>+<revision>`. Mounts the same S3 Files PVC; `hf download` writes directly to `/mnt/<repo>/<revision>/`. No `aws s3 sync`. No emptyDir. |

### 3. Cross-phase resources (Semantic Router, KEDA, vLLM PS, OpenWebUI, Promptfoo)

| Resource | Phase | Notes |
|----------|-------|-------|
| `karpenter.sh/v1.NodePool` `gpu-l4` | 1-gpu-foundation | Spot-first, `nvidia.com/gpu` taint, hard cap (CL-6) |
| `karpenter.k8s.aws/v1.EC2NodeClass` `gpu-l4` | 1-gpu-foundation | Bottlerocket Accelerated AMI, EBS snapshot ID parameter |
| `helm.toolkit.fluxcd.io/v2.HelmRelease` `keda` | 2-inference-stack | KEDA core; HTTP add-on; CRDs in `crds/base/keda/` |
| `HelmRelease` `vllm-production-stack` | 2-inference-stack | Router + LMCache subchart; KEDA-aware values |
| `HelmRelease` `vllm-semantic-router` | 2-inference-stack | OCI chart `ghcr.io/vllm-project/charts/semantic-router`; Iris MoM models pulled at boot |
| `crossplane.io/v1.CompositeResourceDefinition` `xinferenceservices` | 3-composition | KCL-rendered |
| `Bucket` (S3) `xplane-llm-models` | 4-storage | Created via `App` XR `s3Bucket.enabled` |
| `EPI` `xplane-llm-models-s3-read` | 4-storage | KCL composition output |
| `Job` `model-preload-<model>-<rev>` | 4-storage / 5-fleet-routing | One-shot per model+revision per CL-3 trigger choice |
| `XInferenceService` claims (×4) | 5-fleet-routing | Phi-4 Mini, Qwen3-8B, DeepSeek-R1-Distill-Qwen3-8B, LlamaGuard 3-1B |
| `ConfigMap` `vllm-semantic-router-config` | 5-fleet-routing | Routing rules; classifier signal weights; jailbreak/PII plugin config |
| `HTTPRoute` `llm-router` | 5-fleet-routing | parentRef `platform-tailscale-general`; hostname `llm.priv.cloud.ogenki.io` |
| `App` XR claim `openwebui` | 6-ui | Reuses existing composition; HTTPRoute `chat.priv.cloud.ogenki.io` |
| `CronJob` `promptfoo-eval` | 7-eval-guardrails-cost | Tooling namespace; emits Prometheus metrics via pushgateway-style sidecar |
| `GrafanaDashboard` (×3) | 7-eval-guardrails-cost | `llm-platform-overview`, `llm-routing`, `llm-platform-cost` |
| `VMRule` `llm-platform-slo` | 7-eval-guardrails-cost | Cold-start budget, error rate, dollar threshold |

### 4. Key Entities

- **`XInferenceService`** — composite resource (XR) for one self-hosted model. Naming: `xplane-<model-slug>` in namespace `llm-platform`.
- **`gpu-l4` NodePool** — Karpenter NodePool restricted to G6 family, NVIDIA L4 GPUs, spot+on-demand. Hard cap per CL-6.
- **`xplane-llm-models`** — single S3 bucket for all model weights, one prefix per model+revision.
- **`xplane-llm-models-s3-read`** — one EPI (IAM Role + Pod Identity Association) shared by all `XInferenceService` pods, scoped read-only.

### 5. Dependencies

- [x] Karpenter installed and reconciling (existing)
- [x] Crossplane core + AWS provider installed (existing)
- [x] Cilium Gateway API + Tailscale GatewayClass available (existing — `infrastructure/base/gapi/`)
- [x] VictoriaMetrics-k8s-stack with `VMServiceScrape` + `VMRule` CRDs (existing)
- [x] External Secrets Operator + AWS Secrets Manager backend (existing)
- [x] EPI XRD installed (existing — `eks-pod-identity`)
- [x] App XRD installed (existing) for OpenWebUI claim
- [ ] KEDA installed (Phase 2 work)
- [ ] vLLM Production Stack chart deployed (Phase 2 work)
- [ ] vLLM Semantic Router chart deployed (Phase 2 work)
- [ ] HF token populated in AWS Secrets Manager at `/platform/llm/hf_token` (manual prerequisite — assigned to Smana)
- [ ] EBS snapshot of warmup AMI built (Phase 1 last step)

### 6. Alternatives considered

KServe v0.16 `LLMInferenceService` + llm-d Endpoint Picker was the leading alternative. It has best-in-class prefix-cache-aware routing (~57× P90 TTFT improvement per Red Hat 2026-04 article) and is the SOTA architecture. Rejected for v1 because: (a) Knative dependency in KServe Serverless mode adds a major control plane; (b) at four models and internal-only scale, llm-d's value proposition (multi-tenant fairness, multi-cluster federation) is unrealised; (c) double-Envoy stack (Cilium Envoy + Inference Gateway Envoy) increases operational surface. Migration path is clean: vLLM PS routing keys + LMCache prefix pool are the same primitives llm-d uses. Captured in ADR-0003 (proposed under this spec).

---

## Implementation Notes

- **CL-1 (cascade vs hard route)** — once decided, the Semantic Router config in Phase 5 either enables or omits the `cascade-fallback` plugin chain.
- **CL-2 (LlamaGuard placement)** — drives whether Phase 7 wires LlamaGuard as pre-filter (router-side), post-filter (vLLM PS response middleware), or both.
- **CL-3 (preload trigger)** — drives whether the `model-preload` Job is rendered automatically by the `XInferenceService` composition (Phase 3) or stays as a hand-applied manifest under `apps/base/llm-platform/preload/`.
- **CL-4 (eval cadence)** — affects only the Promptfoo CronJob schedule field in Phase 7.
- **CL-5 (extend `App` with `gpu`)** — explicitly out of scope for this spec; we keep `App` CPU-only and route all GPU through `XInferenceService`. If reversed later, Phase 3 composition stays unchanged.
- **CL-6 (NodePool capacity ceiling)** — drives the `limits` block of the Phase 1 NodePool YAML; default proposal: `nvidia.com/gpu: 4` (one of each model warm + one spare). Constitution mandates resource limits — applies to NodePools too.

### File structure (composition, Phase 3)

```
infrastructure/base/crossplane/configuration/kcl/inference-service/
├── main.k                          # KCL composition logic
├── main_test.k                     # Resource-count, naming, security-context, readiness tests
├── kcl.mod                         # KCL module manifest
├── inference-service-definition.yaml  # XRD
├── composition.yaml                # Composition wrapping function-kcl
├── settings-example.yaml           # Minimal claim → renders ≥6 resources
├── examples/
│   ├── basic-claim.yaml            # smallest viable model (Phi-4 Mini)
│   └── full-claim.yaml             # all features on (KEDA + EPI + secrets + VMRule)
└── README.md                       # purpose, API, examples, CL references
```

### Validation path (per phase, run before merging that phase's PR)

- `kcl fmt` passes (CI-enforced)
- `kcl run -Y settings-example.yaml` renders without error
- `crossplane render` against the example claim succeeds
- Polaris score ≥ 85
- kube-linter passes
- `./scripts/validate-kcl-compositions.sh inference-service` exits 0
- `./scripts/validate-spec.sh docs/specs/NNN-self-hosted-llm-platform/` exits 0
- `kubeconform -summary -output json <rendered>.yaml` exits 0

---

## Tasks

> Each task has a stable ID (`T001`, `T002`, …) — committable unit, referenced by PRs and `/verify-spec`. Before marking `[x]`, cite fresh evidence (see [`.claude/rules/process.md`](../../../.claude/rules/process.md)).

### Phase 1 — GPU Foundation

- [ ] **T001**: Add `infrastructure/base/karpenter-nodepools/gpu-l4-ec2nodeclass.yaml` — Bottlerocket Accelerated AMI alias, EBS snapshot ID parameter (left as `snap-PLACEHOLDER` until T004 builds it), security groups via existing selector. Covers FR-005, FR-006.
- [ ] **T002**: Add `infrastructure/base/karpenter-nodepools/gpu-l4-nodepool.yaml` — `karpenter.k8s.aws/instance-family In [g6]`, `karpenter.sh/capacity-type In [spot, on-demand]`, taints `nvidia.com/gpu=true:NoSchedule`, hard cap per CL-6. Covers FR-005, FR-006.
- [ ] **T003**: Wire NodePool + EC2NodeClass into Flux Kustomization in `flux/clusters/mycluster-0/karpenter-nodepools-kustomization.yaml`. Validates SC-001.
- [ ] **T004**: Build initial EBS snapshot of GPU node disk with vLLM image cache (one-shot script under `scripts/build-gpu-snapshot.sh`); update T001 EC2NodeClass with real snapshot ID; commit.
- [ ] **T005**: Smoke test: `kubectl run gpu-smoke --rm -it ... -- nvidia-smi` returns within 90s. Verifies SC-001.

### Phase 2 — Inference Stack Install

- [ ] **T006**: Add KEDA CRDs under `crds/base/keda/`. Add `infrastructure/base/keda/helmrelease.yaml` with HTTP add-on enabled. Verify `flux get hr keda -n flux-system`.
- [ ] **T007**: Add `infrastructure/base/vllm-production-stack/helmrelease.yaml` with `oci://docker.io/lmcache/vllm-production-stack` chart (or equivalent). Default values: zero replicas, KEDA scaler bound. Covers FR-007.
- [ ] **T008**: Add `infrastructure/base/vllm-semantic-router/helmrelease.yaml` with `oci://ghcr.io/vllm-project/charts/semantic-router`. Default config: classifier-only, no cascade (cascade enabled in T024). Covers FR-002.
- [ ] **T009**: Add `VMServiceScrape` for Semantic Router under `observability/base/victoria-metrics-k8s-stack/vmservicecrapes/vllm-semantic-router.yaml`. Covers FR-007.
- [ ] **T010**: Add Flux Kustomizations for the three HelmReleases with explicit `dependsOn` order: KEDA → vLLM PS → Semantic Router.

### Phase 3 — `XInferenceService` Composition (KCL)

- [ ] **T011**: Scaffold `infrastructure/base/crossplane/configuration/kcl/inference-service/` directory (`kcl.mod`, `main.k`, `inference-service-definition.yaml`, `composition.yaml`, `settings-example.yaml`, `README.md`, `examples/basic-claim.yaml`, `examples/full-claim.yaml`). Covers FR-004.
- [ ] **T012**: Implement XRD with the schema shown in `## Design § 1` (KCL types matching `App`'s style — strings, ints, enums for `quantization`, `tier`, `specialty`). Covers FR-004.
- [ ] **T013**: Implement `main.k` composition logic — render Deployment, Service, KEDA ScaledObject (when `minReplicas==0`), HTTPRoute (when `route.enabled`), VMServiceScrape, CiliumNetworkPolicy (default-deny + explicit allow), EPI (when `weightsBucket` set), ExternalSecret(s), VMRule. Use `option("params").ocds` for readiness. Apply `_setResourceRequirements()` pattern from `app/main.k`. Covers FR-004, FR-007, FR-009, FR-011, FR-012.
- [ ] **T014**: Write `main_test.k` — minimal claim renders ≥6 resources; full claim renders ≥10; `xplane-*` prefix on every named resource; security context (runAsNonRoot, readOnlyRootFilesystem, drop ALL caps); resource limits set; CiliumNetworkPolicy is default-deny + explicit allow only. Verifies SC-009.
- [ ] **T015**: Run `./scripts/validate-kcl-compositions.sh inference-service` — must exit 0 (kcl fmt + kcl run + crossplane render + Polaris ≥ 85 + kube-linter). Verifies SC-009.
- [ ] **T016**: Write `README.md` (purpose, API table, examples, CL-N cross-references) and complete `examples/`.

### Phase 4a — Storage base (S3 bucket + per-claim IAM)

- [ ] **T017**: Add `apps/base/ai/s3-bucket.yaml` — direct Crossplane `Bucket` + `BucketVersioning` + `BucketPublicAccessBlock` resources (NOT the `App` XR's `s3Bucket.enabled` — that always renders a Deployment). Region `eu-west-3`, external-name `eu-west-3-ogenki-llm-models`, versioning on, no public access. All three resources need `metadata.namespace: ai` (Crossplane v2 namespaced — see [[crossplane-v2-managed-resources]]). Add `bucketpublicaccessblocks.s3.aws.m.upbound.io` to `infrastructure/base/crossplane/providers/activation-policy.yaml`. Covers FR-011.
- [ ] **T018**: Add `security/base/epis/llm-models-preload.yaml` — shared writable EPI XR `xplane-llm-models-preload` for the preload Job (one-shot, can write to S3 Files mount via the FileSystem role). Per-claim **read** EPIs are rendered by the InferenceService composition in Phase 3 (`xplane-<model>-fs-read`, scoped to the S3 Files FileSystem ARN). Covers FR-011, FR-012.

### Phase 4b — S3 Files (per ADR-0004)

> **Status of Crossplane support**: Upbound `provider-upjet-aws@v2.5.0` does NOT yet ship S3 Files CRDs (verified 2026-05-01). Terraform AWS provider has the resource (`aws_s3files_file_system`), so Upbound auto-generation will likely land in v2.6+. **Interim provisioning via OpenTofu**, native Crossplane CRDs adopted on Upbound release.

- [ ] **T019**: Create `opentofu/llm-platform/` stack with:
  - `aws_s3files_file_system.llm_models` — name `llm-models-fs`, bucket reference to `xplane-llm-models`, IAM role for S3 access (created in same stack).
  - `aws_s3files_access_point` (optional, one shared by default; per-model only if FR-009 requires per-model PII isolation later).
  - IAM role `xplane-llm-models-fs-access` — trust policy allows the EKS Pod Identity Agent; permission policy allows S3 read on the underlying bucket through the FileSystem.
  - Outputs: `llm_models_fs_id`, `llm_models_fs_dns_name`, `llm_models_fs_role_arn`.
  - Wire into Terramate workflow consistent with existing `opentofu/eks/configure/`.
- [ ] **T020a**: Update `clusters/mycluster-0/environment-config.yaml` — fold the OpenTofu outputs into the existing `eks-environment` Crossplane EnvironmentConfig under the `llm` key, alongside `clusterName`/`region`. The InferenceService composition reads via `option("params").ctx["apiextensions.crossplane.io/environment"].llm.fsId`.
- [ ] **T020b**: Install `s3-files-csi-driver` (or the AWS-published equivalent — TBD on package name; `efs-csi-driver` extension is one possibility). HelmRelease under `infrastructure/base/s3-files-csi/`. Wire into Flux dependency chain after `crossplane-providers` and before `karpenter-nodepools`.
- [ ] **T020c**: Add a `StorageClass` `s3-files-llm-models` referencing the FileSystem ID; provisioner field per CSI driver docs. Add a sample `PersistentVolumeClaim` test mounting a tiny pod that `ls`s the bucket — verifies CSI install before Phase 5 claims hit the path.
- [ ] **T020d**: Update preload Job template (rendered by Phase 3 composition) — drop the `tmp` emptyDir, mount the S3 Files PVC at `/models`. Command becomes `hf download <repo> --revision <rev> --local-dir /models/<repo>/<revision>/`. No `aws s3 sync` step. Covers FR-011.
- [ ] **T020e**: Verify per-claim IAM role scope (post-Phase-3 + 4b deploy): `aws iam simulate-principal-policy --policy-source-arn $(aws iam get-role --role-name xplane-phi4-mini-fs-read --query 'Role.Arn' --output text) --action-names s3files:Read s3files:Write --resource-arns <FileSystem ARN>` — read allowed, write denied. Verifies SC-011 against the ADR-0004 IAM model.
- [ ] **T020f**: Migration plan documentation — once Upbound `provider-upjet-aws` v2.6+ publishes `FileSystem.s3files.aws.m.upbound.io`, replace the OpenTofu resources with native Crossplane MRs. Composition consumer side stays unchanged (still reads FS ID from EnvironmentConfig).

### Phase 5 — Model Fleet & Cascade Routing

- [ ] **T021**: Add `apps/base/llm-platform/phi4-mini.yaml` — `XInferenceService` claim, `tier: small`, `specialty: general`, `gpu.count: 1`, `quantization: fp8`. Covers FR-003.
- [ ] **T022**: Add `apps/base/llm-platform/qwen3-8b.yaml` — `tier: medium`, `specialty: general`. Covers FR-003.
- [ ] **T023**: Add `apps/base/llm-platform/deepseek-r1-distill-qwen3-8b.yaml` — `tier: large`, `specialty: code`. Covers FR-003.
- [ ] **T024**: Add `apps/base/llm-platform/llamaguard3-1b.yaml` — `tier: small`, `specialty: guardrail`. Covers FR-003, FR-009.
- [ ] **T025**: Generate `vllm-semantic-router` ConfigMap with classifier rules (domain → specialty mapping), jailbreak + PII plugins enabled, cascade settings per CL-1. Per CL-2, configure LlamaGuard placement (pre / post / both). Covers FR-002, FR-009.
- [ ] **T026**: Add `apps/base/llm-platform/httproute-router.yaml` — HTTPRoute, `parentRefs: platform-tailscale-general`, hostname `llm.priv.cloud.ogenki.io`, backendRefs to Semantic Router service. Covers FR-001.
- [ ] **T027**: E2E routing test: `curl -fsS https://llm.priv.cloud.ogenki.io/v1/chat/completions -d '{"model":"auto","messages":[{"role":"user","content":"Write Rust to parse CIDR"}]}' | jq .model` returns `deepseek-r1-distill-qwen3-8b`. Verifies SC-003.
- [ ] **T028**: Latency SLO check: 1-hour load (≥100 req/min), histogram bucket `vllm_semantic_router_latency_seconds_bucket{le="0.2"}` ≥ 95%. Verifies SC-004.
- [ ] **T029**: Jailbreak block test: 10-pattern set blocked with 0 false negatives via `vllm_semantic_router_blocked_total{reason="jailbreak"}`. Verifies SC-005.
- [ ] **T030**: Scale-to-zero verification: 600s idle → 0 pods → 0 GPU nodes within 60s extra. Verifies SC-002.

### Phase 6 — UI

- [ ] **T031**: Add `apps/base/openwebui/openwebui-claim.yaml` — `App` XR with image `ghcr.io/open-webui/open-webui`, `route.enabled: true`, `route.hostname: chat.priv.cloud.ogenki.io`, `externalSecrets` for admin creds. Covers FR-010.
- [ ] **T032**: Configure OpenWebUI environment to point at `https://llm.priv.cloud.ogenki.io/v1` as OpenAI-compatible endpoint. Covers FR-010.
- [ ] **T033**: Add CiliumNetworkPolicy: OpenWebUI egress allowed to Semantic Router service only. Already enforced by `App` XR `networkPolicies` field.
- [ ] **T034**: Manual UAT: browse to `chat.priv.cloud.ogenki.io`, log in, complete a streaming chat, verify routing model in response. Verifies US-1 acceptance scenarios.

### Phase 7 — Eval, Guardrails, Cost

- [ ] **T035**: Add `tooling/base/promptfoo/cronjob.yaml` — CronJob, schedule per CL-4, image `ghcr.io/promptfoo/promptfoo`, ConfigMap-mounted eval suite (`tooling/base/promptfoo/eval-suite.yaml`) with ≥50 prompts across general / code / guardrail. Covers FR-008.
- [ ] **T036**: Add Prometheus metrics exporter sidecar (or Promptfoo's built-in Prom output) — emit `promptfoo_test_pass_rate{category}`, `promptfoo_test_duration_seconds`. Add `VMServiceScrape`. Covers FR-008.
- [ ] **T037**: Wire LlamaGuard 3-1B post-filter into Semantic Router per CL-2 decision. Verify ToxiGen sample precision ≥ 0.95. Verifies SC-006.
- [ ] **T038**: Add Grafana dashboards as `GrafanaDashboard` CRDs under `observability/base/grafana-dashboards/`: `llm-platform-overview` (per-model QPS, latency, queue depth, GPU util), `llm-routing` (per-tier decision counts, blocked counts, cascade hit rate), `llm-platform-cost` (`$/hour`, `$/1M tokens`). Covers FR-013.
- [ ] **T039**: Add VMRules under `observability/base/victoria-metrics-k8s-stack/vmrules/llm-platform.yaml`: cold-start exceeds 90s budget; per-model error rate > 5% over 10m; cost per hour exceeds threshold; Promptfoo regression alert (per SC-008).
- [ ] **T040**: Regression injection test: temporarily mis-route 20% of code prompts to Phi-4 Mini, observe `VMRule: LLMRoutingQualityDegraded` fire within 1h. Verifies SC-008.
- [ ] **T041**: Cost panel cross-check: `dollars_per_million_tokens` Grafana cell vs manual calculation, within 5%. Verifies SC-012.

### Cross-cutting (any phase)

- [ ] **T042**: Add `docs/decisions/0003-vllm-production-stack-over-kserve.md` ADR. Capture rejected alternatives (KServe + llm-d, NIM, Ray Serve), decision criteria, migration path.
- [ ] **T043**: Update `CLAUDE.md` with a one-paragraph pointer to this spec under "Common Commands" — how to query the LLM endpoint and how to deploy a new model.
- [ ] **T044**: Run `./scripts/validate-spec.sh docs/specs/NNN-self-hosted-llm-platform/` after each phase merge — must exit 0. Verifies SC-010.

### Deviations from plan

<!-- Append as implementation surprises show up. Format:
- <date> T00N was [dropped|replaced|split]: <why>
Keep short — detailed rationale goes in clarifications.md if it is a decision. -->

---

## Review Checklist

Complete this before implementation begins. Each persona enforces non-negotiable rules — do not skip.

### Project Manager

- [x] Problem statement in spec.md is clear and specific
- [x] User stories capture real user needs (US-1..US-5 cover end users, platform engineers, SRE, quality engineer, platform owner)
- [x] Acceptance scenarios are testable (each US has Given/When/Then)
- [x] Scope is well-defined (goals AND non-goals — Non-Goals section in spec.md)
- [x] Success criteria are measurable (SC-001..SC-012, all with concrete commands or metrics)

### Platform Engineer

- [x] Design follows existing patterns (`App`, `SQLInstance`, `EPI` as references — `XInferenceService` mirrors `App`'s progressive complexity model)
- [x] API is consistent with other compositions (XRD style matches `App`/`SQLInstance` — typed enums, `route.enabled` flag, `externalSecrets` block)
- [x] Resource naming follows `xplane-*` convention (FR-012)
- [x] KCL avoids mutation pattern (function-kcl #285) — design uses inline conditionals only (verified at T013)
- [x] Examples provided (basic + complete in `examples/`)

### Security & Compliance

- [x] Zero-trust networking (CiliumNetworkPolicy defined — default-deny + explicit allow per FR-009 + T013)
- [x] Least-privilege RBAC (model pods run as ServiceAccount with no cluster RBAC)
- [x] Secrets via External Secrets (no hardcoded credentials — FR-011, ExternalSecret pattern)
- [x] Security context enforced (non-root, read-only FS where possible — verified at T014)
- [x] IAM policies scoped to `xplane-*` resources (FR-012 + T020 SC-011 verifies via `aws iam simulate-principal-policy`)

### SRE

- [x] Health checks defined (vLLM `/health` liveness + readiness; budget 90s cold start per FR-005)
- [x] Observability configured (metrics → VictoriaMetrics via VMServiceScrape T013; logs → VictoriaLogs via stdout JSON; FR-007 + T009)
- [x] Resource requests + limits appropriate (constitution-mandated; `_setResourceRequirements` pattern reused from `app/main.k` per T013)
- [x] Failure modes documented (Spot interruption → Karpenter drains; KV cache OOM → KEDA scales up; cold-start budget overrun → VMRule alert per T039)
- [x] Recovery / rollback path clear (each phase has independent rollback: delete the new manifests; weights remain in S3 by EPI scope retention; no destructive IAM ops per ADR-0002)

---

## References

- Spec: [spec.md](spec.md)
- Clarifications log: [clarifications.md](clarifications.md)
- Constitution: [docs/specs/constitution.md](../constitution.md)
- Phased specs: [docs/specs/PHASED.md](../PHASED.md)
- Similar composition (template): [`infrastructure/base/crossplane/configuration/kcl/app/`](../../../infrastructure/base/crossplane/configuration/kcl/app/)
- Process rules (verification + debugging): [`.claude/rules/process.md`](../../../.claude/rules/process.md)
- KCL Crossplane rules: [`.claude/rules/kcl-crossplane.md`](../../../.claude/rules/kcl-crossplane.md)
- ADR-0001: [Use KCL for Crossplane Compositions](../../decisions/0001-use-kcl-for-crossplane-compositions.md)
- ADR-0002: [Use EKS Pod Identity over IRSA](../../decisions/0002-eks-pod-identity-over-irsa.md)
- ADR-0003 (proposed): vLLM Production Stack over KServe + llm-d for v1 (T042)
