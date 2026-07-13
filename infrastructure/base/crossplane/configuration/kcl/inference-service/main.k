# inference-service composition.
#
import json

# Conditionally-rendered resources are wrapped in a single-element list
# `_x = [{...}]` then appended to `_items` to avoid function-kcl issue
# #285 (duplicate-detection bug on direct dict mutation). The pattern
# repeats for HTTPRoute, CiliumNetworkPolicy (preload variant),
# ExternalSecret, VMServiceScrape, VMRule, and the preload Job.
oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_name = oxr.metadata.name
_namespace = oxr.metadata.namespace

_appLabels = {
    "app.kubernetes.io/name" = _name
    "app.kubernetes.io/instance" = _name
    "app.kubernetes.io/component" = "inference"
    "app.kubernetes.io/part-of" = "ai"
}

# Preload Job carries the same labels with `component=preload` — a
# distinct selector lets us scope the broad egress (HF/world:443,
# AWS API, EKS Pod Identity Agent) to the one-shot Job and keep
# the long-lived serving Deployment on a tight default-deny.
_preloadLabels = _appLabels | {"app.kubernetes.io/component" = "preload"}

_podSelector = {matchLabels = _appLabels}

# Multi-use accessors. Single-use values inline at point of use.
_modelRepository = oxr.spec.model.repository
_modelRevision = oxr.spec.model.revision or "main"
# CL-3 rec A
_preloadEnabled = oxr.spec.model?.preload?.enabled or False
_gpuCount = oxr.spec.gpu.count or 1
_minReplicas = oxr.spec.scaling?.minReplicas or 1
_maxReplicas = oxr.spec.scaling?.maxReplicas or 3
_cooldownSeconds = oxr.spec.scaling?.cooldownSeconds or 300
_pollingIntervalSeconds = oxr.spec.scaling?.pollingIntervalSeconds or 15
_runningRatioThreshold = oxr.spec.scaling?.runningRatioThreshold or "0.7"
_cacheUtilizationThreshold = oxr.spec.scaling?.cacheUtilizationThreshold or "0.6"
_queueLengthThreshold = oxr.spec.scaling?.queueLengthThreshold or 8
_maxNumSeqs = oxr.spec.model?.maxNumSeqs or 64
_routeEnabled = oxr.spec.route?.enabled or False

# Per ADR-0004: model weights live on a shared S3 Files POSIX filesystem,
# provisioned by opentofu/llm-platform/. The shared PV/PVC `llm-models`
# (created in apps/base/ai/llm/models-pvc.yaml) is mounted by all 4
# InferenceService claims with subPath isolation per claim.
_subPath = oxr.spec.weightsFileSystem?.subPath or _name

# Inside the container the PVC is mounted at /models with subPath, so the
# revision-pinned weights directory is /models/<revision>/.
_modelLocalPath = "/models/" + _modelRevision
_modelQuantization = oxr.spec.model.quantization or "fp16"

_envFromList = [{
    secretRef = {name = s.name}
} for s in oxr.spec.externalSecrets or []] + [{
    secretRef = {name = n}
} for n in oxr.spec.envFromSecrets or []]

_DEFAULTS = {
    # Resources — sized for L4 (24Gi VRAM) with fp8/fp16 small-medium models
    cpu_request = "2"
    memory_request = "16Gi"
    cpu_limit = "8"
    memory_limit = "32Gi"
    # Health checks (cold-start budget per FR-005 = 90s)
    liveness_initial_delay = 60
    liveness_period = 30
    liveness_timeout = 10
    liveness_failure_threshold = 3
    readiness_initial_delay = 30
    readiness_period = 10
    readiness_timeout = 5
    readiness_failure_threshold = 3
    startup_initial_delay = 30
    startup_period = 10
    startup_timeout = 10
    startup_failure_threshold = 30
    # vLLM
    # 0.6.5 ships transformers too old for Phi-4-mini's modern rope_scaling
    # schema (raises `short_factor field must have length 64, got 48`).
    # 0.8.5 supports Phi-4 family + Qwen3 + DeepSeek-R1-Distill-Qwen.
    vllm_image = "vllm/vllm-openai:v0.8.5"
    vllm_port = 8000
    gpu_memory_utilization = "0.92"
    nodepool = "gpu-l4"
    parent_gateway = "platform-tailscale-general"
    parent_gateway_namespace = "infrastructure"
    # SPEC-002: the Envoy AI Gateway the per-claim AIGatewayRoute attaches to.
    ai_gateway = "ai-gateway"
    ai_gateway_namespace = "envoy-ai-gateway-system"
    preload_sa = "xplane-llm-models-preload"
    # Volume sizing — pod_models stays under EC2NodeClass /dev/xvdb (100Gi)
    # given the gpu-l4 NodePool's 4-pod cap (CL-6 A: nvidia.com/gpu = 4)
    pod_models_size = "30Gi"
    preload_tmp_size = "32Gi"
    # ExternalSecret backend
    secret_store = "clustersecretstore"
    # KEDA prometheus trigger query target. Port 8428 is the VictoriaMetrics
    # single ingress / query port (chart default; verified via `kubectl get
    # svc vmsingle-victoria-metrics-k8s-stack -n observability`).
    prometheus_server_address = "http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8428"
}

# Resource metadata helper. `name` defaults to the claim name (Service /
# Deployment / etc. are addressed by callers via the claim name); the
# `composition-resource-name` annotation carries the per-resource unique
# suffix. Callers that need a non-claim name (EPI's `-s3-read`, the
# preload Job's `-preload-<rev>`, ExternalSecrets named after the AWS
# secret) override via dict union: `_metadata(...) | {name = "..."}`.
_metadata = lambda suffix: str, ready: bool -> any {
    {
        name = _name
        namespace = _namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = _name + "-" + suffix
            if ready:
                "krm.kcl.dev/ready" = "True"
        }
        labels = _appLabels
    }
}

_setResourceRequirements = lambda resources: any -> any {
    {
        requests = (resources?.requests or {cpu = _DEFAULTS.cpu_request, memory = _DEFAULTS.memory_request}) | {"nvidia.com/gpu" = _gpuCount}
        limits = (resources?.limits or {cpu = _DEFAULTS.cpu_limit, memory = _DEFAULTS.memory_limit}) | {"nvidia.com/gpu" = _gpuCount}
    }
}

# vLLM container args. --quantization is dropped for fp16 (vLLM auto-detects).
# --model always points at the local S3 Files mount path — no fall-through to
# fetching from HF at vLLM startup (preload Job is the only HF consumer).
_baseVllmArgs = ["--model", _modelLocalPath, "--served-model-name", _name, "--max-model-len", str(oxr.spec.model.contextWindow or 4096), "--max-num-seqs", str(_maxNumSeqs), "--gpu-memory-utilization", _DEFAULTS.gpu_memory_utilization]
_quantArgs = ["--quantization", _modelQuantization] if _modelQuantization != "fp16" else []
_prefixCacheArgs = ["--enable-prefix-caching"] if oxr.spec.cache?.prefixCache?.enabled else []
_kvOffloadArgs = ["--cpu-offload-gb", str(oxr.spec.cache?.kvOffload?.sizeGB or 16)] if oxr.spec.cache?.kvOffload?.enabled else []

# Tool-calling support: when `model.toolCallParser` is set, vLLM is started
# with --enable-auto-tool-choice + --tool-call-parser <name>. Without these,
# vLLM 400s on chat/completions requests that carry `tools[]` or
# `tool_choice: auto` (e.g. OpenCode, Continue agentic profiles, OpenAI SDK
# with function-calling). Common values: `hermes` (Qwen2.5/Qwen3 family),
# `llama3_json` (Llama 3.x), `phi4_mini_json` (Phi-4-mini). FIM/Base models
# leave it unset.
_toolCallArgs = ["--enable-auto-tool-choice", "--tool-call-parser", oxr.spec.model.toolCallParser] if oxr.spec.model?.toolCallParser else []

# LoRA adapters: when `loraAdapters` non-empty, enable vLLM's LoRA support.
# `--max-loras` is the simultaneous-active count (= len(adapters)).
# `--max-lora-rank 64` covers rank-32/rank-64 majority of public adapters; bump
# only if a chosen adapter exceeds it (verify via adapter_config.json `r` field).
# `--lora-modules name=path` tells vLLM where each adapter lives on disk —
# matches the preload Job's `/models/loras/<name>/` layout.
_loraAdapters = oxr.spec.loraAdapters or []
_loraArgs = (["--enable-lora", "--max-loras", str(len(_loraAdapters)), "--max-lora-rank", "64", "--lora-modules"] + ["{}={}".format(a.name, "/models/loras/" + a.name) for a in _loraAdapters]) if _loraAdapters else []

# SPEC-005 (phase 1): Run:ai Model Streamer load-format. When
# spec.model.streaming.enabled, vLLM loads weights with
# `--load-format runai_streamer`, reading the SAME local PVC-mounted
# safetensors at _modelLocalPath (/models/<revision>) concurrently and
# streaming tensors to GPU — no `s3://` URL, no storage change (CL-2). The
# streamer binary is bundled in vllm/vllm-openai:v0.8.5 (CL-1) so this is a
# flag-only diff (no new pod / IAM / S3 / PVC / Secret — FR-006). When
# streaming.concurrency is set, `--model-loader-extra-config` carries a
# compact JSON object `{"concurrency": N}` (json.encode → canonical, testable
# with json.decode in main_test.k). concurrency without enabled renders no
# streamer flags at all — the outer `if enabled` gates everything. Single
# inline-conditional expression, no post-creation dict mutation (function-kcl
# #285). Off/unset ⇒ [] ⇒ _managedVllmArgs byte-identical to pre-SPEC-005
# (FR-005, SC-004). Ordered before user engineArgs so it is covered by the
# `args == _managedVllmArgs + _engineArgs` invariant.
_streamingEnabled = oxr.spec.model?.streaming?.enabled or False
_streamingConcurrency = oxr.spec.model?.streaming?.concurrency
_streamerArgs = (["--load-format", "runai_streamer"] + (["--model-loader-extra-config", json.encode({concurrency = _streamingConcurrency})] if _streamingConcurrency != Undefined else [])) if _streamingEnabled else []

# SPEC-003 FR-001/FR-002: user-supplied vLLM engine args. Verbatim passthrough
# — NO transform, NO re-validation here; the XRD admission CEL denylist is the
# single enforcement point (rejects managed flags + bare `--flag value` form).
# Appended as the LAST slice so composition-managed flags ALWAYS precede user
# flags — a user cannot re-order or shadow a managed flag.
_engineArgs = oxr.spec.engineArgs or []

_managedVllmArgs = _baseVllmArgs + _quantArgs + _prefixCacheArgs + _kvOffloadArgs + _toolCallArgs + _loraArgs + _streamerArgs
_vllmArgs = _managedVllmArgs + _engineArgs

# Observed resources from cluster state (drive readiness annotations).
_observed = lambda suffix: str -> any {
    ocds[_name + "-" + suffix]?.Resource if _name + "-" + suffix in ocds else None
}
_observedDeployment = _observed("deployment")
_observedService = _observed("service")
_observedHTTPRoute = _observed("httproute")
_observedScaledObject = _observed("scaledobject")
_observedServiceAccount = _observed("serviceaccount")
_observedVMServiceScrape = _observed("vmservicescrape")
_observedVMRule = _observed("vmrule")
_observedPreloadJob = _observed("preload-job")

# SPEC-002: single source of truth for the AIGatewayRoute resource suffix.
# Used for BOTH the observed-state ocds lookup and the rendered resource's
# composition-resource-name, so the latch key cannot drift between read and
# write — a rename touches exactly one line.
_gatewayRouteSuffix = "gateway-airoute"
_observedAIGatewayRoute = _observed(_gatewayRouteSuffix)

_readyByCondition = lambda obj: any, ctype: str -> bool {
    any_true([c?.type == ctype and c?.status == "True" for c in obj?.status?.conditions or []])
}
_existsReady = lambda obj: any -> bool {
    obj != None and obj?.metadata != None
}
_appliedReady = lambda obj: any -> bool {
    any_true([c?.status == "True" and (c?.type or "").endswith("/Applied") for c in obj?.status?.conditions or []])
}

# SPEC-002 FR-002: the AIGatewayRoute is gated on Deployment readiness with
# a latch — render only once the Deployment is Available OR the route is
# already observed in ocds (keyed by the SAME _gatewayRouteSuffix the render
# uses). A transient Deployment blip never withdraws a live route (no
# flapping). Takes the raw ocds so tests exercise the exact key-construction
# main.k relies on, not a re-implementation of it.
_aiGatewayRouteShouldRender = lambda name: str, ocdsState: any, deploymentReady: bool -> bool {
    deploymentReady or (name + "-" + _gatewayRouteSuffix) in ocdsState
}

_deploymentReady = _readyByCondition(_observedDeployment, "Available")
_serviceReady = _observedService?.spec?.clusterIP != None
_httpRouteReady = any_true([c?.type == "Accepted" and c?.status == "True" for c in _observedHTTPRoute?.status?.parents?[0]?.conditions or []])
_scaledObjectReady = _readyByCondition(_observedScaledObject, "Ready")
_serviceAccountReady = _existsReady(_observedServiceAccount)
_vmServiceScrapeReady = _appliedReady(_observedVMServiceScrape)
_vmRuleReady = _appliedReady(_observedVMRule)
_preloadJobReady = (_observedPreloadJob?.status?.succeeded or 0) > 0

# SPEC-002 gateway wiring.
_gatewayEnabled = oxr.spec.gateway?.enabled or False
_gatewayCanaries = oxr.spec.gateway?.canaries or []

# SPEC-004: GAIE endpoint-picker opt-in. When enabled (requires gateway.enabled
# and is mutually exclusive with canaries — both XRD-CEL-enforced), the
# composition renders a per-claim HelmRelease `<name>-epp` (chart `inferencepool`
# v1.5.0) that installs the InferencePool CR + EPP Deployment/Service, and swaps
# the AIGatewayRoute base rule's backendRefs to the InferencePool. Default off.
_endpointPickerEnabled = oxr.spec.gateway?.endpointPicker?.enabled or False

# Naming (CL-2, verified against the v1.5.0 chart helpers):
#   * The HelmRelease sets `spec.releaseName = _name`, so Helm's Release.Name is
#     the claim name. The `inferencepool` chart names the InferencePool CR
#     `{{ .Release.Name }}` ⇒ `<name>` (matches the base-rule backendRef, CL-3),
#     and the EPP Deployment/Service via the `<Release.Name>-epp` helper ⇒
#     `<name>-epp`. The HelmRelease object itself is metadata.name `<name>-epp`.
#   * EPP Service carries chart label `app.kubernetes.io/name: <name>-epp`; the
#     VMServiceScrape selector and the EPP CNP endpointSelector key off it.
_eppName = _name + "-epp"
_eppExtProcPort = 9002

# Chart Service exposes the metrics endpoint on `http-metrics`/9090 (chart
# `inferenceExtension.metricsPort` default). The VMServiceScrape targets it by
# port NAME; the EPP CNP allows vmagent to reach it by NUMBER (_eppIngressRules).
_eppMetricsPort = 9090

# Shared CiliumNetworkPolicy peer selectors. Both the serving CNP and the EPP CNP
# admit the same two callers, so the selectors live in one place — a drift between
# two copies of these labels is a silent DROP, not an error.
_vmagentPeer = {
    matchLabels = {"io.kubernetes.pod.namespace" = "observability", "app.kubernetes.io/name" = "vmagent"}
}
_envoyDataPlanePeer = {
    matchLabels = {"io.kubernetes.pod.namespace" = "envoy-gateway-system", "gateway.envoyproxy.io/owning-gateway-name" = "ai-gateway", "gateway.envoyproxy.io/owning-gateway-namespace" = "envoy-ai-gateway-system"}
}

# EPP CiliumNetworkPolicy ingress, as a module-level value the test suite drives
# DIRECTLY (same discipline as `_baseRuleBackendRefsFor`) rather than through a
# mirror copy — a mirror would keep passing if these rules were deleted here.
# Two peers, both mandatory:
#   * ext-proc :9002 from the Envoy AI Gateway data plane — the routing path.
#   * metrics :9090 from vmagent — without it the `<name>-epp` VMServiceScrape is
#     inert: the EPP CNP is default-deny, so the scrape is silently DROPPED with
#     no error surfaced anywhere (.claude/rules/cilium-network-policies.md).
_eppIngressRules = [
    {
        fromEndpoints = [_envoyDataPlanePeer]
        toPorts = [{ports = [{port = str(_eppExtProcPort), protocol = "TCP"}]}]
    }
    {
        fromEndpoints = [_vmagentPeer]
        toPorts = [{ports = [{port = str(_eppMetricsPort), protocol = "TCP"}]}]
    }
]

# Single source of truth for the gateway backend names (same discipline as
# _gatewayRouteSuffix): the Backend's own name and the per-canary
# AIServiceBackend backendRef linkages must never drift apart. Each canary
# adapter gets its own `-canary-<i>` backend so multiple weighted splits can
# coexist as distinct named backendRefs on the single base rule.
_gatewayBackendName = _name + "-direct"
_gatewayCanaryBackendName = lambda i: int -> str {
    _name + "-canary-" + str(i)
}

# Total canary weight; the base-model backendRef keeps the remainder. CEL at
# the XRD guarantees this stays <= 99 so the base model always retains traffic.
_gatewayCanaryWeightTotal = sum([c.weightPercent for c in _gatewayCanaries], 0)

# SPEC-004 (FR-004, CL-3/CL-4): the base-rule backendRefs are chosen by a single
# inline conditional on `endpointPickerEnabled`, never by mutating the SPEC-002
# rule dict (function-kcl #285). When endpointPicker is on, the base rule hands
# the request to the InferencePool `<name>` (group inference.networking.k8s.io,
# kind InferencePool) — a single ref with NO weight/modelNameOverride (unsupported
# on InferencePool backendRefs, and canaries are CEL-excluded so `canaryRefs` is
# always [] on this path). Otherwise it keeps the SPEC-002 weighted base+canary
# AIServiceBackend refs verbatim. Pure lambda so main_test.k drives the EPP branch
# against a canary-less synthetic input (the single global fixture carries canaries
# and thus cannot enable endpointPicker — same discipline as _streamerArgsFor).
_baseRuleBackendRefsFor = lambda endpointPickerEnabled: bool, name: str, canaryWeightTotal: int, canaryRefs: [any] -> [any] {
    [{group = "inference.networking.k8s.io", kind = "InferencePool", name = name}] if endpointPickerEnabled else ([{name = name, weight = 100 - canaryWeightTotal}] + canaryRefs)
}

# SPEC-003 FR-005: status.servedModels topology projection — the base model
# plus one entry per LoRA adapter. `canaryWeightPercent` is included ONLY for
# canary-targeted adapters (via `**` spread of an inline-conditional dict, so
# the key is ABSENT — not null — otherwise). No dict is mutated after creation
# (function-kcl #285).
_canaryWeightByAdapter = {cv.adapter: cv.weightPercent for cv in _gatewayCanaries}
_servedModels = [{name = _name, kind = "base"}] + [{name = a.name, kind = "adapter", **({canaryWeightPercent = _canaryWeightByAdapter[a.name]} if a.name in _canaryWeightByAdapter else {})} for a in _loraAdapters]

# AIGatewayRoute v1alpha1 publishes top-level status.conditions; the route
# is "ready" once Accepted=True (mirror of the HTTPRoute check). Absent
# status ⇒ not ready (defensive: _readyByCondition returns False on []).
_aiRouteReady = _readyByCondition(_observedAIGatewayRoute, "Accepted")

_items = []

_serviceAccount = {
    apiVersion = "v1"
    kind = "ServiceAccount"
    metadata = _metadata("serviceaccount", _serviceAccountReady)
}

_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = _metadata("deployment", _deploymentReady)
    spec = {
        # Replicas managed exclusively by KEDA ScaledObject (v0.5.0).
        # Setting replicas here would race with KEDA on every reconcile.
        selector = _podSelector
        # GPUs are scarce; surge would block scheduling
        strategy = {type = "Recreate"}
        template = {
            metadata = {labels = _appLabels}
            spec = {
                serviceAccountName = _name
                # SA carries no IAM — per ADR-0004 the serving pod reaches
                # weights through the EFS CSI mount (handled by the
                # csi_driver IAM role bound to kube-system/efs-csi-{node,
                # controller}-sa, not this SA). The token mount stays on
                # for in-cluster API calls (Downward API metadata, future
                # service-mesh use) and is harmless without an IAM binding.
                automountServiceAccountToken = True
                nodeSelector = {"karpenter.sh/nodepool" = _DEFAULTS.nodepool}
                tolerations = [{key = "nvidia.com/gpu", operator = "Exists", effect = "NoSchedule"}]
                runtimeClassName = "nvidia"
                terminationGracePeriodSeconds = 60
                securityContext = {
                    seccompProfile = {type = "RuntimeDefault"}
                    runAsNonRoot = True
                    # Match the S3 Files Access Point's posix_user.uid (1001)
                    # so the AP doesn't have to remap. The serving container
                    # also has $USER set in env (below), which lets python's
                    # `getpass.getuser()` short-circuit before it falls back
                    # to `pwd.getpwuid` — vLLM's image lacks /etc/passwd
                    # entries for non-root users, so without $USER any
                    # non-root uid raises KeyError on model inspection.
                    runAsUser = 1001
                    fsGroup = 1001
                }
                volumes = [{name = "models", persistentVolumeClaim = {claimName = "llm-models"}}, {name = "tmp", emptyDir = {}}, {name = "shm", emptyDir = {medium = "Memory", sizeLimit = "8Gi"}}]
                containers = [{
                    name = "vllm"
                    image = _DEFAULTS.vllm_image
                    args = _vllmArgs
                    # Defaults satisfy PSS=restricted; user-supplied
                    # securityContext fields win via dict union (right
                    # side overrides). This carries through arbitrary
                    # extra fields the user sets (`runAsUser`, `seLinuxOptions`,
                    # etc.) that the prior ternary-rebuild pattern silently
                    # dropped.
                    securityContext = {
                        allowPrivilegeEscalation = False
                        readOnlyRootFilesystem = True
                        runAsNonRoot = True
                        capabilities = {drop = ["ALL"]}
                    } | (oxr.spec.securityContext or {})
                    env = [
                        {name = "HF_HOME", value = "/models/.huggingface"}
                        {name = "POD_NAME", valueFrom = {
                            fieldRef = {fieldPath = "metadata.name"}
                        }}
                        {name = "POD_NAMESPACE", valueFrom = {
                            fieldRef = {fieldPath = "metadata.namespace"}
                        }}
                        {name = "VLLM_LOGGING_LEVEL", value = "INFO"}
                        # Bypass `pwd.getpwuid` lookups (see runAsUser comment).
                        {name = "USER", value = "vllm"}
                        {name = "HOME", value = "/tmp"}
                    ]
                    if _envFromList:
                        envFrom = _envFromList
                    ports = [{containerPort = _DEFAULTS.vllm_port, name = "http", protocol = "TCP"}]
                    resources = _setResourceRequirements(oxr.spec.resources)
                    # subPath isolates this claim's slice of the shared S3
                    # Files filesystem under /models/ inside the pod.
                    volumeMounts = [{name = "models", mountPath = "/models", subPath = _subPath}, {name = "tmp", mountPath = "/tmp"}, {name = "shm", mountPath = "/dev/shm"}]
                    livenessProbe = {
                        httpGet = {path = "/health", port = "http"}
                        initialDelaySeconds = oxr.spec.healthProbes?.liveness?.initialDelaySeconds or _DEFAULTS.liveness_initial_delay
                        periodSeconds = oxr.spec.healthProbes?.liveness?.periodSeconds or _DEFAULTS.liveness_period
                        timeoutSeconds = oxr.spec.healthProbes?.liveness?.timeoutSeconds or _DEFAULTS.liveness_timeout
                        failureThreshold = oxr.spec.healthProbes?.liveness?.failureThreshold or _DEFAULTS.liveness_failure_threshold
                    }
                    readinessProbe = {
                        httpGet = {path = "/health", port = "http"}
                        initialDelaySeconds = oxr.spec.healthProbes?.readiness?.initialDelaySeconds or _DEFAULTS.readiness_initial_delay
                        periodSeconds = oxr.spec.healthProbes?.readiness?.periodSeconds or _DEFAULTS.readiness_period
                        timeoutSeconds = oxr.spec.healthProbes?.readiness?.timeoutSeconds or _DEFAULTS.readiness_timeout
                        failureThreshold = oxr.spec.healthProbes?.readiness?.failureThreshold or _DEFAULTS.readiness_failure_threshold
                    }
                    startupProbe = {
                        httpGet = {path = "/health", port = "http"}
                        initialDelaySeconds = _DEFAULTS.startup_initial_delay
                        periodSeconds = _DEFAULTS.startup_period
                        timeoutSeconds = _DEFAULTS.startup_timeout
                        failureThreshold = _DEFAULTS.startup_failure_threshold
                    }
                }]
            }
        }
    }
}

_service = {
    apiVersion = "v1"
    kind = "Service"
    metadata = _metadata("service", _serviceReady)
    spec = {
        selector = _appLabels
        ports = [{name = "http", port = _DEFAULTS.vllm_port, targetPort = "http", protocol = "TCP"}]
        type = "ClusterIP"
    }
}

# PV + PVC for the shared S3 Files filesystem are provisioned OUT-OF-BAND
# in apps/base/ai/llm/models-pvc.yaml because Crossplane v2 namespaced
# composites cannot render cluster-scoped resources (PV is cluster-scoped).
# A single shared PVC `llm-models` (RWM) lives in the `llm` namespace; all
# 4 InferenceService claims mount it via subPath isolation per claim.
_items += [_serviceAccount, _deployment, _service]

# KEDA ScaledObject — leading-indicator autoscaling.
# v0.5.0 (SPEC-001): switched from KEDA HTTP add-on (lagging request-count
# trigger + proxy in the data path) and HPA-on-CPU (CPU is irrelevant for
# GPU-bound vLLM) to a single ScaledObject with two prometheus triggers:
#
#   1. running / max-num-seqs ratio  — leading: scale before batch saturates
#   2. gpu_cache_usage_perc          — leading: catches long-context bursts
#                                      that running-count misses
#   3. num_requests_waiting          — earliest pressure signal: requests
#                                      queue before the running ratio
#                                      saturates. threshold 8 ≈ tolerate a
#                                      short burst; a sustained queue drives
#                                      scale-up.
#
# All three triggers OR-combined; any one >= threshold drives a scale-up
# decision at `pollingIntervalSeconds` cadence. `cooldownSeconds` is the
# minimum hold time before scale-down (amortises CUDA-graph compile cost).
#
# Always rendered (no longer minReplicas-conditional). Production default
# is min=1; demo overrides to min=0 are allowed via spec.scaling but lose
# scale-from-zero queueing — first request to a scaled-to-0 model fails
# until a replica becomes Ready (~60-120s). See SPEC-001 §non-goals.
_scaledObject = [{
    apiVersion = "keda.sh/v1alpha1"
    kind = "ScaledObject"
    metadata = _metadata("scaledobject", _scaledObjectReady)
    spec = {
        scaleTargetRef = {apiVersion = "apps/v1", kind = "Deployment", name = _name}
        minReplicaCount = _minReplicas
        maxReplicaCount = _maxReplicas
        pollingInterval = _pollingIntervalSeconds
        cooldownPeriod = _cooldownSeconds
        triggers = [
            {
                type = "prometheus"
                metadata = {
                    serverAddress = _DEFAULTS.prometheus_server_address
                    # `max(...)` over replicas is hottest-replica saturation,
                    # not fleet average. A single hot pod (one replica's
                    # batch slots filling) drives scale-up even if other
                    # replicas are idle — conservative on purpose. Scale-
                    # down noise is dampened by `cooldownPeriod` (300s
                    # default) so a brief hot-replica spike won't ratchet
                    # replicas down before the load redistributes.
                    query = "max(vllm:num_requests_running{model_name=\"" + _name + "\"}) / scalar(vector(" + str(_maxNumSeqs) + "))"
                    threshold = _runningRatioThreshold
                    activationThreshold = "0.05"
                }
            }
            {
                type = "prometheus"
                metadata = {
                    serverAddress = _DEFAULTS.prometheus_server_address
                    query = "max(vllm:gpu_cache_usage_perc{model_name=\"" + _name + "\"})"
                    threshold = _cacheUtilizationThreshold
                    activationThreshold = "0.05"
                }
            }
            {
                type = "prometheus"
                metadata = {
                    serverAddress = _DEFAULTS.prometheus_server_address
                    query = "max(vllm:num_requests_waiting{model_name=\"" + _name + "\"})"
                    threshold = str(_queueLengthThreshold)
                    activationThreshold = "1"
                }
            }
        ]
    }
}]
_items += _scaledObject

# Per-model HTTPRoute is opt-in; most claims reach vLLM via the Semantic Router
if _routeEnabled:
    _routeHostname = oxr.spec.route.hostname + ".priv.cloud.ogenki.io" if oxr.spec.route?.hostname else None
    _httpRoute = [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "HTTPRoute"
        metadata = _metadata("httproute", _httpRouteReady)
        spec = {
            if _routeHostname:
                hostnames = [_routeHostname]
            parentRefs = [{name = _DEFAULTS.parent_gateway, namespace = _DEFAULTS.parent_gateway_namespace}]
            rules = [{
                matches = [{
                    path = {type = "PathPrefix", value = "/"}
                }]
                backendRefs = [{name = _name, port = _DEFAULTS.vllm_port}]
            }]
        }
    }]
    _items += _httpRoute

# SPEC-002: composition-owned Envoy AI Gateway routing. When gateway.enabled,
# this module renders the claim's Backend (its Service FQDN), AIServiceBackend
# (OpenAI schema) and AIGatewayRoute — replacing the hand-written entries in
# apps/base/ai/llm/ai-gateway-routes/route.yaml (do NOT also hand-maintain
# them there once a claim opts in). Backend + AIServiceBackend(s) are
# static-ready; the AIGatewayRoute is latched on Deployment readiness (FR-002).
if _gatewayEnabled:
    _gatewayBackend = [{
        apiVersion = "gateway.envoyproxy.io/v1alpha1"
        kind = "Backend"
        metadata = _metadata("gateway-backend", True) | {name = _gatewayBackendName}
        spec = {
            endpoints = [{
                fqdn = {hostname = _name + "." + _namespace + ".svc.cluster.local", port = _DEFAULTS.vllm_port}
            }]
        }
    }]
    _items += _gatewayBackend

    # AIServiceBackend(s) — identical bodies pointing at the same Backend; each
    # canary variant (one per gateway.canaries[] entry) differs solely by name,
    # so the base route rule can carry one named backendRef per canary. One
    # target list, one builder — a spec change applies to all.
    _aisbTargets = [{nm = _name, sfx = "gateway-aiservicebackend"}] + [{nm = _gatewayCanaryBackendName(i), sfx = "gateway-aiservicebackend-canary-" + str(i)} for i in range(len(_gatewayCanaries))]
    _aiServiceBackends = [{apiVersion = "aigateway.envoyproxy.io/v1alpha1", kind = "AIServiceBackend", metadata = _metadata(t.sfx, True) | {name = t.nm}, spec = {schema = {name = "OpenAI"}, backendRef = {group = "gateway.envoyproxy.io", kind = "Backend", name = _gatewayBackendName}}} for t in _aisbTargets]
    _items += _aiServiceBackends

    # Base rule: header x-ai-eg-model == <claim>. With canaries, split weight
    # between the base model and each adapter (all served by the same pod). The
    # base-model backendRef keeps 100 − sum(weights). modelNameOverride rewrites
    # the upstream model name to the adapter's OWN name — vLLM serves each LoRA
    # under loraAdapters[].name VERBATIM (main.k emits `--lora-modules
    # <name>=/models/loras/<name>`), and claims already use fully-qualified
    # adapter names (e.g. xplane-qwen-coder-sql-dpo). NO claim prefix here —
    # prefixing would double it to <claim>-<adapter>.
    _canaryBackendRefs = [{name = _gatewayCanaryBackendName(i), modelNameOverride = _gatewayCanaries[i].adapter, weight = _gatewayCanaries[i].weightPercent} for i in range(len(_gatewayCanaries))]

    # SPEC-004 (FR-004): InferencePool ref when endpointPicker on, SPEC-002
    # weighted base+canary refs otherwise — via the pure lambda (no mutation).
    _baseRuleBackendRefs = _baseRuleBackendRefsFor(_endpointPickerEnabled, _name, _gatewayCanaryWeightTotal, _canaryBackendRefs)
    _baseRule = {matches = [{headers = [{type = "Exact", name = "x-ai-eg-model", value = _name}]}], backendRefs = _baseRuleBackendRefs}

    # One pin rule per LoRA adapter (all adapters, canary or not): an explicit
    # request for the adapter's own name stays 100% on the base pod — vLLM
    # dispatches on the request-body model field. Match value = a.name verbatim
    # (adapter names are already fully-qualified; see comment above).
    _pinRules = [{matches = [{headers = [{type = "Exact", name = "x-ai-eg-model", value = a.name}]}], backendRefs = [{name = _name, weight = 100}]} for a in _loraAdapters]

    # Readiness latch (FR-002): render only when the Deployment is Available
    # OR the route is already observed. Never withhold a live route.
    if _aiGatewayRouteShouldRender(_name, ocds, _deploymentReady):
        _aiGatewayRoute = [{
            apiVersion = "aigateway.envoyproxy.io/v1alpha1"
            kind = "AIGatewayRoute"
            metadata = _metadata(_gatewayRouteSuffix, _aiRouteReady)
            spec = {
                parentRefs = [{name = _DEFAULTS.ai_gateway, namespace = _DEFAULTS.ai_gateway_namespace, kind = "Gateway", group = "gateway.networking.k8s.io"}]
                rules = [_baseRule] + _pinRules
            }
        }]
        _items += _aiGatewayRoute

    # SPEC-004 (FR-001, CL-2): per-claim HelmRelease `<name>-epp` installing the
    # GAIE `inferencepool` chart v1.5.0. `chartRef` points at the shared static
    # `llm`-namespace OCIRepository `inferencepool` (flux/sources/…, same-namespace
    # so cross-namespace-refs is moot). `spec.releaseName = _name` makes Helm's
    # Release.Name the claim name, so the chart names the InferencePool CR `<name>`
    # (the base-rule backendRef target, CL-3) and the EPP Deployment/Service
    # `<name>-epp`. The chart owns EPP + InferencePool + its namespace-scoped
    # pod-watch RBAC; Crossplane owns the HelmRelease ⇒ clean GC-on-delete.
    # Values transcribe the verified v1.5.0 chart keys (FR-003):
    #   * inferencePool.modelServers.matchLabels {app.kubernetes.io/name: <name>}
    #     — selects ONLY this claim's vLLM replicas, never cross-model (CL-5).
    #   * inferencePool.targetPorts [{number: 8000}] / modelServerType vllm /
    #     apiVersion inference.networking.k8s.io/v1 ; provider.name none.
    # HelmRelease is static-ready per crossplane-validation.md (Flux owns its
    # lifecycle; the composition treats it as ready-on-apply).
    if _endpointPickerEnabled:
        _eppHelmRelease = [{
            apiVersion = "helm.toolkit.fluxcd.io/v2"
            kind = "HelmRelease"
            metadata = _metadata("epp-helmrelease", True) | {name = _eppName}
            spec = {
                releaseName = _name
                chartRef = {kind = "OCIRepository", name = "inferencepool", namespace = _namespace}
                interval = "10m0s"
                install = {
                    remediation = {retries = 3}
                }
                upgrade = {
                    remediation = {retries = 3}
                }
                values = {
                    inferencePool = {
                        modelServers = {
                            matchLabels = {"app.kubernetes.io/name" = _name}
                        }
                        targetPorts = [{number = _DEFAULTS.vllm_port}]
                        modelServerType = "vllm"
                        apiVersion = "inference.networking.k8s.io/v1"
                    }
                    inferenceExtension = {
                        replicas = 1
                        image = {registry = "registry.k8s.io", repository = "gateway-api-inference-extension/epp", tag = "v1.5.0"}
                        # The chart defaults `monitoring.prometheus.auth.enabled: true`,
                        # and epplib's _deployment.yaml only passes
                        # `--metrics-endpoint-auth=false` when that value is FALSE.
                        # Left at the default, the EPP demands a bearer token on
                        # :9090/metrics and every credential-less scrape gets 401 —
                        # our VMServiceScrape sends none. Disable the auth filter and
                        # let the EPP CNP be the access control instead: only vmagent
                        # may reach :9090 (_eppIngressRules), everything else is
                        # default-denied. `prometheus.enabled` stays false (chart
                        # default) so the chart renders neither its own ServiceMonitor
                        # (we own a VMServiceScrape) nor the SA-token Secret.
                        monitoring = {
                            prometheus = {
                                auth = {enabled = False}
                            }
                        }
                    }
                    provider = {name = "none"}
                }
                # PSS=restricted compliance (SPEC-004 FR-008 / CL-7).
                #
                # The `llm` namespace enforces PodSecurity restricted, and the
                # inferencepool chart (v1.5.0) renders its EPP Deployment with NO
                # securityContext at all — neither pod- nor container-level — and
                # exposes no values key to set one (`inferenceExtension` offers only
                # replicas/image/extProcPort/failureMode/env/pluginsConfigFile/
                # extraContainerPorts/extraServicePorts/flags/affinity/tolerations/
                # resources/sidecar/monitoring/tracing/latencyPredictor/
                # metricsDataSource). So every EPP pod is rejected at admission:
                #
                #   replicaset/<name>-epp FailedCreate: pods "..." is forbidden:
                #   violates PodSecurity "restricted:latest"
                #
                # Helm then times out waiting for the Deployment, uninstalls, and
                # retries forever — the EPP never runs and the InferencePool has no
                # picker. CL-7's "Option A (trust-and-verify)" is therefore refuted
                # on-cluster: the chart is NOT restricted-compliant.
                #
                # Fixed with a Flux postRenderer rather than the Kyverno-mutate
                # fallback CL-7 proposed. A postRenderer is scoped to THIS release,
                # is rendered by (and GC'd with) the claim, keeps a cluster-wide
                # mutating policy out of the admission path, and is deterministic —
                # the manifest that Flux applies already carries the context.
                #
                # runAsUser 65532 is the distroless `nonroot` uid the registry.k8s.io
                # EPP image ships; runAsNonRoot alone would fail if the image's USER
                # resolved to root.
                postRenderers = [{
                    kustomize = {
                        patches = [{
                            target = {kind = "Deployment", name = _eppName}
                            patch = """\
- op: add
  path: /spec/template/spec/securityContext
  value:
    runAsNonRoot: true
    runAsUser: 65532
    seccompProfile:
      type: RuntimeDefault
- op: add
  path: /spec/template/spec/containers/0/securityContext
  value:
    allowPrivilegeEscalation: false
    readOnlyRootFilesystem: true
    capabilities:
      drop:
        - ALL
"""
                        }]
                    }
                }]
            }
        }]
        _items += _eppHelmRelease

        # SPEC-004 (FR-010, CL-8): VMServiceScrape `<name>-epp` selecting the EPP
        # Service (chart label `app.kubernetes.io/name: <name>-epp`) — the
        # composition owns it (GC'd with the claim), matching the vLLM
        # VMServiceScrape pattern. Metrics on the chart's `http-metrics` port.
        _eppVMServiceScrape = [{
            apiVersion = "operator.victoriametrics.com/v1beta1"
            kind = "VMServiceScrape"
            metadata = _metadata("epp-vmservicescrape", _appliedReady(_observed("epp-vmservicescrape"))) | {name = _eppName}
            spec = {
                selector = {
                    matchLabels = {"app.kubernetes.io/name" = _eppName}
                }
                endpoints = [{port = "http-metrics", path = "/metrics", interval = "30s", scrapeTimeout = "10s"}]
            }
        }]
        _items += _eppVMServiceScrape


# XR status patch (dxr) — ALWAYS rendered (SPEC-003 FR-007). servedModels +
# servedModelsSummary are unconditional topology projections; modelEndpoint is
# included ONLY when gateway.enabled (inline conditional via `**` spread of a
# conditional dict — no dict mutation, function-kcl #285). status.modelEndpoint
# is the external OpenAI-compatible URL: the domain comes from the
# eks-environment EnvironmentConfig (privateDomainName, populated via Flux
# ${private_domain_name} substitution) so the composition stays
# environment-agnostic; the literal fallback covers clusters whose
# EnvironmentConfig predates the field. External entry via the Tailscale gateway
# resolves to llm.<domain> (SPEC-002 P5). Patched onto the XR via the
# desired-composite (dxr) per the function-kcl status convention.
_privateDomain = envConfig?.privateDomainName or "priv.cloud.ogenki.io"
_dxrStatus = [{
    **option("params").dxr
    status: {
        servedModels = _servedModels
        servedModelsSummary = ",".join([m.name for m in _servedModels])
        **({modelEndpoint = "https://llm." + _privateDomain + "/v1"} if _gatewayEnabled else {})
    }
}]
_items += _dxrStatus

# CiliumNetworkPolicy — default-deny + explicit allow (constitution mandate).
# Two policies render: a tight one for the long-lived serving Deployment
# (DNS only, scoped ingress for routing/metrics) and a broader one for the
# one-shot preload Job (HF/world:443, AWS API, EKS Pod Identity Agent).
# Splitting on the `app.kubernetes.io/component` label avoids leaking the
# Job's broad egress onto serving pods.
# Cilium CNP `fromEndpoints.matchLabels` without an explicit
# `io.kubernetes.pod.namespace` key defaults to the policy's own
# namespace — so cross-namespace clients (apps/xplane-openwebui) MUST
# carry the namespace label, otherwise the policy silently drops.
_defaultIngress = [{
    fromEndpoints = [
        {
            matchLabels = {"app.kubernetes.io/name" = "vllm-semantic-router"}
        }
        {
            matchLabels = {"app.kubernetes.io/name" = "promptfoo"}
        }
        {
            matchLabels = {"app.kubernetes.io/name" = "xplane-openwebui", "io.kubernetes.pod.namespace" = "apps"}
        }
        # Envoy AI Gateway data plane routes traffic directly to vLLM
        # (SPEC-001 removed the KEDA HTTP add-on interceptor from the
        # data path; AI Gateway calls AIServiceBackend → Backend → vLLM
        # Service FQDN). Data-plane proxy pods live in envoy-gateway-system.
        _envoyDataPlanePeer
    ]
    toPorts = [{ports = [{port = str(_DEFAULTS.vllm_port), protocol = "TCP"}]}]
}]
_metricsIngress = [{
    fromEndpoints = [_vmagentPeer]
    toPorts = [{ports = [{port = str(_DEFAULTS.vllm_port), protocol = "TCP"}]}]
}]

# SPEC-004 (FR-007, CL-6): serving-CNP ingress extension — the EPP scrapes each
# vLLM replica's `/metrics` + probes endpoints on :8000 to score them, so the
# serving CNP must allow ingress from the EPP pod (chart label
# `app.kubernetes.io/name: <name>-epp`, same `llm` namespace). Empty [] when
# endpointPicker is off ⇒ byte-identical serving CNP to SPEC-002. Only appended
# when the composition's default-deny ingress is in force (a user
# networkPolicies.ingress override owns its own peer list).
# The EPP POD is selected by the chart's own label, NOT app.kubernetes.io/name.
# The inferencepool chart puts app.kubernetes.io/* on the SERVICE but gives the
# POD only `inferencepool: <release>-epp` (plus
# inference.networking.k8s.io/igw-mode and pod-template-hash). Selecting the pod
# by app.kubernetes.io/name therefore matches NOTHING, which fails silently and
# in the worst possible way:
#   * this vLLM ingress rule never matches, so the EPP's :8000 metric scrape —
#     the queue-depth / KV-cache signal it PICKS ENDPOINTS WITH — is DROPPED;
#   * the EPP's own CNP endpointSelector never matches, so the EPP pod is not
#     even default-denied.
# The picker then runs blind and silently degrades to fallback routing, while
# requests still return 200 and every resource still reports Ready. Verified on
# cluster with `hubble observe --pod llm/<epp> --verdict DROPPED`.
# The VMServiceScrape above keeps app.kubernetes.io/name because it selects the
# Service, which does carry it (up==1 confirms).
_eppPodSelector = {
    matchLabels = {inferencepool = _eppName}
}

_eppScrapeIngress = [{
    fromEndpoints = [_eppPodSelector]
    toPorts = [{ports = [{port = str(_DEFAULTS.vllm_port), protocol = "TCP"}]}]
}] if _endpointPickerEnabled else []
_dnsEgress = [{
    toEndpoints = [{
        matchLabels = {"io.kubernetes.pod.namespace" = "kube-system", "k8s-app" = "kube-dns"}
    }]
    # rules.dns is REQUIRED for Cilium to L7-inspect DNS responses and
    # populate IP/FQDN mappings used by downstream toFQDNs egress rules.
    # Without this, toFQDNs traffic is silently denied even with port 53
    # allowed (Hubble: 'Policy denied DROPPED' on the TCP SYN).
    toPorts = [{ports = [{port = "53", protocol = "UDP"}, {port = "53", protocol = "TCP"}], rules = {dns = [{matchPattern = "*"}]}}]
}]
_awsApiEgress = [{
    toFQDNs = [{matchPattern = "*.s3.eu-west-3.amazonaws.com"}, {matchName = "s3.eu-west-3.amazonaws.com"}, {matchPattern = "*.secretsmanager.eu-west-3.amazonaws.com"}]
    toPorts = [{ports = [{port = "443", protocol = "TCP"}]}]
}]

# Internet HTTPS egress — preload Job only. Maintaining a strict FQDN
# allowlist for HuggingFace meant chasing HF's CDN topology every time
# they rotated; for a one-shot bounded Job under PSS=restricted with
# scoped IAM, the policy-vs-effort balance favors `toEntities: world`
# on TCP 443 only. Default-deny on every other port/protocol still
# applies via the absence of any other rule.
_internetHttpsEgress = [{
    toEntities = ["world"]
    toPorts = [{ports = [{port = "443", protocol = "TCP"}]}]
}]

# EKS Pod Identity Agent — runs on the node, listens on the link-local
# 169.254.170.23:80. The preload Job's `xplane-llm-models-preload` SA
# is bound to a writable EPI and needs this for AWS SDK credential
# retrieval. Serving Deployment carries no SA-bound IAM (weights via
# CSI mount per ADR-0004) so this rule is preload-only. Cilium
# classifies traffic to host-network endpoints as the `host` entity;
# `toCIDR` on the link-local IP would silently fail (Hubble:
# policy-verdict:none DENIED).
_eksPodIdentityEgress = [{
    toEntities = ["host"]
    toPorts = [{ports = [{port = "80", protocol = "TCP"}]}]
}]

# Serving CNP — endpointSelector scoped to component=inference, so the
# preload Job pod (component=preload) is governed by the separate CNP
# rendered below. CNP is in the static-ready list per
# crossplane-validation.md (always ready when applied).
_networkPolicy = [{
    apiVersion = "cilium.io/v2"
    kind = "CiliumNetworkPolicy"
    metadata = _metadata("cilium-netpol", True)
    spec = {
        # _eppScrapeIngress is [] unless endpointPicker is on (FR-007, CL-6) —
        # appended so the EPP may reach vLLM :8000 to score replicas.
        endpointSelector = {matchLabels = _appLabels | {"app.kubernetes.io/component" = "inference"}}
        ingress = (oxr.spec.networkPolicies?.ingress or _defaultIngress) + _metricsIngress + _eppScrapeIngress
        egress = oxr.spec.networkPolicies?.egress or _dnsEgress
    }
}]
_items += _networkPolicy

# SPEC-004 EPP CiliumNetworkPolicy (FR-007, CL-6): default-deny + explicit allow
# for the new EPP pod (chart label `app.kubernetes.io/name: <name>-epp`). Renders
# only when endpointPicker is on. Traps from .claude/rules/cilium-network-policies.md:
#   * egress to the claim's vLLM pods on :8000 — `toEndpoints` on the serving
#     pods' `app.kubernetes.io/name: <name>` label (same namespace; `/metrics`
#     scrape + endpoint health checks the EPP uses to score replicas).
#   * egress to the kube-apiserver — `toEntities: ["kube-apiserver"]` (the EPP
#     watches Pods + the InferencePool CR; the apiserver is the `kube-apiserver`
#     entity, not a toCIDR — trap #3 idiom).
#   * egress to kube-dns:53 UDP/TCP WITH `rules.dns.matchPattern "*"` (reuses
#     `_dnsEgress`) — mandatory L7 DNS inspection or outbound resolution silently
#     drops (trap #1).
#   * ingress on the ext-proc port 9002 from the Envoy AI Gateway data plane
#     (reuses the SPEC-002 `envoy-gateway-system` / owning-gateway selector) —
#     Envoy calls the EPP per request to pick an endpoint.
# CNP is static-ready (crossplane-validation.md: always ready when applied).
if _endpointPickerEnabled:
    _eppVllmScrapeEgress = [{
        toEndpoints = [{matchLabels = _appLabels | {"app.kubernetes.io/component" = "inference"}}]
        toPorts = [{ports = [{port = str(_DEFAULTS.vllm_port), protocol = "TCP"}]}]
    }]
    _eppApiServerEgress = [{
        toEntities = ["kube-apiserver"]
    }]
    _eppNetworkPolicy = [{
        apiVersion = "cilium.io/v2"
        kind = "CiliumNetworkPolicy"
        metadata = _metadata("epp-cilium-netpol", True) | {name = _eppName}
        spec = {
            # Chart's real POD label (see _eppPodSelector above) — app.kubernetes.io/name
            # is on the Service only, so selecting the pod by it matches nothing and the
            # EPP silently ends up with NO policy at all.
            endpointSelector = _eppPodSelector
            ingress = _eppIngressRules
            egress = _eppVllmScrapeEgress + _eppApiServerEgress + _dnsEgress
        }
    }]
    _items += _eppNetworkPolicy

# Preload CNP — only when the preload Job is actually rendered. The Job
# downloads weights from HF (world:443), reads the HF token Secret
# (AWS API), and assumes the writable IAM role via EKS PIA (host:80).
# It accepts no ingress (Job pods don't serve traffic).
if _preloadEnabled:
    _preloadNetworkPolicy = [{
        apiVersion = "cilium.io/v2"
        kind = "CiliumNetworkPolicy"
        metadata = _metadata("cilium-netpol-preload", True) | {name = _name + "-preload"}
        spec = {
            endpointSelector = {matchLabels = _preloadLabels}
            egress = _dnsEgress + _awsApiEgress + _internetHttpsEgress + _eksPodIdentityEgress
        }
    }]
    _items += _preloadNetworkPolicy

# Per-claim EPI dropped per ADR-0004: serving pods no longer access S3
# directly — model weights are mounted via the EFS CSI driver. The CSI
# controller has its own IAM (xplane-llm-models-fs-csi-driver, created
# in opentofu/llm-platform/iam.tf) bound to kube-system/efs-csi-controller-sa.
if oxr.spec.externalSecrets:
    _externalSecrets = [{
        apiVersion = "external-secrets.io/v1"
        kind = "ExternalSecret"
        metadata = _metadata("externalsecret-" + secret.name, False) | {name = secret.name}
        spec = {
            refreshInterval = secret.refreshInterval or "1h"
            secretStoreRef = {kind = "ClusterSecretStore", name = _DEFAULTS.secret_store}
            target = {creationPolicy = "Owner", deletionPolicy = "Retain", name = secret.name}
            dataFrom = [{
                extract = {conversionStrategy = "Default", key = secret.remoteRef}
            }]
        }
    } for secret in oxr.spec.externalSecrets]
    _items += _externalSecrets

_vmServiceScrape = [{
    apiVersion = "operator.victoriametrics.com/v1beta1"
    kind = "VMServiceScrape"
    metadata = _metadata("vmservicescrape", _vmServiceScrapeReady)
    spec = {
        selector = {matchLabels = _appLabels}
        endpoints = [{port = "http", path = "/metrics", interval = oxr.spec.observability?.metrics?.interval or "30s", scrapeTimeout = "10s"}]
    }
}]
_items += _vmServiceScrape

# Default per-model SLO group; override via spec.observability.alertingRules.groups.
# `for` is a KCL reserved keyword — must be a quoted dict key in rule entries.
_coldStartRule = {
    alert = "InferenceServiceColdStartBudgetExceeded"
    # vLLM exposes time_to_first_token_seconds (TTFT) — captures model-load
    # + first-inference latency, which is the cold-start budget per FR-005.
    # End-to-end request latency includes output length, not appropriate here.
    expr = "histogram_quantile(0.95, sum by (le) (rate(vllm:time_to_first_token_seconds_bucket{model_name=\"" + _name + "\"}[5m]))) > 90"
    "for" = "10m"
    labels = {severity = "warning", model = _name}
    annotations = {summary = "Cold-start budget exceeded for " + _name, description = "p95 TTFT over 90s for the last 10m on " + _name + "."}
}
_errorRateRule = {
    alert = "InferenceServiceErrorRateHigh"
    # vLLM has no dedicated request_failure_total. Failures are counted as
    # request_success_total{finished_reason="abort"} alongside successes.
    expr = "sum(rate(vllm:request_success_total{model_name=\"" + _name + "\",finished_reason=\"abort\"}[10m])) / sum(rate(vllm:request_success_total{model_name=\"" + _name + "\"}[10m])) > 0.05"
    "for" = "10m"
    labels = {severity = "critical", model = _name}
    annotations = {summary = "Abort rate > 5% on " + _name, description = "vllm:request_success_total{finished_reason=\"abort\"} share exceeded 5% for 10m on " + _name + "."}
}
_vmRule = [{
    apiVersion = "operator.victoriametrics.com/v1beta1"
    kind = "VMRule"
    metadata = _metadata("vmrule", _vmRuleReady)
    spec = {
        groups = oxr.spec.observability?.alertingRules?.groups or [{name = _name + "-slo", rules = [_coldStartRule, _errorRateRule]}]
    }
}]
_items += _vmRule

# Preload Job (CL-3 rec A) — composition renders one when model.preload.enabled.
# Self-healing idempotency: both `huggingface-cli download` (HF cache hits)
# and `aws s3 sync` (size + etag diff) skip files that already match the
# remote, so partial uploads from a previously-killed Job heal on the next
# run. The earlier `aws s3 ls | grep config.json` precheck was brittle —
# config.json present + safetensors chunks missing would have starved the
# inference pod's init container at runtime.
# KCL triple-quoted strings interpolate `${...}`, so the embedded shell
# uses POSIX `$VAR` form.
if _preloadEnabled:
    # Per ADR-0004: preload Job downloads HuggingFace weights directly
    # to the shared S3 Files mount — same PVC the serving Deployment
    # uses, mounted with the same subPath. No `aws s3 sync` second step.
    # Idempotency: hf download skips files whose size+etag match.
    # `--max-workers 1` serializes downloads. The HF library uses a
    # filelock on `<dir>/.cache/huggingface/.gitignore.lock` to coordinate
    # concurrent file fetches; on S3 Files NFS the fcntl lock either
    # never releases or contention deadlocks, leaving 21 worker threads
    # all stuck on `Still waiting to acquire lock`. Single-threaded
    # downloads bypass the lock contention entirely.
    #
    # Two-tier short-circuit (avoids re-downloading multi-GB checkpoints
    # whenever the S3 Files filesystem is recreated against the same
    # bucket):
    #   1. Marker file `.preload-complete` matches `<repo>@<revision>` —
    #      fast path, no metadata calls.
    #   2. `config.json` already present AND no `.incomplete` files in the
    #      xet download cache — assume the bucket already holds a usable
    #      HuggingFace snapshot from a prior run (FS recreated, marker
    #      lost). Backfill the marker so future restarts hit the fast path.
    # Why the .incomplete guard: an earlier version short-circuited on
    # `config.json` alone, but `hf download` writes that tiny file FIRST
    # before the multi-GB shards. A pod that crashed/was killed mid-stream
    # left config.json + a 1.1GB *.incomplete xet shard, then the next
    # Job hit the fast path, recorded the marker, exited 0 — and vLLM
    # crashlooped on `vocab_file=None` because the shards never finished.
    # `hf download` is resumable, so we always run it when the cache is
    # in flight, accepting ~minutes of S3 Files checksum work as the
    # price of correctness.
    # Marker writes use `tmp + mv` so two concurrent Jobs racing on the
    # short-circuit can't observe a partially-written marker. POSIX
    # rename(2) is atomic on local FS and on NFSv4 (S3 Files speaks
    # NFSv4) for the same parent directory.
    # LoRA adapter downloads run AFTER base resolution. `hf download` is
    # naturally idempotent (skips files already present), so per-adapter
    # markers are unnecessary at this scale (<500 MB / adapter, 1-2
    # adapters). Both base-warm and base-cold paths reach this snippet via
    # the BASE_DONE flag below — earlier `exit 0` short-circuits removed.
    _loraDownloadCommands = ["hf download " + a.repository + " --revision " + (a.revision or "main") + " --local-dir /models/loras/" + a.name + " --max-workers 1" for a in _loraAdapters]

    # Snippet ALWAYS starts with `\n` so the preceding `fi` and the
    # following `echo '[preload] Done.'` stay on separate lines even when
    # _loraAdapters is empty. Without this, empty-adapter renders collapse
    # to `fiecho` — a single bash token, not a valid statement.
    _loraDownloadSnippet = ("\necho '[preload] Downloading LoRA adapters...'\nmkdir -p /models/loras\n" + "\n".join(_loraDownloadCommands) + "\n") if _loraAdapters else "\n"

    _preloadCommand = """set -euo pipefail
DIR="/models/""" + _modelRevision + """"
MARKER="$DIR/.preload-complete"
WANT=\"""" + _modelRepository + """@""" + _modelRevision + """\"
BASE_DONE=0
# `find` returns non-zero when the directory does not exist (fresh
# preload, never run before). Combined with `set -e -o pipefail` this
# would abort the script before we even reach `hf download`. Guard the
# call so a missing cache dir simply yields INCOMPLETE_COUNT=0.
if [ -d "$DIR/.cache/huggingface/download" ]; then
  INCOMPLETE_COUNT=$(find "$DIR/.cache/huggingface/download/" -maxdepth 1 -name '*.incomplete' | wc -l)
else
  INCOMPLETE_COUNT=0
fi
# `.incomplete` files trump every other signal: even a matching marker
# is wrong if the xet cache says a shard never finished. Earlier code
# baked a bad marker after a stalled download and the wrong marker
# would otherwise short-circuit forever — clean those up explicitly
# before the marker check.
if [ "$INCOMPLETE_COUNT" -gt 0 ]; then
  echo "[preload] $INCOMPLETE_COUNT .incomplete file(s) in xet cache — clearing stale marker, will resume download."
  rm -f "$MARKER"
elif [ -f "$MARKER" ] && [ "$(cat "$MARKER" 2>/dev/null)" = "$WANT" ]; then
  echo "[preload] $WANT already complete (marker) — skipping base download."
  BASE_DONE=1
elif [ -f "$DIR/config.json" ]; then
  echo "[preload] $WANT files already in bucket (config.json present, no .incomplete cache) — recording marker, skipping base download."
  printf '%s' "$WANT" > "$MARKER.tmp" && mv "$MARKER.tmp" "$MARKER" || true
  BASE_DONE=1
fi
export PATH="/tmp/pip/bin:$PATH"
export PYTHONPATH="/tmp/pip"
pip install --quiet --target /tmp/pip --upgrade --no-cache-dir huggingface_hub
if [ "$BASE_DONE" -ne 1 ]; then
  hf download """ + _modelRepository + """ --revision """ + _modelRevision + """ --local-dir "$DIR" --max-workers 1
  printf '%s' "$WANT" > "$MARKER.tmp" && mv "$MARKER.tmp" "$MARKER"
fi""" + _loraDownloadSnippet + """echo '[preload] Done.'
"""
    _preloadJob = [{
        apiVersion = "batch/v1"
        kind = "Job"
        metadata = _metadata("preload-job", _preloadJobReady) | {name = _name + "-preload-" + _modelRevision[0:8:]}
        spec = {
            backoffLimit = 3
            ttlSecondsAfterFinished = 86400
            template = {
                # `component=preload` switches the pod onto the broader
                # preload CNP (HF/world:443, AWS API, EKS PIA host:80).
                metadata = {labels = _preloadLabels}
                spec = {
                    serviceAccountName = _DEFAULTS.preload_sa
                    restartPolicy = "OnFailure"
                    securityContext = {seccompProfile = {type = "RuntimeDefault"}, runAsNonRoot = True, runAsUser = 1001, fsGroup = 1001}
                    volumes = [{name = "models", persistentVolumeClaim = {claimName = "llm-models"}}, {name = "tmp", emptyDir = {sizeLimit = _DEFAULTS.preload_tmp_size}}]
                    containers = [{
                        name = "preload"
                        # AWS ECR public mirror of docker.io/library/python.
                        # docker.io anonymous pull rate limit (100/6h/IP)
                        # surfaces under heavy reconcile churn.
                        image = "public.ecr.aws/docker/library/python:3.12-slim"
                        command = ["/bin/sh", "-c"]
                        args = [_preloadCommand]
                        securityContext = {seccompProfile = {type = "RuntimeDefault"}, allowPrivilegeEscalation = False, readOnlyRootFilesystem = True, runAsNonRoot = True, capabilities = {drop = ["ALL"]}}
                        resources = {requests = {cpu = "1", memory = "2Gi"}, limits = {cpu = "4", memory = "8Gi"}}
                        # HF_HUB_DISABLE_XET=1: bypass HF's xet/cas-bridge CDN
                        # and use the legacy LFS path. Xet's resumable-by-design
                        # protocol stalls on long-lived TCP streams from EKS
                        # (5+ minute idle hangs with no retry), leaving the
                        # preload Job stuck on a half-downloaded shard until
                        # backoffLimit is exhausted. LFS direct download is a
                        # straight HTTPS GET with predictable retry semantics.
                        # HF_HUB_DOWNLOAD_TIMEOUT=120: cap any single stream at
                        # 2min so a stalled connection fails-fast and the Python
                        # client retries instead of blocking forever.
                        env = [{name = "HF_HOME", value = "/tmp/.huggingface"}, {name = "HF_HUB_DISABLE_XET", value = "1"}, {name = "HF_HUB_DOWNLOAD_TIMEOUT", value = "120"}]
                        if _envFromList:
                            envFrom = _envFromList
                        # subPath isolates each claim's slice of the
                        # shared S3 Files filesystem — same path as the
                        # serving Deployment.
                        volumeMounts = [{name = "models", mountPath = "/models", subPath = _subPath}, {name = "tmp", mountPath = "/tmp"}]
                    }]
                }
            }
        }
    }]
    _items += _preloadJob

items = _items
