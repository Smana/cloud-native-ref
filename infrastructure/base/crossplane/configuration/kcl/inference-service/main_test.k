# Tests for InferenceService composition
# Run: kcl test . -Y settings-example.yaml

# ---- Test: Core resources always created ----
# Two CiliumNetworkPolicies render when preload is enabled — one tight
# policy for the long-lived serving Deployment and a broader one scoped
# to the one-shot preload Job (HF/world:443, AWS API, EKS PIA host:80).
test_core_resources = lambda {
    _oxr = option("params").oxr
    deployments = [r for r in items if r.kind == "Deployment"]
    services = [r for r in items if r.kind == "Service"]
    serviceAccounts = [r for r in items if r.kind == "ServiceAccount"]
    netpols = [r for r in items if r.kind == "CiliumNetworkPolicy"]
    scrapes = [r for r in items if r.kind == "VMServiceScrape"]
    rules = [r for r in items if r.kind == "VMRule"]
    _expectedNetpols = 2 if _oxr.spec.model?.preload?.enabled else 1
    assert len(deployments) == 1, "expected 1 Deployment, got {}".format(len(deployments))
    assert len(services) == 1, "expected 1 Service, got {}".format(len(services))
    assert len(serviceAccounts) == 1, "expected 1 ServiceAccount, got {}".format(len(serviceAccounts))
    assert len(netpols) == _expectedNetpols, "expected {} CiliumNetworkPolicy (default-deny mandate), got {}".format(_expectedNetpols, len(netpols))
    assert len(scrapes) == 1, "expected 1 VMServiceScrape, got {}".format(len(scrapes))
    assert len(rules) == 1, "expected 1 VMRule, got {}".format(len(rules))
}

# ---- Test: Resource count for full settings-example claim ----
# settings-example exercises: KEDA ScaledObject, HTTPRoute, ExternalSecret,
# preload Job, and (SPEC-002) the AI Gateway trio + canaries + XR status patch.
test_resource_count_full = lambda {
    # Full claim (settings-example) renders 11 base resources:
    # ServiceAccount, Deployment, Service, ScaledObject, HTTPRoute,
    # CiliumNetworkPolicy (serving), CiliumNetworkPolicy (preload),
    # ExternalSecret, VMServiceScrape, VMRule, Job = 11 — plus, with
    # gateway.enabled + canaries: Backend, AIServiceBackend, one
    # AIServiceBackend-canary-<i> per canary, AIGatewayRoute, and the dxr
    # status patch.
    assert len(items) >= 11, "expected ≥11 resources for full claim, got {}".format(len(items))
}

# ---- Test: Container security context (constitution mandate) ----
test_security_context = lambda {
    dep = [r for r in items if r.kind == "Deployment"][0]
    container = dep.spec.template.spec.containers[0]
    assert container.securityContext.allowPrivilegeEscalation == False, "allowPrivilegeEscalation must be False"
    assert container.securityContext.readOnlyRootFilesystem == True, "readOnlyRootFilesystem must be True"
    assert container.securityContext.runAsNonRoot == True, "runAsNonRoot must be True"
    assert "ALL" in container.securityContext.capabilities.drop, "must drop ALL capabilities"
}

# ---- Test: Pod-level security context ----
test_pod_security_context = lambda {
    dep = [r for r in items if r.kind == "Deployment"][0]
    podSec = dep.spec.template.spec.securityContext
    assert podSec.runAsNonRoot == True, "pod runAsNonRoot must be True"
    assert podSec.seccompProfile.type == "RuntimeDefault", "seccompProfile must be RuntimeDefault"
}

# ---- Test: GPU resource request/limit set ----
test_gpu_resources = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    res = dep.spec.template.spec.containers[0].resources
    _expectedGpu = _oxr.spec.gpu.count
    assert res.requests["nvidia.com/gpu"] == _expectedGpu, "GPU request mismatch"
    assert res.limits["nvidia.com/gpu"] == _expectedGpu, "GPU limit mismatch"
}

# ---- Test: GPU toleration + nodeSelector ----
test_gpu_scheduling = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    podSpec = dep.spec.template.spec
    assert podSpec.nodeSelector["karpenter.sh/nodepool"] == (_oxr.spec.nodePool or "gpu-l4"), "nodeSelector must target GPU NodePool"
    _tolerations = [t for t in podSpec.tolerations if t.key == "nvidia.com/gpu"]
    assert len(_tolerations) == 1, "expected GPU toleration"
}

# ---- Test: Deployment has no replicas field — KEDA always controls it ----
# Composition v0.5.0 always renders a ScaledObject; the Deployment spec.replicas
# field is omitted unconditionally so KEDA owns the replica count.
test_no_replicas_field = lambda {
    dep = [r for r in items if r.kind == "Deployment"][0]
    assert not dep.spec.replicas, "Deployment must not set replicas — KEDA ScaledObject controls scaling"
}

# ---- Test: KEDA ScaledObject with prometheus-leading triggers ----
# v0.5.0 SPEC-001: replaces HTTPScaledObject + HPA-on-CPU with a single
# ScaledObject. Two prometheus triggers, OR-combined: running/max-num-seqs
# ratio (leading: scale before batch saturates) and gpu_cache_usage_perc
# (leading: catches long-context bursts that running-count misses).
test_scaledobject_prometheus_triggers = lambda {
    _oxr = option("params").oxr
    sos = [r for r in items if r.kind == "ScaledObject"]
    assert len(sos) == 1, "expected exactly 1 ScaledObject, got {}".format(len(sos))
    so = sos[0]
    assert so.apiVersion == "keda.sh/v1alpha1", "ScaledObject apiVersion must be keda.sh/v1alpha1"
    assert so.spec.minReplicaCount == (_oxr.spec.scaling?.minReplicas or 1), "minReplicaCount mismatch"
    assert so.spec.maxReplicaCount == (_oxr.spec.scaling?.maxReplicas or 3), "maxReplicaCount mismatch"
    assert so.spec.pollingInterval == (_oxr.spec.scaling?.pollingIntervalSeconds or 15), "pollingInterval mismatch"
    assert so.spec.cooldownPeriod == (_oxr.spec.scaling?.cooldownSeconds or 300), "cooldownPeriod mismatch"
    triggers = so.spec.triggers
    assert len(triggers) == 2, "expected exactly 2 prometheus triggers (running ratio + cache util), got {}".format(len(triggers))
    _runningTriggers = [t for t in triggers if "num_requests_running" in (t?.metadata?.query or "")]
    _cacheTriggers = [t for t in triggers if "gpu_cache_usage_perc" in (t?.metadata?.query or "")]
    assert len(_runningTriggers) == 1, "expected exactly 1 running-ratio trigger, got {}".format(len(_runningTriggers))
    assert len(_cacheTriggers) == 1, "expected exactly 1 cache-util trigger, got {}".format(len(_cacheTriggers))
    assert _runningTriggers[0].metadata.threshold == (_oxr.spec.scaling?.runningRatioThreshold or "0.7"), "running ratio threshold mismatch"
    assert _cacheTriggers[0].metadata.threshold == (_oxr.spec.scaling?.cacheUtilizationThreshold or "0.6"), "cache util threshold mismatch"
}

# ---- Test: vLLM container args carry --max-num-seqs ----
# Required so the running-ratio trigger has a known denominator.
test_vllm_max_num_seqs = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    container = dep.spec.template.spec.containers[0]
    _args = container.args or []
    _expected = str(_oxr.spec.model?.maxNumSeqs or 64)
    _idx = [i for i in range(len(_args)) if _args[i] == "--max-num-seqs"]
    assert len(_idx) == 1, "vLLM args must contain --max-num-seqs exactly once"
    assert _args[_idx[0] + 1] == _expected, "vLLM --max-num-seqs value must match spec.model.maxNumSeqs"
}

# ---- Test: HTTPRoute when route.enabled ----
test_httproute = lambda {
    _oxr = option("params").oxr
    routes = [r for r in items if r.kind == "HTTPRoute"]
    if _oxr.spec.route?.enabled:
        assert len(routes) == 1, "expected 1 HTTPRoute"
        assert routes[0].spec.hostnames, "HTTPRoute must have hostnames"
        assert routes[0].spec.parentRefs[0].name == (_oxr.spec.route.parentGateway or "platform-tailscale-general"), "parent gateway mismatch"
    else:
        assert len(routes) == 0, "expected 0 HTTPRoutes when disabled"
    assert True
}

# ---- Test: CiliumNetworkPolicy is default-deny + explicit allow ----
test_network_policy_default_deny = lambda {
    netpol = [r for r in items if r.kind == "CiliumNetworkPolicy"][0]
    # endpointSelector must scope only to this app (not empty match-all)
    assert netpol.spec.endpointSelector.matchLabels["app.kubernetes.io/name"], "endpointSelector must target this app"
    # Explicit allows must exist (default-deny + allow pattern, not empty rules)
    assert netpol.spec.ingress, "ingress rules must be present (default-deny + explicit allow)"
    assert netpol.spec.egress, "egress rules must be present (default-deny + explicit allow)"
}

# ---- Test: per-claim EPI dropped (ADR-0004) ----
test_epi_for_s3 = lambda {
    epis = [r for r in items if r.kind == "EPI"]

    # Per ADR-0004: serving pods access weights via CSI mount, not S3 API.
    # The CSI driver has its own IAM (managed by opentofu/llm-platform/iam.tf,
    # bound to kube-system/efs-csi-controller-sa via EKS Pod Identity).
    assert len(epis) == 0, "InferenceService composition no longer renders per-claim EPI"
    assert True
}

# ---- Test: ExternalSecrets count matches spec ----
test_external_secrets = lambda {
    _oxr = option("params").oxr
    extSecrets = [r for r in items if r.kind == "ExternalSecret"]
    _expected = len(_oxr.spec.externalSecrets) if _oxr.spec.externalSecrets else 0
    assert len(extSecrets) == _expected, "expected {} ExternalSecrets, got {}".format(_expected, len(extSecrets))
}

# ---- Test: Preload Job (CL-3 rec A) ----
test_preload_job = lambda {
    _oxr = option("params").oxr
    jobs = [r for r in items if r.kind == "Job"]

    # Per ADR-0004: preload Job depends on model.preload.enabled only;
    # weightsFileSystem.id/accessPointId are now schema-required (XRD).
    if _oxr.spec.model?.preload?.enabled:
        assert len(jobs) == 1, "expected 1 preload Job when model.preload.enabled"
        assert "preload" in jobs[0].metadata.name, "Job name must include preload"
    else:
        assert len(jobs) == 0, "expected 0 Jobs when preload disabled"
    assert True
}

# ---- Test: xplane-* prefix on composition-managed resources (constitution mandate) ----
# ExternalSecrets are user-named (referenced by app envFrom) — exempted, matching App composition pattern
test_xplane_naming = lambda {
    _name = option("params").oxr.metadata.name
    _bad = [r.kind + "/" + r.metadata.name for r in items if r.kind != "ExternalSecret" and not r.metadata.name.startswith(_name)]
    assert len(_bad) == 0, "composition-managed resources must be named with claim prefix '{}': {}".format(_name, _bad)
}

# ---- Test: composition-resource-name annotations on every resource ----
# The composite XR itself (kind InferenceService, returned to patch
# status.modelEndpoint per SPEC-002) is not a composed resource and carries
# no composition-resource-name — excluded here.
test_composition_annotations = lambda {
    _bad = [r.kind + "/" + r.metadata.name for r in items if r.kind != "InferenceService" and not r.metadata?.annotations?["krm.kcl.dev/composition-resource-name"]]
    assert len(_bad) == 0, "resources missing composition-resource-name annotation: {}".format(_bad)
}

# ---- Test: All resources in correct namespace ----
test_namespace_consistency = lambda {
    _ns = option("params").oxr.metadata.namespace
    _bad = [r.kind + "/" + r.metadata.name for r in items if r.metadata.namespace and r.metadata.namespace != _ns]
    assert len(_bad) == 0, "resources in wrong namespace: {}".format(_bad)
}

# ---- Test: Deployment uses Recreate strategy (GPUs are scarce) ----
test_recreate_strategy = lambda {
    dep = [r for r in items if r.kind == "Deployment"][0]
    assert dep.spec.strategy.type == "Recreate", "GPU pods must use Recreate (not RollingUpdate) — surge would block"
}

# ---- Test: claim-named resources use exact claim name (not <claim>-<suffix>) ----
# Service / Deployment / KEDA scaleTargetRef / HTTPRoute backendRefs all
# address each other by the claim name; suffixed names break those references.
# CiliumNetworkPolicy is selector-based (matchLabels), not name-addressed,
# so the preload CNP intentionally uses `<claim>-preload` to coexist with
# the serving CNP — both kinds are excluded from this test.
test_claim_named_resources = lambda {
    _name = option("params").oxr.metadata.name
    _claimNamed = ["Deployment", "Service", "ServiceAccount", "ScaledObject", "HTTPRoute", "VMServiceScrape", "VMRule"]
    _bad = [r.kind + "/" + r.metadata.name for r in items if r.kind in _claimNamed and r.metadata.name != _name]
    assert len(_bad) == 0, "claim-named resources must use exact claim name '{}': {}".format(_name, _bad)
}

# ---- Test: _defaultIngress allows AI Gateway data plane (no longer KEDA interceptor) ----
# Regression guard for the AI-gateway allow in _defaultIngress. v0.5.0 (SPEC-001)
# drops the keda-interceptor allow because traffic now goes envoy-gateway-system
# direct to vLLM (no proxy hop). Without the AI Gateway allow, traffic lands on
# Cilium's default-deny and silently drops. Skips when the claim overrides
# networkPolicies (composition defaults don't apply there). Filters to the
# serving CNP (claim-named); the preload CNP uses a different selector.
test_default_ingress_ai_gateway = lambda {
    _name = option("params").oxr.metadata.name
    if not option("params").oxr.spec.networkPolicies?.ingress:
        _servingCnps = [r for r in items if r.kind == "CiliumNetworkPolicy" and r.metadata.name == _name]
        assert len(_servingCnps) == 1, "expected exactly 1 serving CiliumNetworkPolicy named '{}', got {}".format(_name, len(_servingCnps))
        _ingressFroms = sum([r.fromEndpoints for r in _servingCnps[0].spec.ingress], [])
        _aiGatewayCount = len([f for f in _ingressFroms if f?.matchLabels?["gateway.envoyproxy.io/owning-gateway-name"] == "ai-gateway"])
        assert _aiGatewayCount == 1, "expected AI Gateway data plane fromEndpoints (matchLabels.owning-gateway-name=ai-gateway), got {}".format(_aiGatewayCount)
        _interceptorCount = len([f for f in _ingressFroms if f?.matchLabels?["app.kubernetes.io/component"] == "interceptor" and f?.matchLabels?["io.kubernetes.pod.namespace"] == "keda"])
        assert _interceptorCount == 0, "v0.5.0 must not allow keda-interceptor (proxy removed from data path), got {}".format(_interceptorCount)

    assert True
}

# ---- Test: serving CNP has no `toEntities: world` egress; preload CNP has it ----
# H4 fix — the broad world:443 egress (HF/PyPI for preload weight pulls)
# must not leak onto the long-lived serving Deployment.
test_egress_split_serving_vs_preload = lambda {
    _oxr = option("params").oxr
    _name = _oxr.metadata.name
    _servingCnps = [r for r in items if r.kind == "CiliumNetworkPolicy" and r.metadata.name == _name]
    if not _oxr.spec.networkPolicies?.egress:
        _servingEgressEntities = sum([rule?.toEntities or [] for rule in _servingCnps[0].spec.egress], [])
        assert "world" not in _servingEgressEntities, "serving CNP must NOT include toEntities: world (only the preload Job needs that)"

    if _oxr.spec.model?.preload?.enabled:
        _preloadCnps = [r for r in items if r.kind == "CiliumNetworkPolicy" and r.metadata.name == _name + "-preload"]
        assert len(_preloadCnps) == 1, "expected exactly 1 preload CiliumNetworkPolicy"
        _preloadEgressEntities = sum([rule?.toEntities or [] for rule in _preloadCnps[0].spec.egress], [])
        assert "world" in _preloadEgressEntities, "preload CNP must include toEntities: world for HF/PyPI egress"
        assert "host" in _preloadEgressEntities, "preload CNP must include toEntities: host for EKS Pod Identity Agent"

    assert True
}

# ---- Test: legacy KEDA HTTP add-on / HPA-on-CPU resources removed ----
# v0.5.0 (SPEC-001): removed HTTPScaledObject and HPA. The new ScaledObject
# (asserted by test_scaledobject_prometheus_triggers above) is the sole
# autoscaler. This test guards against regression where one of the legacy
# Kinds reappears.
test_no_legacy_scaling_resources = lambda {
    httpScaledObjects = [r for r in items if r.kind == "HTTPScaledObject"]
    hpas = [r for r in items if r.kind == "HorizontalPodAutoscaler"]
    assert len(httpScaledObjects) == 0, "expected 0 HTTPScaledObjects in v0.5.0 (replaced by ScaledObject), got {}".format(len(httpScaledObjects))
    assert len(hpas) == 0, "expected 0 HorizontalPodAutoscalers in v0.5.0 (replaced by ScaledObject), got {}".format(len(hpas))
}

# ---- Test: vLLM args reflect loraAdapters ----
# vLLM args reflect loraAdapters. Conditional pattern matches test_core_resources
# (line 16) — assertions adapt to what the test fixture sets.
#   loraAdapters non-empty: --enable-lora + --max-loras N + --max-lora-rank 64
#                           + --lora-modules <name>=/models/loras/<name> per adapter.
#   loraAdapters empty/absent: none of the LoRA flags present.
# Real claims that don't set loraAdapters (qwen3-8b, qwen-coder-fim, llamaguard)
# are regression-checked at Flux render / kubeconform time.
test_lora_args_conditional = lambda {
    _oxr = option("params").oxr
    deployments = [r for r in items if r.kind == "Deployment"]
    assert len(deployments) == 1
    args = deployments[0].spec.template.spec.containers[0].args
    _adapters = _oxr.spec?.loraAdapters or []
    if len(_adapters) > 0:
        assert "--enable-lora" in args, "expected --enable-lora when loraAdapters non-empty"
        assert "--max-loras" in args, "expected --max-loras when loraAdapters non-empty"
        assert str(len(_adapters)) in args, "expected --max-loras N where N == len(adapters)"
        assert "--max-lora-rank" in args, "expected --max-lora-rank"
        assert "64" in args, "expected --max-lora-rank 64"
        assert "--lora-modules" in args, "expected --lora-modules"
        _missing = ["{}={}".format(a.name, "/models/loras/" + a.name) for a in _adapters if "{}={}".format(a.name, "/models/loras/" + a.name) not in args]
        assert len(_missing) == 0, "expected --lora-modules entries for every adapter, missing: {}".format(_missing)
    else:
        assert "--enable-lora" not in args, "must not emit --enable-lora when loraAdapters absent"
        assert "--lora-modules" not in args, "must not emit --lora-modules when loraAdapters absent"
        assert "--max-loras" not in args, "must not emit --max-loras when loraAdapters absent"
    assert True
}

# ---- Test: Preload Job extends to download LoRA adapters ----
# Preload Job extends to download each adapter from HF into
# /models/loras/<name>/. Idempotency comes from `hf download` — the CLI
# skips files already present locally. Conditional pattern: assertions
# adapt to what the fixture sets.
test_preload_lora_downloads_conditional = lambda {
    _oxr = option("params").oxr
    _adapters = _oxr.spec?.loraAdapters or []
    jobs = [r for r in items if r.kind == "Job"]
    if not _oxr.spec.model?.preload?.enabled:
        # Nothing to assert if preload is disabled at the claim level.
        assert True
    else:
        assert len(jobs) == 1, "expected 1 preload Job when preload enabled"
        cmd = jobs[0].spec.template.spec.containers[0].args[0]
        if len(_adapters) > 0:
            assert "/models/loras" in cmd, "preload command must reference /models/loras when loraAdapters non-empty"
            _missing = ["{}|{}|{}".format(a.name, a.repository, a.revision or "main") for a in _adapters if "/models/loras/" + a.name not in cmd or a.repository not in cmd or (a.revision or "main") not in cmd]
            assert len(_missing) == 0, "preload command missing entries (name|repo|rev): {}".format(_missing)
        else:
            assert "/models/loras" not in cmd, "must not reference /models/loras when loraAdapters absent"
    assert True
}

# ---- Test (a/b): AI Gateway trio rendered iff gateway.enabled ----
# Backend <claim>-direct, AIServiceBackend(s), AIGatewayRoute <claim>.
# Conditional pattern mirrors test_httproute — assertions adapt to the
# fixture. The fixture's Deployment is NOT Available but the route is present
# in ocds, so the latched AIGatewayRoute still renders (see settings-example).
test_gateway_resources = lambda {
    _oxr = option("params").oxr
    _name = _oxr.metadata.name
    _ns = _oxr.metadata.namespace
    backends = [r for r in items if r.kind == "Backend"]
    aisbs = [r for r in items if r.kind == "AIServiceBackend"]
    routes = [r for r in items if r.kind == "AIGatewayRoute"]
    if _oxr.spec.gateway?.enabled:
        assert len(backends) == 1, "expected 1 Backend, got {}".format(len(backends))
        assert backends[0].metadata.name == _name + "-direct", "Backend name must be <claim>-direct"
        assert backends[0].apiVersion == "gateway.envoyproxy.io/v1alpha1", "Backend apiVersion mismatch"
        assert backends[0].spec.endpoints[0].fqdn.hostname == _name + "." + _ns + ".svc.cluster.local", "Backend FQDN mismatch"
        assert len(aisbs) >= 1, "expected ≥1 AIServiceBackend, got {}".format(len(aisbs))
        assert aisbs[0].spec.schema.name == "OpenAI", "AIServiceBackend schema must be OpenAI"
        assert len(routes) == 1, "expected 1 AIGatewayRoute (fixture Deployment Available), got {}".format(len(routes))
        assert routes[0].metadata.name == _name, "AIGatewayRoute name must be the claim name"
        assert routes[0].spec.parentRefs[0].name == "ai-gateway", "parentRef must be ai-gateway"
        assert routes[0].spec.parentRefs[0].namespace == "envoy-ai-gateway-system", "parentRef namespace mismatch"
    else:
        assert len(backends) == 0, "no Backend when gateway disabled"
        assert len(aisbs) == 0, "no AIServiceBackend when gateway disabled"
        assert len(routes) == 0, "no AIGatewayRoute when gateway disabled"
    assert True
}

# ---- Test (c/d): AIGatewayRoute readiness latch decision (FR-002) ----
# Drives the ACTUAL decision function main.k calls (`_aiGatewayRouteShouldRender`)
# with synthetic ocds keyed under the REAL composition-resource-name — so the
# in-ocds branch exercises the exact `<claim>-gateway-airoute` key construction,
# not a re-implementation. KCL's single global fixture can only encode one ocds
# state through `items`, so the withheld case (c) is covered here via the real
# lambda; the render-when-latched case (b/d) is ALSO covered end-to-end through
# `items` by test_gateway_route_latch_integration below.
test_gateway_route_latch = lambda {
    _name = option("params").oxr.metadata.name
    _routeKey = _name + "-" + _gatewayRouteSuffix
    _emptyOcds = {}
    _ocdsWithRoute = {k: {
        Resource = {kind = "AIGatewayRoute"}
    } for k in [_routeKey]}
    # (c) withhold: Deployment not Available AND route absent from ocds.
    assert _aiGatewayRouteShouldRender(_name, _emptyOcds, False) == False, "route withheld until Deployment Available or route observed"
    # (d) latch: route observed under its real key ⇒ render even if Deployment down.
    assert _aiGatewayRouteShouldRender(_name, _ocdsWithRoute, False) == True, "observed route latches — never withdrawn on a Deployment blip"
    # Deployment Available renders regardless of ocds.
    assert _aiGatewayRouteShouldRender(_name, _emptyOcds, True) == True, "route renders when Deployment Available"
    assert _aiGatewayRouteShouldRender(_name, _ocdsWithRoute, True) == True, "route renders when both true"
    # Guard: a WRONG key must NOT satisfy the latch (proves the suffix is load-bearing).
    _wrongKeyOcds = {k: {} for k in [_name + "-httproute"]}
    assert _aiGatewayRouteShouldRender(_name, _wrongKeyOcds, False) == False, "an unrelated observed resource must not latch the AIGatewayRoute"
}

# ---- Test (b/d) integration: latch renders through the full pipeline ----
# End-to-end proof that the ocds observed-state lookup is wired to the render
# suffix. The settings-example fixture puts the Deployment in Available=False
# AND the AIGatewayRoute (Accepted=True) in ocds under `<claim>-gateway-airoute`.
# The route must therefore (1) still appear in `items` (latch, not deployment
# readiness) and (2) carry krm.kcl.dev/ready="True" (derived from the observed
# Accepted condition). If the observed-lookup suffix ever drifts from the render
# suffix, the route would vanish or lose its ready annotation and this fails —
# the exact regression the pure decision test cannot see.
test_gateway_route_latch_integration = lambda {
    _oxr = option("params").oxr
    _name = _oxr.metadata.name
    if _oxr.spec.gateway?.enabled:
        # Fixture precondition: Deployment is NOT Available — assert via the
        # module's own readiness variable, not a re-implementation of it.
        assert not _deploymentReady, "fixture precondition: Deployment must NOT be Available for the latch integration test"
        # Fixture precondition: the route IS already observed (real suffix constant).
        assert (_name + "-" + _gatewayRouteSuffix) in option("params").ocds, "fixture precondition: AIGatewayRoute must be present in ocds"
        routes = [r for r in items if r.kind == "AIGatewayRoute"]
        assert len(routes) == 1, "AIGatewayRoute must still render via the ocds latch when Deployment is not Available, got {}".format(len(routes))
        assert routes[0].metadata.annotations["krm.kcl.dev/ready"] == "True", "rendered route must carry ready annotation from observed Accepted=True — proves ocds key matches render suffix"

    assert True
}

# ---- Test (e): canary weights sum to 100 + modelNameOverride + -canary AISB ----
# Array form (canaries[]): the base rule carries one backendRef for the base
# model (weight = 100 − sum(weights)) plus one per canary entry, each with
# modelNameOverride = adapter name VERBATIM. Each canary also renders its own
# `<claim>-canary-<i>` AIServiceBackend.
test_gateway_canaries = lambda {
    _oxr = option("params").oxr
    _name = _oxr.metadata.name
    _canaries = _oxr.spec.gateway?.canaries or []
    if _canaries:
        routes = [r for r in items if r.kind == "AIGatewayRoute"]
        assert len(routes) == 1, "expected 1 AIGatewayRoute"
        _refs = routes[0].spec.rules[0].backendRefs
        assert len(_refs) == 1 + len(_canaries), "base rule must have 1 base + {} canary backendRefs, got {}".format(len(_canaries), len(_refs))
        _total = sum([ref.weight for ref in _refs], 0)
        assert _total == 100, "canary weights must sum to 100 (base retains remainder), got {}".format(_total)
        _baseRefs = [ref for ref in _refs if ref.name == _name]
        assert len(_baseRefs) == 1, "expected exactly 1 base-model backendRef"
        _expectedBaseWeight = 100 - sum([c.weightPercent for c in _canaries], 0)
        assert _baseRefs[0].weight == _expectedBaseWeight, "base weight must be 100 − sum(weights) = {}, got {}".format(_expectedBaseWeight, _baseRefs[0].weight)

        # Every canary entry maps to a distinct `-canary-<i>` backendRef + AISB,
        # carrying its adapter name verbatim as modelNameOverride.
        _i = [i for i in range(len(_canaries))]
        _missingRefs = [i for i in _i if len([ref for ref in _refs if ref.name == _name + "-canary-" + str(i) and ref?.modelNameOverride == _canaries[i].adapter and ref.weight == _canaries[i].weightPercent]) != 1]
        assert len(_missingRefs) == 0, "each canary must render a distinct backendRef with verbatim modelNameOverride + weight; missing/mismatched indices: {}".format(_missingRefs)
        _missingAisb = [i for i in _i if len([r for r in items if r.kind == "AIServiceBackend" and r.metadata.name == _name + "-canary-" + str(i)]) != 1]
        assert len(_missingAisb) == 0, "each canary must render a distinct -canary-<i> AIServiceBackend; missing indices: {}".format(_missingAisb)

    assert True
}

# ---- Test (e2): multi-canary split — 2 adapters (10 + 15) → base 75 ----
# The settings-example fixture carries two canaries; this test pins the exact
# arithmetic (base = 100 − 10 − 15 = 75) and asserts BOTH adapters land as
# distinct backendRefs with their adapter name VERBATIM as modelNameOverride.
test_gateway_multi_canary = lambda {
    _oxr = option("params").oxr
    _name = _oxr.metadata.name
    _canaries = _oxr.spec.gateway?.canaries or []
    if len(_canaries) >= 2:
        routes = [r for r in items if r.kind == "AIGatewayRoute"]
        assert len(routes) == 1, "expected 1 AIGatewayRoute"
        _refs = routes[0].spec.rules[0].backendRefs
        assert len(_refs) == 1 + len(_canaries), "base rule must carry base + one ref per canary"
        _baseRef = [ref for ref in _refs if ref.name == _name][0]
        _expectedBaseWeight = 100 - sum([c.weightPercent for c in _canaries], 0)
        assert _baseRef.weight == _expectedBaseWeight, "base weight must equal 100 − sum(weights)"
        # Adapter names appear VERBATIM as modelNameOverride (no prefix/transform).
        _overrides = [ref.modelNameOverride for ref in _refs if ref?.modelNameOverride]
        _missing = [c.adapter for c in _canaries if c.adapter not in _overrides]
        assert len(_missing) == 0, "every canary adapter must appear verbatim as a modelNameOverride, missing: {}".format(_missing)
        # Overridden names are the adapter names verbatim, never claim-prefixed.
        _prefixed = [o for o in _overrides if o.startswith(_name + "-canary")]
        assert len(_prefixed) == 0, "modelNameOverride must be the adapter name, never the -canary backend name: {}".format(_prefixed)

    assert True
}

# ---- Test (f): one pin rule per loraAdapters entry ----
# Every adapter (regardless of canary) gets a pin rule matching
# x-ai-eg-model == <claim>-<adapter> → base pod at weight 100.
test_gateway_pin_rules = lambda {
    _oxr = option("params").oxr
    _name = _oxr.metadata.name
    _adapters = _oxr.spec?.loraAdapters or []
    if _oxr.spec.gateway?.enabled:
        routes = [r for r in items if r.kind == "AIGatewayRoute"]
        assert len(routes) == 1, "expected 1 AIGatewayRoute"
        _rules = routes[0].spec.rules
        assert len(_rules) == 1 + len(_adapters), "expected {} rules (1 base + {} pins), got {}".format(1 + len(_adapters), len(_adapters), len(_rules))

        # Pin match value must equal the adapter name VERBATIM (no claim
        # prefix). Fixtures use fully-qualified adapter names so a reintroduced
        # `<claim>-<adapter>` concat would produce a clearly-wrong doubled value
        # and fail here.
        _pinValues = [rule.matches[0].headers[0].value for rule in _rules[1::]]
        _missing = [a.name for a in _adapters if a.name not in _pinValues]
        assert len(_missing) == 0, "missing pin rules (adapter name verbatim) for adapters: {}".format(_missing)
        _pinBackends = [rule.backendRefs[0].name for rule in _rules[1::]]
        _badBackends = [n for n in _pinBackends if n != _name]
        assert len(_badBackends) == 0, "pin rules must target the base pod ({}), got {}".format(_name, _badBackends)

    assert True
}

# ---- Test: XR status.modelEndpoint patched when gateway.enabled ----
# SPEC-003 FR-007: the dxr status patch always renders (servedModels /
# servedModelsSummary are unconditional). modelEndpoint is present ONLY when
# gateway.enabled. So the XR status patch itself is always in `items`.
test_gateway_status_endpoint = lambda {
    _oxr = option("params").oxr
    _composites = [r for r in items if r.kind == "InferenceService"]
    assert len(_composites) == 1, "expected exactly 1 XR status patch (always rendered), got {}".format(len(_composites))
    if _oxr.spec.gateway?.enabled:
        assert _composites[0].status.modelEndpoint == "https://llm.priv.cloud.ogenki.io/v1", "modelEndpoint mismatch"
    else:
        assert not _composites[0].status?.modelEndpoint, "modelEndpoint must be absent when gateway disabled"
    assert True
}

# ---- Test (T005): engineArgs appended verbatim and LAST ----
# SPEC-003 FR-001/FR-002; SC-001/SC-006. spec.engineArgs is a plain
# passthrough appended as the final slice of the vLLM args — composition-
# managed flags always precede user flags so a user cannot re-order or
# shadow a managed flag (admission CEL is the single enforcement point).
test_engine_args_appended_last = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    args = dep.spec.template.spec.containers[0].args
    _engineArgs = _oxr.spec?.engineArgs or []
    if len(_engineArgs) > 0:
        # Every engineArgs token appears, verbatim, in the SAME order, as the
        # tail slice of the container args.
        _tail = args[len(args) - len(_engineArgs)::]
        assert _tail == _engineArgs, "engineArgs must be appended verbatim as the LAST slice: expected tail {}, got {}".format(_engineArgs, _tail)

        # Managed-flags-still-win: every composition-managed token appears
        # strictly BEFORE the first engineArgs entry. The managed portion is
        # everything preceding the appended tail; assert the first engineArgs
        # entry does not appear anywhere in that managed prefix.
        _managedPrefix = args[0:len(args) - len(_engineArgs):]
        assert _engineArgs[0] not in _managedPrefix, "engineArgs must start strictly after all managed flags; first entry {} leaked into managed prefix".format(_engineArgs[0])
        # The known managed flags are all in the prefix (never after engineArgs).
        _managedFlags = ["--model", "--served-model-name", "--max-model-len", "--max-num-seqs", "--gpu-memory-utilization"]
        _leaked = [f for f in _managedFlags if f in _tail]
        assert len(_leaked) == 0, "managed flags must never appear in the engineArgs tail: {}".format(_leaked)

    assert True
}

# ---- Test (T005): empty/absent engineArgs ⇒ args identical to baseline ----
# SC-006: adding the engineArgs plumbing must not perturb the rendered args
# when engineArgs is unset. Proven against the REAL builder main.k uses
# (`_buildVllmArgs`), NOT by tail-stripping the same render — a bad fallback
# like `managed + (extra or ["--oops"])` would survive tail-stripping (the
# "--oops" would sit in the stripped tail) but fails `builder(managed, []) ==
# managed` here. Two independent proofs:
#   1. builder(managed, []) == managed exactly (empty engineArgs is a no-op).
#   2. the fixture render == builder(managed, fixture engineArgs) — the
#      rendered args ARE the builder output, so the module wires the builder
#      in (no divergent second assembly path).
test_engine_args_empty_is_baseline = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    args = dep.spec.template.spec.containers[0].args
    _engineArgs = _oxr.spec?.engineArgs or []

    # (1) Absent-engineArgs proof: the builder with extra=[] returns the
    # managed prefix VERBATIM — this is exactly what a claim with no
    # engineArgs renders. A `or ["--oops"]`-style fallback breaks this.
    _emptyBuild = _buildVllmArgs(_managedVllmArgs, [])
    assert _emptyBuild == _managedVllmArgs, "builder([]) must equal the managed prefix exactly (absent engineArgs is a no-op): got {}".format(_emptyBuild)

    # The managed prefix is itself a valid, complete managed arg list.
    assert _managedVllmArgs[0] == "--model", "managed prefix must start with --model"
    _smnIdx = [i for i in range(len(_managedVllmArgs)) if _managedVllmArgs[i] == "--served-model-name"]
    assert len(_smnIdx) == 1, "managed prefix must carry exactly one --served-model-name"
    assert _managedVllmArgs[_smnIdx[0] + 1] == _oxr.metadata.name, "served-model-name must be the claim name"

    # (2) The fixture render IS the builder output — proves main.k uses the
    # builder for the real args, so proof (1) actually governs the render.
    assert args == _buildVllmArgs(_managedVllmArgs, _engineArgs), "rendered args must equal builder(managed, engineArgs) — the module must wire the builder in"

    # No user token (first engineArg) leaked into the managed prefix.
    if len(_engineArgs) > 0:
        assert _engineArgs[0] not in _managedVllmArgs, "engineArgs must not perturb the managed baseline"

    assert True
}

# ---- Test (T006): servedModels topology projection ----
# SPEC-003 FR-005; SC-004. status.servedModels = base entry (kind=base) +
# one entry per loraAdapters[] (kind=adapter). canaryWeightPercent is present
# ONLY on canary-targeted adapters and equals the canary weightPercent;
# absent (key not present) on the base entry and on non-canaried adapters.
test_served_models_shape = lambda {
    _oxr = option("params").oxr
    _name = _oxr.metadata.name
    xr = [r for r in items if r.kind == "InferenceService"][0]
    served = xr.status.servedModels
    _adapters = _oxr.spec?.loraAdapters or []
    _canaries = _oxr.spec.gateway?.canaries or []
    _canaryWeightByAdapter = {c.adapter: c.weightPercent for c in _canaries}

    # Count: base + one per adapter.
    assert len(served) == 1 + len(_adapters), "servedModels must be base + one per adapter = {}, got {}".format(1 + len(_adapters), len(served))

    # Base entry: kind=base, name=claim, NO canaryWeightPercent key.
    _base = [m for m in served if m.kind == "base"]
    assert len(_base) == 1, "exactly one base entry, got {}".format(len(_base))
    assert _base[0].name == _name, "base name must be the claim name"
    assert "canaryWeightPercent" not in _base[0], "base entry must NOT carry canaryWeightPercent"

    # Membership: every loraAdapter name appears in servedModels.
    _servedNames = [m.name for m in served]
    _missingAdapters = [a.name for a in _adapters if a.name not in _servedNames]
    assert len(_missingAdapters) == 0, "every loraAdapter must appear in servedModels: {}".format(_missingAdapters)

    # Each adapter entry: kind=adapter, canaryWeightPercent present IFF the
    # adapter is canary-targeted, and equal to the canary weight when present.
    _adapterEntries = [m for m in served if m.kind == "adapter"]
    # Canaried adapters must carry the key with the exact canary weight.
    _badCanaried = [m.name for m in _adapterEntries if m.name in _canaryWeightByAdapter and ("canaryWeightPercent" not in m or m.canaryWeightPercent != _canaryWeightByAdapter[m.name])]
    assert len(_badCanaried) == 0, "canaried adapters must carry canaryWeightPercent == canary weight; wrong: {}".format(_badCanaried)
    # Non-canaried adapters must NOT carry the key at all (absent, not null).
    _badPlain = [m.name for m in _adapterEntries if m.name not in _canaryWeightByAdapter and "canaryWeightPercent" in m]
    assert len(_badPlain) == 0, "non-canaried adapters must NOT carry a canaryWeightPercent key: {}".format(_badPlain)

    # Names match the rendered AIGatewayRoute canary modelNameOverride values.
    if _oxr.spec.gateway?.enabled and _canaries:
        routes = [r for r in items if r.kind == "AIGatewayRoute"]
        _overrides = [ref.modelNameOverride for ref in routes[0].spec.rules[0].backendRefs if ref?.modelNameOverride]
        _canariedServed = [m.name for m in served if "canaryWeightPercent" in m]
        _mismatch = [n for n in _canariedServed if n not in _overrides]
        assert len(_mismatch) == 0, "canaried servedModels names must match AIGatewayRoute modelNameOverride values: {}".format(_mismatch)

    assert True
}

# ---- Test (T006): servedModelsSummary is the comma-joined servedModels names ----
# CL-5 deviation: status.servedModelsSummary = ",".join([m.name for m in servedModels]).
test_served_models_summary = lambda {
    xr = [r for r in items if r.kind == "InferenceService"][0]
    served = xr.status.servedModels
    summary = xr.status.servedModelsSummary
    _expected = ",".join([m.name for m in served])
    assert summary == _expected, "servedModelsSummary must be the comma-joined servedModels names: expected {}, got {}".format(_expected, summary)
    assert True
}
