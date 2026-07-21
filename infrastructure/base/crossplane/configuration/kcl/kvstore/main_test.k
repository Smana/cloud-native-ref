# Tests for KVStore composition (SPEC-012)
# Run: kcl test . -Y settings-example.yaml
#
# Variant coverage calls the module's _render lambda directly with synthetic
# XRs, so one `kcl test` run exercises standalone/auth/replica/persistence/
# metrics-off/size-map paths regardless of what settings-example.yaml contains.
_mkOxr = lambda _spec: any -> any {
    {metadata = {name = "xplane-test", namespace = "apps"}, spec = _spec}
}

_hrValues = lambda _res: [any] -> any {
    [r for r in _res if r.kind == "HelmRelease"][0].spec.values
}

# ---- Test: standalone default renders exactly HelmRelease + CNP ----
test_standalone_default_resources = lambda {
    _res = _render(_mkOxr({}))
    assert len(_res) == 2, "expected exactly 2 resources, got {}".format(len(_res))
    _hrs = [r for r in _res if r.kind == "HelmRelease"]
    _cnps = [r for r in _res if r.kind == "CiliumNetworkPolicy"]
    assert len(_hrs) == 1, "expected 1 HelmRelease"
    assert len(_cnps) == 1, "expected 1 CiliumNetworkPolicy"
}

# ---- Test: HelmRelease naming, chart pin, skeleton ----
test_helmrelease_shape = lambda {
    _hr = [r for r in _render(_mkOxr({})) if r.kind == "HelmRelease"][0]
    assert _hr.metadata.name == "xplane-test-valkey", "HR name must be <xr>-valkey"
    assert _hr.metadata.namespace == "apps"
    assert _hr.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "xplane-test-kvstore"
    assert _hr.metadata.annotations["krm.kcl.dev/ready"] == "True", "HelmRelease is static-ready"
    assert _hr.spec.releaseName == "xplane-test-valkey"
    assert _hr.spec.chart.spec.chart == "valkey"
    assert _hr.spec.chart.spec.version == "0.10.0", "chart version pin"
    assert _hr.spec.chart.spec.sourceRef.kind == "HelmRepository"
    assert _hr.spec.chart.spec.sourceRef.name == "valkey"
    assert _hr.spec.chart.spec.sourceRef.namespace == "flux-system"
    assert _hr.spec.driftDetection.mode == "enabled"
    assert _hr.spec.interval == "10m0s"
    assert _hr.spec.install.remediation.retries == 3
}

# ---- Test: standalone default values (small size, ephemeral, no auth) ----
test_standalone_default_values = lambda {
    _v = _hrValues(_render(_mkOxr({})))
    assert _v.fullnameOverride == "xplane-test-valkey"
    assert _v.readinessProbe.enabled == True, "readinessProbe must be enabled (chart default is off)"
    assert _v.resources.requests.cpu == "250m", "default size is small"
    assert _v.resources.requests.memory == "256Mi"
    assert _v.resources.limits.cpu == "375m"
    assert _v.resources.limits.memory == "384Mi"
    assert "auth" not in _v, "no auth block unless auth.existingSecret set"
    assert "replica" not in _v, "no replica block in standalone"
    assert "dataStorage" not in _v, "ephemeral by default (CL-4)"
}

# ---- Test: metrics enabled by default with hardened exporter ----
test_metrics_default = lambda {
    _v = _hrValues(_render(_mkOxr({})))
    assert _v.metrics.enabled == True
    assert _v.metrics.serviceMonitor.enabled == True
    _sc = _v.metrics.exporter.securityContext
    assert _sc.runAsNonRoot == True
    assert _sc.runAsUser == 1000
    assert _sc.runAsGroup == 1000
    assert _sc.allowPrivilegeEscalation == False
    assert _sc.readOnlyRootFilesystem == True
    assert "ALL" in _sc.capabilities.drop
    _er = _v.metrics.exporter.resources
    assert _er.requests.cpu == "50m" and _er.requests.memory == "64Mi"
    assert _er.limits.cpu == "100m" and _er.limits.memory == "128Mi"
}

# ---- Test: metrics == false omits the metrics key entirely ----
# Chart default is metrics.enabled=false, so omission == disabled.
test_metrics_disabled = lambda {
    _v = _hrValues(_render(_mkOxr({metrics = False})))
    assert "metrics" not in _v, "metrics key must be absent when spec.metrics is false"
}

# ---- Test: auth variant (existingSecret + custom passwordKey) ----
test_auth_variant = lambda {
    _v = _hrValues(_render(_mkOxr({
        auth = {existingSecret = "harbor-valkey-password", passwordKey = "REDIS_PASSWORD"}
    })))
    assert _v.auth.enabled == True
    assert _v.auth.usersExistingSecret == "harbor-valkey-password"
    assert _v.auth.aclUsers["default"].permissions == "~* &* +@all", "default ACL user is mandatory when auth is on"
    assert _v.auth.aclUsers["default"].passwordKey == "REDIS_PASSWORD"
}

# ---- Test: auth passwordKey defaults to "password" ----
test_auth_default_password_key = lambda {
    _v = _hrValues(_render(_mkOxr({
        auth = {existingSecret = "mysecret"}
    })))
    assert _v.auth.aclUsers["default"].passwordKey == "password"
}

# ---- Test: replica variant (replica block + persistence default 4Gi) ----
test_replica_variant = lambda {
    _v = _hrValues(_render(_mkOxr({replicas = 2})))
    assert _v.replica.enabled == True
    assert _v.replica.replicas == 2
    assert _v.replica.persistence.size == "4Gi", "replica mode must always default persistence.size (chart fails without it)"
    assert "dataStorage" not in _v, "dataStorage is standalone-only"
}

# ---- Test: replica variant honors explicit persistence.size ----
test_replica_explicit_persistence = lambda {
    _v = _hrValues(_render(_mkOxr({replicas = 1, persistence = {size = "10Gi"}})))
    assert _v.replica.persistence.size == "10Gi"
}

# ---- Test: standalone persistence maps to dataStorage ----
test_persistence_standalone = lambda {
    _v = _hrValues(_render(_mkOxr({
        persistence = {size = "8Gi"}
    })))
    assert _v.dataStorage.enabled == True
    assert _v.dataStorage.requestedSize == "8Gi"
    assert "replica" not in _v
}

# ---- Test: size map spot-checks (nano + large) ----
test_size_map = lambda {
    _nano = _hrValues(_render(_mkOxr({size = "nano"}))).resources
    assert _nano.requests.cpu == "100m" and _nano.requests.memory == "128Mi"
    assert _nano.limits.cpu == "150m" and _nano.limits.memory == "192Mi"
    _large = _hrValues(_render(_mkOxr({size = "large"}))).resources
    assert _large.requests.cpu == "1000m" and _large.requests.memory == "1Gi"
    assert _large.limits.cpu == "1500m" and _large.limits.memory == "1536Mi"
}

# ---- Test: CNP selector, ingress rules, standalone has NO egress ----
test_cnp_standalone = lambda {
    _cnp = [r for r in _render(_mkOxr({})) if r.kind == "CiliumNetworkPolicy"][0]
    assert _cnp.apiVersion == "cilium.io/v2"
    assert _cnp.metadata.name == "xplane-test-valkey"
    assert _cnp.metadata.namespace == "apps"
    assert _cnp.metadata.annotations["krm.kcl.dev/composition-resource-name"] == "xplane-test-netpol"
    assert _cnp.metadata.annotations["krm.kcl.dev/ready"] == "True", "CNP is static-ready"
    _sel = _cnp.spec.endpointSelector.matchLabels
    assert _sel["app.kubernetes.io/name"] == "valkey"
    assert _sel["app.kubernetes.io/instance"] == "xplane-test-valkey"
    assert len(_cnp.spec.ingress) == 2
    assert len(_cnp.spec.ingress[0].fromEndpoints) == 1 and len(_cnp.spec.ingress[0].fromEndpoints[0]) == 0, "6379 open to all endpoints in the namespace"
    assert _cnp.spec.ingress[0].toPorts[0].ports[0].port == "6379"
    assert _cnp.spec.ingress[0].toPorts[0].ports[0].protocol == "TCP"
    assert _cnp.spec.ingress[1].fromEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "observability", "9121 restricted to observability (vmagent scrape)"
    assert _cnp.spec.ingress[1].toPorts[0].ports[0].port == "9121"
    assert "egress" not in _cnp.spec, "standalone must render no egress key at all"
}

# ---- Test: replica-mode CNP egress = DNS (L7 inspected) + intra-instance 6379 ----
test_cnp_replica_egress = lambda {
    _cnp = [r for r in _render(_mkOxr({replicas = 3})) if r.kind == "CiliumNetworkPolicy"][0]
    assert len(_cnp.spec.egress) == 2
    _dns = _cnp.spec.egress[0]
    assert _dns.toEndpoints[0].matchLabels["io.kubernetes.pod.namespace"] == "kube-system"
    assert _dns.toEndpoints[0].matchLabels["k8s-app"] == "kube-dns"
    _dnsPorts = [p.port for p in _dns.toPorts[0].ports]
    _dnsProtos = [p.protocol for p in _dns.toPorts[0].ports]
    assert _dnsPorts == ["53", "53"] and "UDP" in _dnsProtos and "TCP" in _dnsProtos
    assert _dns.toPorts[0].rules.dns[0].matchPattern == "*", "L7 dns matchPattern is mandatory for FQDN visibility"
    _sync = _cnp.spec.egress[1]
    assert _sync.toEndpoints[0].matchLabels["app.kubernetes.io/instance"] == "xplane-test-valkey"
    assert _sync.toEndpoints[0].matchLabels["app.kubernetes.io/name"] == "valkey"
    assert _sync.toPorts[0].ports[0].port == "6379"
}

# ---- Test: no Bitnami legacy artifacts anywhere in rendered output ----
test_no_bitnami_legacy = lambda {
    _full = _render(_mkOxr({size = "large", replicas = 2, auth = {existingSecret = "s"}, persistence = {size = "4Gi"}, metrics = True}))
    assert "bitnamilegacy" not in str(_full), "bitnamilegacy must not appear in any variant"
    assert "bitnamilegacy" not in str(items), "bitnamilegacy must not appear in the settings-rendered output"
}

# ---- Test: settings-example.yaml renders through the real option() path ----
test_settings_render = lambda {
    _oxr = option("params").oxr
    assert len(items) == 2, "expected 2 resources from settings-example, got {}".format(len(items))
    _hr = [r for r in items if r.kind == "HelmRelease"][0]
    assert _hr.metadata.name == _oxr.metadata.name + "-valkey"
    assert _hr.spec.values.fullnameOverride == _oxr.metadata.name + "-valkey"
}
