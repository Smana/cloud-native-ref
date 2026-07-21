# KVStore composition (SPEC-012): Valkey via the official valkey-helm chart.
# Renders exactly 2 resources per XR:
#   1. HelmRelease <xr>-valkey  - chart valkey 0.10.0, HelmRepository valkey/flux-system
#   2. CiliumNetworkPolicy <xr>-valkey - default-deny; 6379 ns-local, 9121 from
#      observability (vmagent scrape); egress only in replica mode (DNS + sync)
# Both are static-ready (krm.kcl.dev/ready=True) per repo convention; XR
# readiness comes from function-auto-ready in the composition pipeline.
# SHARED CONTRACT: consumers reach the instance at `<xr-name>-valkey:6379`
# (fullnameOverride pins the Service name; the App module wires REDIS_URL to it).
oxr = option("params").oxr

# Size map (FR-008) - replaces the Bitnami `resourcesPreset`
_sizeResources = {
    nano = {requests = {cpu = "100m", memory = "128Mi"}, limits = {cpu = "150m", memory = "192Mi"}}
    small = {requests = {cpu = "250m", memory = "256Mi"}, limits = {cpu = "375m", memory = "384Mi"}}
    medium = {requests = {cpu = "500m", memory = "512Mi"}, limits = {cpu = "750m", memory = "768Mi"}}
    large = {requests = {cpu = "1000m", memory = "1Gi"}, limits = {cpu = "1500m", memory = "1536Mi"}}
}

# All output is built in single dict literals with inline conditionals -
# never mutated after creation (function-kcl issue #285).
_render = lambda _oxr: any -> [any] {
    _xrName = _oxr.metadata.name
    _namespace = _oxr.metadata.namespace
    _releaseName = _xrName + "-valkey"
    _size = _oxr.spec?.size or "small"
    _replicas = _oxr.spec?.replicas or 0
    _auth = _oxr.spec?.auth
    _persistenceSize = _oxr.spec?.persistence?.size
    _metrics = _oxr.spec?.metrics

    [
        {
            apiVersion = "helm.toolkit.fluxcd.io/v2"
            kind = "HelmRelease"
            metadata = {
                name = _releaseName
                namespace = _namespace
                annotations = {
                    "krm.kcl.dev/composition-resource-name" = _xrName + "-kvstore"
                    "krm.kcl.dev/ready" = "True"
                }
            }
            spec = {
                releaseName = _releaseName
                driftDetection = {
                    mode = "enabled"
                }
                chart = {
                    spec = {
                        chart = "valkey"
                        sourceRef = {
                            kind = "HelmRepository"
                            name = "valkey"
                            namespace = "flux-system"
                        }
                        version = "0.10.0"
                    }
                }
                interval = "10m0s"
                install = {
                    remediation = {
                        retries = 3
                    }
                }
                values = {
                    fullnameOverride = _releaseName
                    resources = _sizeResources[_size]
                    # Chart default is off; startup+liveness are on by default
                    readinessProbe = {enabled = True}
                    if _auth?.existingSecret:
                        # A `default` ACL user is mandatory when auth is on; classic
                        # AUTH <password> authenticates as `default`, so existing
                        # consumer password secrets work unchanged.
                        auth = {
                            enabled = True
                            usersExistingSecret = _auth.existingSecret
                            aclUsers = {
                                "default" = {permissions = "~* &* +@all", passwordKey = _auth?.passwordKey or "password"}
                            }
                        }
                    if _replicas > 0:
                        # Chart `fail`s in replica mode without persistence.size
                        replica = {
                            enabled = True
                            replicas = _replicas
                            persistence = {size = _persistenceSize or "4Gi"}
                        }
                    if _replicas == 0 and _persistenceSize:
                        dataStorage = {
                            enabled = True
                            requestedSize = _persistenceSize
                        }
                    if _metrics != False:
                        # Chart defaults leave exporter securityContext/resources
                        # empty - both must be set for PSS=restricted + constitution
                        metrics = {
                            enabled = True
                            serviceMonitor = {enabled = True}
                            exporter = {
                                resources = {requests = {cpu = "50m", memory = "64Mi"}, limits = {cpu = "100m", memory = "128Mi"}}
                                securityContext = {
                                    runAsNonRoot = True
                                    runAsUser = 1000
                                    runAsGroup = 1000
                                    allowPrivilegeEscalation = False
                                    readOnlyRootFilesystem = True
                                    capabilities = {drop = ["ALL"]}
                                }
                            }
                        }
                }
            }
        }
        {
            apiVersion = "cilium.io/v2"
            kind = "CiliumNetworkPolicy"
            metadata = {
                name = _releaseName
                namespace = _namespace
                annotations = {
                    "krm.kcl.dev/composition-resource-name" = _xrName + "-netpol"
                    "krm.kcl.dev/ready" = "True"
                }
            }
            spec = {
                endpointSelector = {
                    matchLabels = {"app.kubernetes.io/name" = "valkey", "app.kubernetes.io/instance" = _releaseName}
                }
                ingress = [
                    {fromEndpoints = [{}], toPorts = [{ports = [{port = "6379", protocol = "TCP"}]}]}
                    {
                        fromEndpoints = [{
                            matchLabels = {"io.kubernetes.pod.namespace" = "observability"}
                        }]
                        toPorts = [{ports = [{port = "9121", protocol = "TCP"}]}]
                    }
                ]
                if _replicas > 0:
                    # Replica mode only: resolve the headless Service + sync from
                    # the primary. Standalone needs no egress at all.
                    # L7 dns matchPattern "*" is mandatory so Cilium sees resolved
                    # IPs - .claude/rules/cilium-network-policies.md.
                    egress = [
                        {
                            toEndpoints = [{
                                matchLabels = {"io.kubernetes.pod.namespace" = "kube-system", "k8s-app" = "kube-dns"}
                            }]
                            toPorts = [{ports = [{port = "53", protocol = "UDP"}, {port = "53", protocol = "TCP"}], rules = {dns = [{matchPattern = "*"}]}}]
                        }
                        {
                            toEndpoints = [{
                                matchLabels = {"app.kubernetes.io/name" = "valkey", "app.kubernetes.io/instance" = _releaseName}
                            }]
                            toPorts = [{ports = [{port = "6379", protocol = "TCP"}]}]
                        }
                    ]
            }
        }
    ]
}

items = _render(oxr)
