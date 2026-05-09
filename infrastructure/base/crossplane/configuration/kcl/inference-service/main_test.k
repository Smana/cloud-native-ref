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
# settings-example exercises: KEDA ScaledObject, HTTPRoute, ExternalSecret, preload Job
test_resource_count_full = lambda {
    # Full claim (settings-example) renders 11 resources:
    # ServiceAccount, Deployment, Service, ScaledObject, HTTPRoute,
    # CiliumNetworkPolicy (serving), CiliumNetworkPolicy (preload),
    # ExternalSecret, VMServiceScrape, VMRule, Job = 11
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
test_composition_annotations = lambda {
    _bad = [r.kind + "/" + r.metadata.name for r in items if not r.metadata?.annotations?["krm.kcl.dev/composition-resource-name"]]
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
