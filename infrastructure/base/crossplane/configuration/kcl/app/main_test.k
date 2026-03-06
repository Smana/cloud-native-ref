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
