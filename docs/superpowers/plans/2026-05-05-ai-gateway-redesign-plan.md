# AI Gateway Redesign — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the CEC + cilium-envoy + custom Go proxy stack with **Envoy AI Gateway + InferencePool + EPP** on a dedicated Envoy data plane. Originally phased with the `llm-router-proxy` retained as a safety net until P5 demolition; **mid-flight reframe (user call, 2026-05-05)** dropped the proxy + CEC in the same PR — solo experimental scope made the rollback insurance unnecessary, and the blog post deliverable favors the cleaner state.

**Source design:** [`2026-05-05-ai-gateway-redesign-design.md`](./2026-05-05-ai-gateway-redesign-design.md) (commit `060c02e8`).

**Commit conventions:** Use Smana / smainklh@gmail.com (configured for the repo). Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`). **Never** add `Co-Authored-By:` lines or "Generated with Claude" attribution — `CLAUDE.md` forbids it.

---

## Pre-conditions

- Branch `wip/self-hosted-llm-platform-draft` checked out. Verify: `git -C ~/Sources/cloud-native-ref branch --show-current`.
- Cluster `mycluster-0` reachable. Verify: `kubectl get nodes`.
- LLM platform fully deployed (Phase 5 of llm-platform initiative, all 5 InferenceService XRs Ready). Verify: `kubectl get inferenceservice.cloud.ogenki.io -n llm` → all `Synced=True Ready=True`.
- SR running. Verify: `kubectl get pods -n llm -l app.kubernetes.io/name=vllm-semantic-router | grep 1/1`.
- Existing `llm-router-proxy` deployed and healthy (the safety net). Verify: `kubectl get deploy llm-router-proxy -n llm` → Available.
- `mise install` complete; `kcl`, `kubeconform`, `flux`, `helm` available.

---

## File structure

```
flux/sources/                                  # add new OCIRepository sources
├── ocirepo-envoy-gateway.yaml                # P1: oci://docker.io/envoyproxy/gateway-helm
├── ocirepo-envoy-ai-gateway-crds.yaml        # P1: oci://docker.io/envoyproxy/ai-gateway-crds-helm
└── ocirepo-envoy-ai-gateway.yaml             # P1: oci://docker.io/envoyproxy/ai-gateway-helm

infrastructure/base/envoy-gateway/             # new — Envoy Gateway prerequisite
├── helmrelease.yaml                          # P1: Envoy Gateway controller (envoy-gateway-system ns)
├── network-policy.yaml                       # P1: CNP
└── kustomization.yaml

infrastructure/base/envoy-ai-gateway/          # new — AI Gateway controller + Gateway resource
├── helmrelease-crds.yaml                     # P1: AI Gateway CRDs chart (envoy-ai-gateway-system ns)
├── helmrelease.yaml                          # P1: AI Gateway controller (envoy-ai-gateway-system ns)
├── gateway.yaml                              # P1: Gateway resource w/ gatewayClassName: envoy-gateway
├── network-policy.yaml                       # P1: CNP
└── kustomization.yaml

infrastructure/base/vllm-semantic-router/
└── extension-policy.yaml                     # P2: EnvoyExtensionPolicy injecting SR ext_proc

apps/base/ai/llm/ai-gateway-routes/           # new — per-model AIGatewayRoute + AIServiceBackend + Backend
├── qwen3-8b.yaml                             # P1 (single route initially), P3 (full set)
├── qwen-coder.yaml                           # P3
├── qwen-coder-fim.yaml                       # P3
├── phi4-mini.yaml                            # P3
├── llamaguard3-1b.yaml                       # P3
├── route.yaml                                # P1: single AIGatewayRoute aggregating all backends (per upstream pattern)
└── kustomization.yaml

infrastructure/base/crossplane/configuration/kcl/inference-service/
├── main.k                                    # P4: drop xplane-<model> Service; add InferencePool, EPP Deployment, EPP Service
├── main_test.k                               # P4: assert resource counts + labels
└── ...                                        # existing

# REMOVED in P5
infrastructure/base/llm-ai-gateway/           # delete entire directory
tooling/llm-router-proxy/                     # delete entire directory
.github/workflows/llm-router-proxy.yml        # delete file

# MODIFIED in P5
clusters/mycluster-0-llm-platform/README.md   # update to reflect new gateway
infrastructure/base/tailscale-gateway/        # repoint HTTPRoute backendRefs (exact path resolved in P5.1 via grep)
```

---

## Phase 1 — Smoke: dedicated Envoy + single route

**Goal:** Prove the Envoy AI Gateway controller + dedicated data plane works on this cluster, returns 200 for a single model route, and is reachable from in-cluster sources. **No SR, no InferencePool yet.** Result: kills the cilium-envoy L7-policy concern definitively.

**Architecture details (confirmed via context7 docs at /envoyproxy/ai-gateway):**
- Envoy Gateway is a **prerequisite** — provides the GatewayClass `envoy-gateway` and the data-plane controller. Coexists with Cilium's GatewayClass (`cilium`, `cilium-tailscale`).
- AI Gateway ships as **two charts** at v0.5.0: `ai-gateway-crds-helm` (CRDs only) + `ai-gateway-helm` (controller). Default namespace: `envoy-ai-gateway-system`.
- AIGatewayRoute matches on header `x-ai-eg-model` (single word). The AI Gateway controller's built-in body parser sets this header from `body.model` automatically.
- AIServiceBackend's `backendRef` points at an Envoy Gateway `Backend` CRD (`gateway.envoyproxy.io/v1alpha1`), NOT a vanilla `Service`. The Backend wraps an FQDN endpoint; for in-cluster Services use `<service>.<ns>.svc.cluster.local:<port>`.

**Mergeable independently?** Yes. Cluster keeps the old proxy for real traffic; this new path is reachable via its own Gateway.

### Task P1.1: Add OCIRepository sources

**Files:** `flux/sources/ocirepo-envoy-gateway.yaml`, `flux/sources/ocirepo-envoy-ai-gateway-crds.yaml`, `flux/sources/ocirepo-envoy-ai-gateway.yaml` (all new).

- [ ] **Step 1: Author 3 OCIRepositories** following the existing pattern in `flux/sources/ocirepo-vllm-semantic-router.yaml`:
  - `envoy-gateway`: `oci://docker.io/envoyproxy/gateway-helm`, pin to a known-good v1.x tag (verify latest at `https://github.com/envoyproxy/gateway/releases`).
  - `envoy-ai-gateway-crds`: `oci://docker.io/envoyproxy/ai-gateway-crds-helm`, tag `v0.5.0`.
  - `envoy-ai-gateway`: `oci://docker.io/envoyproxy/ai-gateway-helm`, tag `v0.5.0` (must match CRDs version).
  - All three in namespace `flux-system` (matching repo convention — sources live there for cross-namespace HelmRelease references).
- [ ] **Step 2: Verify** the OCI tags are anonymously pullable: `crane ls docker.io/envoyproxy/ai-gateway-helm` (or skopeo equivalent).
- [ ] **Step 3: Validate** with `kubeconform -summary -strict flux/sources/ocirepo-envoy-*.yaml`. Expect 0 errors.

### Task P1.2: HelmRelease — Envoy AI Gateway controller

**Files:** `infrastructure/base/envoy-ai-gateway/helmrelease.yaml` (new), kustomization.yaml (modify).

- [ ] **Step 1: Author HelmRelease** for the AI Gateway controller. Values to set:
  - `replicaCount: 1` (controller, not data plane).
  - `securityContext`: restricted PSS — non-root, readOnlyRootFilesystem, allowPrivilegeEscalation: false, drop ALL caps, seccompProfile: RuntimeDefault.
  - `resources.requests/limits` modest (controller is light).
  - Logging level `info`.
- [ ] **Step 2: Confirm the chart's CRD strategy** — does it install CRDs as part of the chart, or expect them pre-installed via a separate `CustomResourceDefinition` set? If the latter, add a `crds/base/envoy-ai-gateway/` directory with the CRDs and wire it into the bootstrap dependency hierarchy (Namespaces → CRDs → … in CLAUDE.md).
- [ ] **Step 3: Add to kustomization.yaml** resources.
- [ ] **Step 4: Validate** with `kubeconform -summary -strict` and `helm template` (locally via `flux build kustomization` if practical).

### Task P1.3: Gateway resource + dedicated data plane

**Files:** `infrastructure/base/envoy-ai-gateway/gateway.yaml` (new), kustomization.yaml (modify).

- [ ] **Step 1: Author the `Gateway`** resource referencing the AI Gateway's `gatewayClassName` (chart-provided). Listener: HTTP on port 8080 with allowedRoutes from same namespace (or `apps/llm` namespace as needed).
- [ ] **Step 2: Verify the controller will spawn an Envoy data-plane Deployment** automatically when the Gateway is reconciled. (This is per the AI Gateway model — the Gateway resource triggers Deployment creation.)
- [ ] **Step 3: Add to kustomization.yaml**.

### Task P1.4: CiliumNetworkPolicy — controller + data plane

**Files:** `infrastructure/base/envoy-ai-gateway/network-policy.yaml` (new), kustomization.yaml (modify).

- [ ] **Step 1: Author CNP for the controller**: default-deny ingress, egress to kube-apiserver (TCP 443 to `kube-apiserver` entity), kube-dns (with rules.dns.matchPattern: "*" per `.claude/rules/cilium-network-policies.md` rule 1), and to Helm/OCI registry FQDNs as needed.
- [ ] **Step 2: Author CNP for the data plane**: default-deny ingress except from Tailscale gateway pods (label-based selector) and from same-namespace test sources for the smoke; egress to kube-dns, to xplane-qwen3-8b Service (cluster IP, namespace llm).
- [ ] **Step 3: Validate** with `kubeconform`.

### Task P1.5: AIGatewayRoute + AIServiceBackend (qwen3-8b only)

**Files:** `apps/base/ai/llm/ai-gateway-routes/qwen3-8b-route.yaml` (new), `apps/base/ai/llm/ai-gateway-routes/kustomization.yaml` (new).

- [ ] **Step 1: Author `AIGatewayRoute`** with rule matching `model: qwen3-8b` (or model-specific header — check chart docs) and backendRefs → `AIServiceBackend/qwen3-8b`.
- [ ] **Step 2: Author `AIServiceBackend`** with `backendRef → Service xplane-qwen3-8b` (port 8000, the vLLM container port).
- [ ] **Step 3: Add to kustomization.yaml** in `apps/base/ai/llm/ai-gateway-routes/`. Wire this kustomization in via `apps/base/ai/llm/kustomization.yaml`.

### Task P1.6: Wire the new kustomizations into the umbrella

**Files:** `clusters/mycluster-0-llm-platform/<files>` (existing — modify to include new infrastructure base).

- [ ] **Step 1: Identify the umbrella Kustomization manifest** that aggregates llm-platform children (`clusters/mycluster-0/llm-platform.yaml` references children in `clusters/mycluster-0-llm-platform/`).
- [ ] **Step 2: Add a child Kustomization** for `infrastructure/base/envoy-ai-gateway/`. Set dependencies: depends on the namespace + Crossplane base (constitution dependency hierarchy).
- [ ] **Step 3: Validate** the chain with `flux build kustomization llm-platform --path .`.

### Task P1.7: Deploy & smoke test

- [ ] **Step 1: Push branch** with new manifests; let Flux reconcile (or `flux reconcile kustomization llm-platform`).
- [ ] **Step 2: Verify controller is healthy**: `kubectl get pods -n <ai-gateway-ns> -l <controller-label>` → `Running 1/1`.
- [ ] **Step 3: Verify data plane spawned**: `kubectl get deploy -n <ns>` should show a new Envoy deployment created by the controller.
- [ ] **Step 4: Test from in-cluster** (a temporary `curlimages/curl` pod with NetworkPolicy bypass for the smoke):
  ```
  kubectl run -it --rm smoke --image=curlimages/curl -n llm --restart=Never -- \
    curl -sv -X POST http://<envoy-data-plane-svc>:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"qwen3-8b","messages":[{"role":"user","content":"hi"}],"max_tokens":4}'
  ```
- [ ] **Step 5: Expect HTTP 200 + a streamed completion**. If 403 or timeout: check Hubble (`hubble observe --pod llm/<envoy-pod> --verdict DROPPED --last 50`) + Envoy access logs. **This is the gate that says "dedicated Envoy ≠ cilium-envoy works".**

### Task P1.8: Commit P1

- [ ] `git add infrastructure/base/envoy-ai-gateway/ apps/base/ai/llm/ai-gateway-routes/ clusters/mycluster-0-llm-platform/`
- [ ] Commit message: `feat(ai-gateway): bootstrap Envoy AI Gateway controller + qwen3-8b smoke route`

**SC met by P1:** none yet (smoke only). **Phase gate:** in-cluster curl returns 200 from the new data plane.

---

## Phase 2 — SR wiring + filter ordering

**Goal:** Inject SR's ext_proc as a filter ahead of Envoy AI Gateway's body parser via `EnvoyExtensionPolicy`. Verify the **filter ordering claim from design §3** — that SR's body mutation propagates to the route. Smoke: `model:"MoM"` → SR classifies → Envoy routes to qwen3-8b backend.

**Mergeable independently?** Yes — keeps P1's explicit-model route working, adds the MoM virtual-model path on top.

### Task P2.1: EnvoyExtensionPolicy — inject SR ext_proc

**Files:** `infrastructure/base/vllm-semantic-router/extension-policy.yaml` (new), `infrastructure/base/vllm-semantic-router/kustomization.yaml` (modify).

- [ ] **Step 1: Look up `EnvoyExtensionPolicy` schema** for the AI Gateway version installed in P1 — exact `apiVersion`, `targetRef` shape, ext_proc fields.
- [ ] **Step 2: Author the EnvoyExtensionPolicy** referring to:
  - `targetRef → AIGatewayRoute/qwen3-8b-route` (single route for the smoke; expand in P3).
  - `extProc.backendRef → Service vllm-semantic-router` (gRPC port 50051).
  - `processingMode.requestBodyMode: BUFFERED`.
  - `messageTimeout: 10s`.
- [ ] **Step 3: Confirm filter ordering** — read the chart docs / `EnvoyExtensionPolicy` semantics: does an extension attached this way run *before* the AI Gateway's built-in body parser? (Source-of-truth design §3.) If unclear, deploy and observe the actual filter chain via `kubectl get cm -n <ns> envoy-config -o yaml` (the rendered Envoy bootstrap).
- [ ] **Step 4: Validate** with `kubeconform`.

### Task P2.2: SR side — confirm SR responds to ext_proc body callback

The SR (vllm-semantic-router v0.2.0) is already running and is wired to receive ext_proc requests. **Nothing to change on SR.** Verify:

- [ ] **Step 1: SR is reachable on port 50051** from the data plane: `kubectl exec -n llm <test-pod> -- nc -zv vllm-semantic-router.llm.svc 50051`.
- [ ] **Step 2: SR's CNP allows ingress** from the AI Gateway data plane label (extend `infrastructure/base/vllm-semantic-router/network-policy.yaml`).

### Task P2.3: Deploy & MoM smoke test

- [ ] **Step 1: Reconcile** the new EnvoyExtensionPolicy.
- [ ] **Step 2: Test from in-cluster**:
  ```
  kubectl run -it --rm smoke --image=curlimages/curl -n llm --restart=Never -- \
    curl -sv -X POST http://<envoy-data-plane-svc>:8080/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model":"MoM","messages":[{"role":"user","content":"write me a python fizzbuzz"}],"max_tokens":50}'
  ```
- [ ] **Step 3: Expect** HTTP 200 + response header `x-vsr-selected-model: <classified model>` + the actual classified model's vLLM logs show the request. If `x-vsr-selected-model` is missing → check whether AI Gateway strips unknown response headers; add `responseHeadersToAdd` allowlist on the route if needed.
- [ ] **Step 4: If filter ordering is wrong** (request hits the AI Gateway body parser BEFORE SR mutation): the symptom is `x-ai-eg-model: MoM` in Envoy access logs and a 4xx because no route matches MoM. **Fallback path:** add a Lua filter via `EnvoyPatchPolicy` or chart-supported `EnvoyExtensionPolicy.lua` that calls `request_handle:clearRouteCache()` after SR's ext_proc. ~10 lines of Lua. Document in design §3 risks if this fallback is taken.

### Task P2.4: Commit P2

- [ ] Commit message: `feat(ai-gateway): inject SR ext_proc ahead of body parser via EnvoyExtensionPolicy`

**SC met by P2:** SC-01 (MoM classification routing on smoke route), SC-03 (header-match works).

---

## Phase 3 — Full fleet routing (Service-backed)

**Goal:** AIGatewayRoute + AIServiceBackend per model for all 5 models, still pointing at `xplane-<model>` Services. Extend the EnvoyExtensionPolicy `targetRef` to cover all routes (or apply the policy at Gateway scope rather than per-Route).

**Mergeable independently?** Yes — adds 4 more routes; P2's smoke route remains.

### Task P3.1: Author 4 more AIGatewayRoute + AIServiceBackend manifests

**Files:** `apps/base/ai/llm/ai-gateway-routes/{qwen-coder,qwen-coder-fim,phi4-mini,llamaguard3-1b}-route.yaml` (new), kustomization.yaml (modify).

- [ ] **Step 1: For each model**, author route matching `model: <model-name>` → `AIServiceBackend/<model>` → `Service xplane-<model>:8000`.
- [ ] **Step 2: Add all to kustomization.yaml**.
- [ ] **Step 3: Validate** with `kubeconform`.

### Task P3.2: Expand EnvoyExtensionPolicy to all routes

**Files:** `infrastructure/base/vllm-semantic-router/extension-policy.yaml` (modify).

- [ ] **Option A:** keep per-route `targetRef` and add 4 more entries (or 4 more EnvoyExtensionPolicies).
- [ ] **Option B:** retarget the EnvoyExtensionPolicy at the `Gateway` resource so it covers all routes flowing through that Gateway. **Preferred** if chart supports it — single source of truth.

### Task P3.3: Smoke each model

- [ ] **Step 1: One curl per model** (5 in total) — verify HTTP 200, correct vLLM pod logs the request, correct `x-vsr-selected-model` for MoM-routed requests. *Note:* `phi4-mini` and `llamaguard3-1b` are `min=0` today (scale-to-zero with no working scale-up trigger), so direct curls against them surface as EPP `503 / no candidate pods` — that's expected. Either run those with prompts that trigger their decision via a warm peer, or skip them until the HTTP-queue scaler lands.
- [ ] **Step 2: Verify SR cascade decisions** route MoM correctly across the *warm* fleet (qwen-coder-fim, qwen-coder, qwen3-8b). Prompt mix: code question (→ qwen-coder), math/multilingual (→ qwen3-8b), short generic (→ qwen3-8b — was phi4-mini, remapped because phi4-mini stays scale-to-zero).

### Task P3.4: Commit P3

- [ ] Commit message: `feat(ai-gateway): full fleet routing — 5 AIGatewayRoutes + 5 backends`

**SC met by P3:** SC-01, SC-02, SC-03, SC-07. (SC-04, SC-05, SC-06 require P4–P5.)

---

## Phase 4 — InferencePool + EPP

**Goal:** Refactor the Crossplane `InferenceService` KCL composition to emit `InferencePool` + EPP `Deployment` + EPP `Service` per claim. Switch each `AIServiceBackend` from kind `Service` to kind `InferencePool`. Drop the `xplane-<model>` per-model Services. Drop the per-claim CNP overrides (folds task #76 into this phase).

**Mergeable independently?** Yes. The migration can be done one model at a time (per-`AIServiceBackend` swap).

### Task P4.1: Add inference-extension CRDs to the cluster

**Files:** `crds/base/inference-extension/` (new directory; or use `helm` if the EPP chart bundles them), `crds/base/kustomization.yaml` (modify).

- [ ] **Step 1: Pin the gateway-api-inference-extension version**. Record in `opentofu/config.tm.hcl` or a comment header on the CRD manifests.
- [ ] **Step 2: Apply CRDs** at the `crds/base/` layer per the constitution dependency hierarchy.

### Task P4.2: Modify InferenceService KCL composition

**Files:** `infrastructure/base/crossplane/configuration/kcl/inference-service/main.k` (modify), `main_test.k` (modify).

- [ ] **Step 1: Drop the `xplane-<model>` Service** generation. Add inline conditional or remove the resource block (KCL: never mutate post-creation, build a new resource list).
- [ ] **Step 2: Add `InferencePool` resource** with selector matching the Deployment's pod labels, `targetPortNumber: 8000`, `extensionRef → Service <claim>-epp`.
- [ ] **Step 3: Add EPP `Deployment`** — image `registry.k8s.io/gateway-api-inference-extension/epp:v<pinned>`, restricted PSS (non-root, RO root FS, drop ALL caps, seccompProfile: RuntimeDefault), 1 replica, modest resources, args/env to point at the InferencePool name.
- [ ] **Step 4: Add EPP `Service`** — ClusterIP, port 9002 (gRPC) targeting the EPP Deployment.
- [ ] **Step 5: Modify `CiliumNetworkPolicy`** at composition level — allow EPP → vLLM pods (TCP 8000, /metrics), allow AI Gateway data plane → EPP (TCP 9002), allow AI Gateway data plane → vLLM pods (TCP 8000). Drop the per-claim CNP override mechanism that task #76 was about.
- [ ] **Step 6: Decide PodMonitor vs headless Service for vLLM scraping** — implementation detail flagged in design §7. Quick lean: PodMonitor (fewer resources, pod-direct, simpler). Adjust ServiceMonitor accordingly.
- [ ] **Step 7: Run `kcl fmt`** before commit (CI is strict).
- [ ] **Step 8: Update `main_test.k`** — assert resource counts (InferencePool: 1, EPP Deployment: 1, EPP Service: 1, no xplane-<model> Service), correct labels, restricted PSS on EPP.
- [ ] **Step 9: Validate** with `./scripts/validate-kcl-compositions.sh` → exit 0.

### Task P4.3: Bump composition version + push

**Files:** `infrastructure/base/crossplane/configuration/kcl/inference-service/kcl.mod` (modify).

- [ ] **Step 1: Bump `version`** in `kcl.mod` per the kcl-crossplane.md rule 5 (the version field is what's actually published, not the OCI tag suffix).
- [ ] **Step 2: Push via the existing CI workflow** (`crossplane-modules.yml`) or trigger manually if needed.
- [ ] **Step 3: Update the composition's `Function.spec.package`** reference to the new version.
- [ ] **Step 4: Verify the new tag is anonymously pullable** before pointing the composition at it.

### Task P4.4: Switch each AIServiceBackend from Service → InferencePool

**Files:** `apps/base/ai/llm/ai-gateway-routes/*-route.yaml` (modify, all 5).

- [ ] **Step 1: For each route** change `backendRef.kind: Service` → `kind: InferencePool`, name: `<model>-pool` (or whatever name the composition emits).
- [ ] **Step 2: Apply per-model**, verify each smoke test still passes after each switch (rollback per model if needed).

### Task P4.5: Drop task #76's per-claim CNP overrides

**Files:** the 3 per-claim CNP overrides from task #76 — `phi4-mini`, `qwen3-8b`, `llamaguard3-1b` — now subsumed by composition-level CNP.

- [ ] **Step 1: Identify the CNP overrides** (`apps/base/ai/llm/<model>-network-policy.yaml` or similar — verify exact paths).
- [ ] **Step 2: Delete them**.
- [ ] **Step 3: Verify** the composition-level CNP covers everything they covered: `hubble observe --pod llm/<model>-pod --verdict DROPPED --last 50` shows no expected-traffic drops.

### Task P4.6: Commit P4

- [ ] Commit messages (split if useful):
  - `feat(crossplane): InferenceService composition emits InferencePool + EPP per claim`
  - `feat(ai-gateway): switch backendRefs from Service to InferencePool`
  - `chore(llm): drop per-claim CNP overrides (subsumed by composition)` (closes task #76)

**SC met by P4:** SC-04 (single-endpoint pool today, scales-ready), SC-06 (PSS on new pods), SC-07 (CNP coverage).

---

## Phase 5 — Demolition

**Goal:** Remove the legacy stack. Repoint Tailscale entry. Update docs. Close residual tasks.

**Mergeable independently?** Yes — final phase; only run after P4 has been verified for at least 24h on the cluster.

### Task P5.1: Repoint Tailscale HTTPRoute

**Files:** wherever the Tailscale `HTTPRoute` for `llm.priv.cloud.ogenki.io` lives (likely `infrastructure/mycluster-0/tailscale-gateway/` or `apps/base/ai/llm/`).

- [ ] **Step 1: Locate the existing HTTPRoute**: `grep -r 'xplane-llm-ai-gateway\|llm.priv' apps/ infrastructure/`.
- [ ] **Step 2: Change `backendRefs`** to point at the AI Gateway data-plane Service. Discover the exact name with `kubectl get svc -n <ai-gateway-ns>` after P1 completes — the AI Gateway controller typically names it `<gateway-name>-data-plane` or `eg-<gateway-name>`.
- [ ] **Step 3: Verify external access** through Tailscale: `curl -sv https://llm.priv.cloud.ogenki.io/v1/models` returns the model list.

### Task P5.2: Delete legacy CEC + Service + CNP

- [ ] `rm -r infrastructure/base/llm-ai-gateway/`
- [ ] Verify nothing references it: `grep -r 'llm-ai-gateway' . --exclude-dir=docs`. (Docs references are fine — they describe the migration history.)
- [ ] Remove from `clusters/mycluster-0-llm-platform/` umbrella if listed.

### Task P5.3: Delete the custom Go proxy

- [ ] `rm -r tooling/llm-router-proxy/`
- [ ] `rm .github/workflows/llm-router-proxy.yml`
- [ ] Verify nothing references the image: `grep -r 'llm-router-proxy' . --exclude-dir=docs --exclude-dir=.git`.
- [ ] **Manual step (post-merge):** delete the GHCR package via `gh api -X DELETE /user/packages/container/llm-router-proxy` (verify exact name first).

### Task P5.4: Update the umbrella README

**Files:** `clusters/mycluster-0-llm-platform/README.md`.

- [ ] Update the architecture description to reflect: dedicated Envoy AI Gateway data plane, InferencePool + EPP per model, SR ext_proc as a pre-parser filter.
- [ ] Remove references to the CEC and `llm-router-proxy`.
- [ ] Add a "Migration history" subsection pointing at the redesign design doc + this plan.

### Task P5.5: Close out tasks

- [ ] Mark task #76 (per-claim CNP overrides) **completed** — folded into P4.5.
- [ ] Mark task #78 (ext_proc cold-connect) **completed** — task #91 (HTTP/2 keepalive) + AI Gateway's longer-lived control connections address it; if regression seen, reopen with a fresh report.
- [ ] Mark task #114–118 (P1–P5) **completed** in order.

### Task P5.6: Commit P5

- [ ] Commit messages:
  - `chore(llm): delete legacy CEC + llm-ai-gateway directory`
  - `chore(llm): delete tooling/llm-router-proxy + GHCR workflow`
  - `feat(tailscale): repoint llm hostname to Envoy AI Gateway data plane`
  - `docs(llm): update mycluster-0-llm-platform README — new gateway architecture`

**SC met by P5:** SC-05 (proxy removed), all SCs validated end-to-end on the new stack.

---

## Cross-cutting verification (run after every phase)

| Claim | Evidence command |
|-------|------------------|
| KCL composition valid (P4) | `./scripts/validate-kcl-compositions.sh` → exit 0 |
| Manifests valid (P1, P2, P3, P5) | `kubeconform -summary -strict <files>` → 0 errors |
| Trivy clean | `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml infrastructure/base/envoy-ai-gateway/` |
| Flux reconciled | `flux get kustomizations` → all `Ready=True` |
| Crossplane XR ready (P4) | `kubectl get inferenceservice.cloud.ogenki.io -n llm` → `Synced=True Ready=True` |
| HTTP 200 end-to-end | `curl -sv -X POST .../v1/chat/completions ... | head -1` → `HTTP/1.1 200 OK` |
| `x-vsr-selected-model` present for MoM | response headers contain it |
| No CNP drops | `hubble observe --pod llm/<pod> --verdict DROPPED --last 50` → empty for expected traffic |

Per `.claude/rules/process.md`: every "done" claim cites a fresh command run in the same response. No previous-run extrapolation.

---

## Rollback playbook

| Phase | Rollback |
|-------|---------|
| P1 | `flux suspend kustomization envoy-ai-gateway` and revert the umbrella include. Cluster keeps running on `llm-router-proxy` + CEC. |
| P2 | Delete the `EnvoyExtensionPolicy`. Routes still work for explicit model names; MoM is unrouted via the new path (still served by `llm-router-proxy`). |
| P3 | Per-route revert — delete the offending route file, push, reconcile. |
| P4 | Per-model revert — switch the offending route's `backendRef.kind` back to `Service`. The composition can be left emitting both InferencePool and Service during transition if the chart accepts that (parallel resources). |
| P5 | Restore from git: `git revert <commit>` for the deletion commits. Re-deploy the proxy. |

---

## Open items (to resolve during implementation)

1. **Exact AI Gateway chart version + CRD strategy** (P1.1, P1.2). Verify against upstream releases page.
2. **Filter ordering vs. Lua fallback** (P2.3 step 4). Test order; document the actual behavior in this plan after P2.
3. **EPP image version pin** (P4.1, P4.2). Pick a known-good tag; document in `kcl.mod` or a header comment.
4. **PodMonitor vs headless Service for vLLM scraping** (P4.2 step 6). Lean: PodMonitor.
5. **Tailscale HTTPRoute exact file location** (P5.1). Resolve via grep.
6. **GHCR package deletion command** (P5.3). Verify exact package name before issuing `gh api -X DELETE`.

---

## Plan summary

5 phases, each independently mergeable, each ~10 tasks. Total: ~50 numbered tasks. The legacy stack stays as the safety net until P5. The blog-post hook is captured in design §1; this plan delivers the wiring that the blog post will describe.
