# Tests for App composition
# Run: kcl test . -Y settings-example.yaml

# ---- Test: Core resources always created (Deployment, Service, ServiceAccount) ----
test_core_resources = lambda {
    deployments = [r for r in items if r.kind == "Deployment"]
    services = [r for r in items if r.kind == "Service"]
    serviceAccounts = [r for r in items if r.kind == "ServiceAccount"]
    assert len(deployments) == 1, "expected 1 Deployment, got {}".format(len(deployments))
    assert len(services) == 1, "expected 1 Service, got {}".format(len(services))
    assert len(serviceAccounts) == 1, "expected 1 ServiceAccount, got {}".format(len(serviceAccounts))
}

# ---- Test: Deployment image configuration ----
test_deployment_image = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    container = dep.spec.template.spec.containers[0]
    _expectedImage = _oxr.spec.image.repository + ":" + (_oxr.spec.image.tag or "latest")
    assert container.image == _expectedImage, "expected image {}, got {}".format(_expectedImage, container.image)
}

# ---- Test: Security context defaults ----
test_security_context = lambda {
    dep = [r for r in items if r.kind == "Deployment"][0]
    container = dep.spec.template.spec.containers[0]
    assert container.securityContext.allowPrivilegeEscalation == False, "allowPrivilegeEscalation should be False"
    assert container.securityContext.readOnlyRootFilesystem == True, "readOnlyRootFilesystem should be True"
    assert container.securityContext.runAsNonRoot == True, "runAsNonRoot should be True"
    assert "ALL" in container.securityContext.capabilities.drop, "should drop ALL capabilities"
}

# ---- Test: Autoscaling creates HPA ----
test_autoscaling_hpa = lambda {
    _oxr = option("params").oxr
    hpas = [r for r in items if r.kind == "HorizontalPodAutoscaler"]
    if _oxr.spec.autoscaling?.enabled:
        assert len(hpas) == 1, "expected 1 HPA when autoscaling enabled"
        assert hpas[0].spec.minReplicas == _oxr.spec.autoscaling.minReplicas, "HPA minReplicas mismatch"
        assert hpas[0].spec.maxReplicas == _oxr.spec.autoscaling.maxReplicas, "HPA maxReplicas mismatch"
    else:
        assert len(hpas) == 0, "expected 0 HPAs when autoscaling disabled"
    assert True
}

# ---- Test: No replicas field when autoscaling enabled ----
test_no_replicas_with_autoscaling = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    if _oxr.spec.autoscaling?.enabled:
        assert not dep.spec.replicas, "Deployment should not set replicas when autoscaling is enabled"

    assert True
}

# ---- Test: PDB created when enabled ----
test_pdb = lambda {
    _oxr = option("params").oxr
    pdbs = [r for r in items if r.kind == "PodDisruptionBudget"]
    if _oxr.spec.pdb?.enabled:
        assert len(pdbs) == 1, "expected 1 PDB"
    else:
        assert len(pdbs) == 0, "expected 0 PDBs when disabled"
    assert True
}

# ---- Test: HTTPRoute created when route enabled ----
test_httproute = lambda {
    _oxr = option("params").oxr
    routes = [r for r in items if r.kind == "HTTPRoute"]
    if _oxr.spec.route?.enabled:
        assert len(routes) == 1, "expected 1 HTTPRoute"
        assert routes[0].spec.hostnames, "HTTPRoute should have hostnames"
    else:
        assert len(routes) == 0, "expected 0 HTTPRoutes when disabled"
    assert True
}

# ---- Test: Gateway created when enabled ----
test_gateway = lambda {
    _oxr = option("params").oxr
    gateways = [r for r in items if r.kind == "Gateway"]
    if _oxr.spec.gateway?.enabled:
        assert len(gateways) == 1, "expected 1 Gateway"
    else:
        assert len(gateways) == 0, "expected 0 Gateways when disabled"
    assert True
}

# ---- Test: CiliumNetworkPolicy created when enabled ----
test_network_policy = lambda {
    _oxr = option("params").oxr
    netpols = [r for r in items if r.kind == "CiliumNetworkPolicy"]
    if _oxr.spec.networkPolicies?.enabled:
        assert len(netpols) == 1, "expected 1 CiliumNetworkPolicy"
    else:
        assert len(netpols) == 0, "expected 0 CiliumNetworkPolicies when disabled"
    assert True
}

# ---- Test: KV Store creates HelmRelease ----
test_kvstore = lambda {
    _oxr = option("params").oxr
    helmReleases = [r for r in items if r.kind == "HelmRelease"]
    if _oxr.spec.kvStore?.enabled:
        assert len(helmReleases) == 1, "expected 1 HelmRelease for kvStore"
    else:
        assert len(helmReleases) == 0, "expected 0 HelmReleases when kvStore disabled"
    assert True
}

# ---- Test: SQL Instance creates SQLInstance XR ----
test_sql_instance = lambda {
    _oxr = option("params").oxr
    sqls = [r for r in items if r.kind == "SQLInstance"]
    if _oxr.spec.sqlInstance?.enabled:
        assert len(sqls) == 1, "expected 1 SQLInstance"
        assert sqls[0].apiVersion == "cloud.ogenki.io/v1alpha1"
    else:
        assert len(sqls) == 0, "expected 0 SQLInstances when disabled"
    assert True
}

# ---- Test: S3 Bucket creates Bucket + EPI ----
test_s3_bucket = lambda {
    _oxr = option("params").oxr
    buckets = [r for r in items if r.kind == "Bucket"]
    epis = [r for r in items if r.kind == "EPI"]
    if _oxr.spec.s3Bucket?.enabled:
        assert len(buckets) == 1, "expected 1 S3 Bucket"
        assert len(epis) == 1, "expected 1 EPI for S3 access"
    else:
        assert len(buckets) == 0, "expected 0 Buckets when disabled"
    assert True
}

# ---- Test: External Secrets ----
test_external_secrets = lambda {
    _oxr = option("params").oxr
    extSecrets = [r for r in items if r.kind == "ExternalSecret"]
    _expectedCount = len(_oxr.spec.externalSecrets) if _oxr.spec.externalSecrets else 0
    assert len(extSecrets) == _expectedCount, "expected {} ExternalSecrets, got {}".format(_expectedCount, len(extSecrets))
}

# ---- Test: Composition-resource-name annotations on all resources ----
test_composition_annotations = lambda {
    _name = option("params").oxr.metadata.name
    _bad = [r.kind + "/" + r.metadata.name for r in items if not r.metadata?.annotations?["krm.kcl.dev/composition-resource-name"]]
    assert len(_bad) == 0, "resources missing composition-resource-name annotation: {}".format(_bad)
}

# ---- Test: All resources in correct namespace ----
test_namespace_consistency = lambda {
    _ns = option("params").oxr.metadata.namespace
    _bad = [r.kind + "/" + r.metadata.name for r in items if r.metadata.namespace and r.metadata.namespace != _ns]
    assert len(_bad) == 0, "resources in wrong namespace: {}".format(_bad)
}

# ---- Test: Observability VMServiceScrape ----
test_observability_metrics = lambda {
    _oxr = option("params").oxr
    scrapes = [r for r in items if r.kind == "VMServiceScrape"]
    if _oxr.spec.observability?.metrics?.enabled:
        assert len(scrapes) == 1, "expected 1 VMServiceScrape"
    else:
        assert len(scrapes) == 0, "expected 0 VMServiceScrapes when metrics disabled"
    assert True
}

# ============================================================================
# SPEC-007 tests
# ============================================================================

# ---- Test: main container command/args plumbed (SPEC-007 T007) ----
test_main_command_args = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    c = dep.spec.template.spec.containers[0]
    if _oxr.spec?.command:
        assert c.command == _oxr.spec.command, "main container command should match spec.command"

    if _oxr.spec?.args:
        assert c.args == _oxr.spec.args, "main container args should match spec.args"

    assert True
}

# ---- Test: imagePullSecrets + terminationGracePeriodSeconds (SPEC-007 T009) ----
test_pod_lifecycle_fields = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    pod = dep.spec.template.spec
    if _oxr.spec?.imagePullSecrets:
        _expected = [{name = s} for s in _oxr.spec.imagePullSecrets]
        assert pod.imagePullSecrets == _expected, "imagePullSecrets should be [{name: ...}] shaped"

    if _oxr.spec?.terminationGracePeriodSeconds != None:
        assert pod.terminationGracePeriodSeconds == _oxr.spec.terminationGracePeriodSeconds, "terminationGracePeriodSeconds mismatch"

    assert True
}

# ---- Test: sidecars appended with full security defaults + override wins ----
test_sidecars_security = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    containers = dep.spec.template.spec.containers
    _sidecarSpecs = _oxr.spec.sidecars or []
    # main container + one container per sidecar, main first
    assert len(containers) == 1 + len(_sidecarSpecs), "expected {} containers (main + {} sidecars), got {}".format(1 + len(_sidecarSpecs), len(_sidecarSpecs), len(containers))
    assert containers[0].name == _oxr.metadata.name, "main container must be first"
    # Sidecars occupy the tail of the containers list, in order.
    _sidecarContainers = containers[1::]
    _names = [c.name for c in _sidecarContainers]
    assert _names == [s.name for s in _sidecarSpecs], "sidecar names/order mismatch: {}".format(_names)

    # Every sidecar carries the constitution security defaults. seccompProfile
    # is enforced at pod level (covers all containers under PSS=restricted).
    _missingDefaults = [c.name for c in _sidecarContainers if c.securityContext.allowPrivilegeEscalation != False or c.securityContext.runAsNonRoot != True or "ALL" not in c.securityContext.capabilities.drop]
    assert len(_missingDefaults) == 0, "sidecars missing constitution security defaults: {}".format(_missingDefaults)
    assert dep.spec.template.spec.securityContext.seccompProfile.type == "RuntimeDefault", "pod-level seccompProfile must be RuntimeDefault"

    # Every sidecar gets resource requests+limits even when the claim omits them
    # (constitution: resource requests + limits mandatory).
    _missingResources = [c.name for c in _sidecarContainers if not c?.resources?.requests or not c?.resources?.limits]
    assert len(_missingResources) == 0, "sidecars missing resource requests/limits: {}".format(_missingResources)
    # Per-field override wins: the log-shipper sidecar sets readOnlyRootFilesystem=false.
    _override = [c for c in _sidecarContainers if c.name == "log-shipper"]
    if _override:
        assert _override[0].securityContext.readOnlyRootFilesystem == False, "per-sidecar readOnlyRootFilesystem override should win"

    assert True
}

# ---- Test: initContainers present with full security defaults, no ports ----
test_init_containers_security = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    _initSpecs = _oxr.spec.initContainers or []
    _init = dep.spec.template.spec?.initContainers or []
    assert len(_init) == len(_initSpecs), "expected {} initContainers, got {}".format(len(_initSpecs), len(_init))
    assert [c.name for c in _init] == [s.name for s in _initSpecs], "init container names/order mismatch"
    _missingDefaults = [c.name for c in _init if c.securityContext.allowPrivilegeEscalation != False or c.securityContext.readOnlyRootFilesystem != True or c.securityContext.runAsNonRoot != True or "ALL" not in c.securityContext.capabilities.drop]
    assert len(_missingDefaults) == 0, "initContainers missing constitution security defaults: {}".format(_missingDefaults)
    _withPorts = [c.name for c in _init if c?.ports]
    assert len(_withPorts) == 0, "init containers must not expose ports: {}".format(_withPorts)
    assert True
}

# ---- Test: persistence renders PVC + volume + mount, flips strategy ----
test_persistence = lambda {
    _oxr = option("params").oxr
    pvcs = [r for r in items if r.kind == "PersistentVolumeClaim"]
    dep = [r for r in items if r.kind == "Deployment"][0]
    if _oxr.spec.persistence?.enabled:
        assert len(pvcs) == 1, "expected 1 PVC when persistence enabled"
        _pvc = pvcs[0]
        assert _pvc.metadata.name == _oxr.metadata.name + "-data", "PVC must be named <name>-data"
        assert _pvc.spec.resources.requests.storage == _oxr.spec.persistence.size, "PVC size mismatch"
        # volume + mount present
        _vols = [v.name for v in dep.spec.template.spec.volumes]
        assert "data" in _vols, "pod must have a 'data' volume for persistence"
        _mounts = [m.mountPath for m in dep.spec.template.spec.containers[0].volumeMounts]
        assert _oxr.spec.persistence.mountPath in _mounts, "main container must mount persistence at mountPath"

        # strategy: RWO persistence flips to Recreate; RWX keeps RollingUpdate
        # (unless an explicit deploymentStrategy is set).
        if not _oxr.spec?.deploymentStrategy:
            _rwo = "ReadWriteOnce" in (_oxr.spec.persistence?.accessModes or ["ReadWriteOnce"])
            _wantStrategy = "Recreate" if _rwo else "RollingUpdate"
            assert dep.spec.strategy.type == _wantStrategy, "persistence strategy: RWO->Recreate, RWX->RollingUpdate"

    else:
        assert len(pvcs) == 0, "expected 0 PVCs when persistence disabled"
    assert True
}

# ---- Test: service.extraPorts exposed alongside the main port ----
test_service_extra_ports = lambda {
    _oxr = option("params").oxr
    svcs = [r for r in items if r.kind == "Service"]
    _extra = _oxr.spec.service?.extraPorts or []
    if _oxr.spec?.type == "web" or not _oxr.spec?.type:
        _ports = svcs[0].spec.ports
        _names = [p.name for p in _ports]
        assert "http" in _names, "Service should expose the main http port"
        _missing = [ep.name for ep in _extra if ep.name not in _names]
        assert len(_missing) == 0, "Service missing extraPorts: {}".format(_missing)

    assert True
}

# ---- Test: startup + tcp readiness probe variants (SPEC-007 T009) ----
test_probe_variants = lambda {
    _oxr = option("params").oxr
    dep = [r for r in items if r.kind == "Deployment"][0]
    c = dep.spec.template.spec.containers[0]
    if _oxr.spec.healthProbes?.startup:
        assert c?.startupProbe, "startup probe should be present when configured"

    if _oxr.spec.healthProbes?.readiness?.type == "tcp":
        assert c.readinessProbe?.tcpSocket, "readiness probe should use tcpSocket for type=tcp"
        assert not c.readinessProbe?.httpGet, "tcp readiness must not have httpGet"

    assert True
}

# ---- Test: _buildProbe helper covers all probe types ----
test_build_probe_types = lambda {
    _http = _buildProbe({type = "http", path = "/x", port = 9000}, _livenessProbeDefaults)
    assert _http.httpGet.path == "/x" and _http.httpGet.port == 9000, "http probe should set httpGet path/port"
    _tcp = _buildProbe({type = "tcp", port = 5000}, _livenessProbeDefaults)
    assert _tcp.tcpSocket.port == 5000, "tcp probe should set tcpSocket.port"
    _grpc = _buildProbe({type = "grpc", port = 50051}, _livenessProbeDefaults)
    assert _grpc.grpc.port == 50051, "grpc probe should set grpc.port"
    _exec = _buildProbe({type = "exec", command = ["sh", "-c", "true"]}, _livenessProbeDefaults)
    assert _exec.exec.command == ["sh", "-c", "true"], "exec probe should set exec.command"
    assert True
}

# ---- Test: type fork flags + web invariants ----
# The worker/cron *rendering* (no Service/route/HPA/PDB for worker; CronJob
# shape + Forbid/backoffLimit=3 for cron) is asserted end-to-end by
# `crossplane render` in validate-kcl-compositions.sh against
# examples/app-worker.yaml and examples/app-cron.yaml, since `kcl test` only
# loads a single settings file. Here we assert the fork flags + web invariants.
test_type_fork_flags = lambda {
    _oxr = option("params").oxr

    # Assert rendered invariants, not the flag derivation itself (which would
    # just restate the implementation).
    if (_oxr.spec?.type or "web") == "web":
        assert len([r for r in items if r.kind == "Service"]) == 1, "web must render a Service"
        assert len([r for r in items if r.kind == "CronJob"]) == 0, "web must not render a CronJob"
        assert len([r for r in items if r.kind == "Deployment"]) == 1, "web must render a Deployment"

    assert True
}

# ---- Test: strategy resolution wired into the rendered Deployment (FR-007) ----
test_effective_strategy = lambda {
    _oxr = option("params").oxr
    _dep = [r for r in items if r.kind == "Deployment"][0]
    # explicit value always wins; else RWO persistence -> Recreate, RWX/none -> RollingUpdate
    if _oxr.spec?.deploymentStrategy:
        assert _dep.spec.strategy.type == _oxr.spec.deploymentStrategy, "explicit deploymentStrategy must win in rendered output"
    elif _oxr.spec.persistence?.enabled and ("ReadWriteOnce" in (_oxr.spec.persistence?.accessModes or ["ReadWriteOnce"])):
        assert _dep.spec.strategy.type == "Recreate", "RWO persistence must default rendered strategy to Recreate"
    else:
        assert _dep.spec.strategy.type == "RollingUpdate", "default/RWX rendered strategy must be RollingUpdate"
    assert True
}

# ---- Test: _containerSecurityDefaults merge (override wins per field) ----
test_container_security_defaults = lambda {
    _def = _containerSecurityDefaults(None)
    assert _def.allowPrivilegeEscalation == False, "default allowPrivilegeEscalation False"
    assert _def.readOnlyRootFilesystem == True, "default readOnlyRootFilesystem True"
    assert _def.runAsNonRoot == True, "default runAsNonRoot True"
    assert _def.capabilities.drop == ["ALL"], "default drop ALL"
    _ovr = _containerSecurityDefaults({readOnlyRootFilesystem = False})
    assert _ovr.readOnlyRootFilesystem == False, "override readOnlyRootFilesystem should win"
    assert _ovr.runAsNonRoot == True, "un-overridden fields keep defaults"
    assert True
}
