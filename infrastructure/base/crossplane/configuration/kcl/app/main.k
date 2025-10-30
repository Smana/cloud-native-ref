oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]
# Cache frequently accessed values
_name = oxr.metadata.name
_namespace = oxr.metadata.namespace
# Common labels
_appLabels = {
    "app.kubernetes.io/name" = _name
    "app.kubernetes.io/instance" = _name
}

_podSelector = {
    matchLabels = _appLabels
}

# Metadata helper for native Kubernetes resources
# Creates metadata with composition-resource-name annotation for Crossplane tracking
# AWS resources use monolith provider (s3.aws.m.upbound.io) for namespace-scoped resources
_metadata = lambda suffix: str -> any {
    {
        name = _name + "-" + suffix
        namespace = _namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = _name + "-" + suffix
        }
    }
}
# Build node affinity for on-demand instances
_buildNodeAffinity = lambda onDemand: bool -> any {
    {
        requiredDuringSchedulingIgnoredDuringExecution = {
            nodeSelectorTerms = [{
                matchExpressions = [{
                    key = "karpenter.sh/capacity-type"
                    operator = "In"
                    values = ["on-demand"]
                }]
            }]
        }
    } if onDemand else None
}
# Build pod anti-affinity based on preset (hard/soft)
_buildPodAntiAffinity = lambda preset: str -> any {
    {
        requiredDuringSchedulingIgnoredDuringExecution = [{
            labelSelector = _podSelector
            topologyKey = "kubernetes.io/hostname"
        }]
    } if preset == "hard" else {
        preferredDuringSchedulingIgnoredDuringExecution = [{
            weight = 100
            podAffinityTerm = {
                labelSelector = _podSelector
                topologyKey = "kubernetes.io/hostname"
            }
        }]
    } if preset == "soft" else None
}
# Build complete affinity configuration
_buildAffinity = lambda onDemand: bool, antiAffinityPreset: str -> any {
    _nodeAff = _buildNodeAffinity(onDemand)
    _podAff = _buildPodAntiAffinity(antiAffinityPreset)

    {
        if _nodeAff:
            nodeAffinity = _nodeAff
        if _podAff:
            podAntiAffinity = _podAff
    } if _nodeAff or _podAff else None
}
# Build topology spread constraints for zone distribution
_buildTopologySpreadConstraints = lambda enabled: bool -> any {
    [{
        maxSkew = 1
        topologyKey = "topology.kubernetes.io/zone"
        whenUnsatisfiable = "ScheduleAnyway"
        labelSelector = _podSelector
    }] if enabled else None
}
# Map KV store size to Helm chart resource preset
_kvSizeToPreset = lambda size: str -> str {
    "nano" if size == "small" else "small" if size == "medium" else "medium"
}
# Constants
_DEFAULTS = {
    # Resource requirements
    cpu_request = "100m"
    memory_request = "128Mi"
    cpu_limit = "200m"
    memory_limit = "256Mi"
    # Health checks
    health_check_initial_delay = 30
    health_check_period = 10
    readiness_initial_delay = 5
    readiness_period = 5
    # Autoscaling
    hpa_min_replicas = 1
    hpa_max_replicas = 5
    cpu_utilization_target = 70
    # PodDisruptionBudget
    pdb_min_available = 1
    pdb_eviction_policy = "AlwaysAllow"
    # KV Store
    valkey_chart_version = "3.0.31"
    # Observability endpoints
    traces_endpoint = "http://victoria-traces-vt-single-server.observability.svc:10428/insert/opentelemetry/v1/traces"
    metrics_endpoint = "http://vmsingle-victoria-metrics-k8s-stack.observability.svc:8428/opentelemetry/v1/metrics"
}

# Build OpenTelemetry environment variables for observability
# Returns a list of env vars based on observability configuration
_buildObservabilityEnv = lambda obs: any -> [any] {
    _baseEnv = [
        {
            name = "OTEL_SERVICE_NAME"
            value = _name
        }
        {
            name = "OTEL_SERVICE_VERSION"
            value = oxr.spec.image.tag or "latest"
        }
        {
            name = "OTEL_DEPLOYMENT_ENVIRONMENT"
            value = envConfig.environment or "production"
        }
    ]

    _tracesEnv = [
        {
            name = "OTEL_TRACES_ENABLED"
            value = "true"
        }
        {
            name = "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"
            value = obs?.traces?.endpoint or _DEFAULTS.traces_endpoint
        }
        {
            name = "OTEL_TRACES_SAMPLER"
            value = "parentbased_traceidratio"
        }
        {
            name = "OTEL_TRACES_SAMPLER_ARG"
            value = str(obs?.traces?.samplingRate or 1)
        }
    ] if obs?.traces?.enabled else []

    _metricsEnv = [
        {
            name = "OTEL_METRICS_ENABLED"
            value = "true"
        }
        {
            name = "OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"
            value = obs?.metrics?.endpoint or _DEFAULTS.metrics_endpoint
        }
    ] if obs?.metrics?.enabled else []

    # Return combined env vars only if traces or metrics are enabled
    _baseEnv + _tracesEnv + _metricsEnv if (obs?.traces?.enabled or obs?.metrics?.enabled) else []
}
# Default resource requirements
_defaultRequests = {
    cpu: _DEFAULTS.cpu_request
    memory: _DEFAULTS.memory_request
}
_defaultLimits = {
    cpu: _DEFAULTS.cpu_limit
    memory: _DEFAULTS.memory_limit
}
# Set resource requirements based on size
_setResourceRequirements = lambda resources: any -> any {
    {
        requests: resources?.requests or _defaultRequests
        limits: resources?.limits or _defaultLimits
    }
}

_items = []

# Readiness checking for native Kubernetes resources
# ===================================================
# Crossplane provides observed resources through ocds (Observed Composed Desired State)
# which contains the current cluster state. Resources are keyed by their
# composition-resource-name annotation value (e.g., "podinfo-deployment").
#
# We check actual Kubernetes status conditions before marking resources ready.
# This ensures the App XR only shows Ready when resources are truly functional,
# not just created. This is based on Upbound's best practice pattern from
# project-template-k8s-webapp.
#
# References:
# - https://github.com/upbound/project-template-k8s-webapp/blob/main/template/functions/webapps-kcl/main.k
# - Kubernetes API conventions for status conditions
# Get observed resources from cluster to check actual health
# Use direct accessor pattern to avoid UndefinedType issues with .get()
_observedDeployment = ocds[_name + "-deployment"]?.Resource if _name + "-deployment" in ocds else None
_observedService = ocds[_name + "-service"]?.Resource if _name + "-service" in ocds else None
_observedHTTPRoute = ocds[_name + "-httproute"]?.Resource if _name + "-httproute" in ocds else None
_observedHPA = ocds[_name + "-hpa"]?.Resource if _name + "-hpa" in ocds else None
_observedPDB = ocds[_name + "-pdb"]?.Resource if _name + "-pdb" in ocds else None
_observedGateway = ocds[_name + "-gateway"]?.Resource if _name + "-gateway" in ocds else None
_observedNetworkPolicy = ocds[_name + "-cilium-netpol"]?.Resource if _name + "-cilium-netpol" in ocds else None
_observedKVStore = ocds[_name + "-kvstore"]?.Resource if _name + "-kvstore" in ocds else None
_observedServiceAccount = ocds[_name + "-serviceaccount"]?.Resource if _name + "-serviceaccount" in ocds else None

# Check if Deployment is actually Available (not just created)
# Looks for Deployment.status.conditions[type=Available, status=True]
# Use direct field access (c?.type) instead of c.get() to avoid UndefinedType
_deploymentReady = any_true([c?.type == "Available" and c?.status == "True" for c in _observedDeployment?.status?.conditions or []])

# Check if Service has ClusterIP assigned
# Services are ready when they have a ClusterIP (can route traffic)
_serviceReady = _observedService?.spec?.clusterIP != None

# Check if HTTPRoute is Accepted by Gateway
# Looks for HTTPRoute.status.parents[].conditions[type=Accepted, status=True]
_httpRouteConditions = _observedHTTPRoute?.status?.parents?[0]?.conditions or []
_httpRouteReady = any_true([c?.type == "Accepted" and c?.status == "True" for c in _httpRouteConditions])

# Check if HorizontalPodAutoscaler is functioning
# HPAs are ready when they have started reporting current replicas
_hpaReady = _observedHPA?.status?.currentReplicas != None

# Check if PodDisruptionBudget has been observed by the controller
# PDBs are ready when the controller has calculated allowed disruptions
_pdbReady = _observedPDB?.status?.disruptionsAllowed != None

# Check if Gateway is Programmed or Accepted
# Looks for Gateway.status.conditions[type=Programmed|Accepted, status=True]
_gatewayReady = any_true([(c?.type == "Programmed" or c?.type == "Accepted") and c?.status == "True" for c in _observedGateway?.status?.conditions or []])

# Check if CiliumNetworkPolicy exists in the cluster
# Network policies don't have status conditions, so we check if the resource exists
_networkPolicyReady = _observedNetworkPolicy != None and _observedNetworkPolicy?.metadata != None

# Check if HelmRelease is Ready
# Looks for HelmRelease.status.conditions[type=Ready, status=True]
_helmReleaseReady = any_true([c?.type == "Ready" and c?.status == "True" for c in _observedKVStore?.status?.conditions or []])

# Check if ServiceAccount exists in the cluster
# ServiceAccounts don't have status conditions, so we check if the resource exists
_serviceAccountReady = _observedServiceAccount != None and _observedServiceAccount?.metadata != None

# Core Kubernetes resources
# Deployment
_deployment = {
    apiVersion = "apps/v1"
    kind = "Deployment"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = _name + "-deployment"
            if _deploymentReady:
                "krm.kcl.dev/ready" = "True"
        }
        labels = _appLabels
    }
    spec = {
        if oxr.spec.autoscaling?.enabled != True:
            replicas = oxr.spec.replicas or 1
        selector = _podSelector
        template = {
            metadata = {
                labels = _appLabels
            }
            spec = {
                serviceAccountName = _name
                automountServiceAccountToken = oxr.spec?.automountServiceAccountToken or False
                securityContext = {
                    seccompProfile = {
                        type = "RuntimeDefault"
                    }
                    if oxr.spec.runAsNonRoot:
                        runAsNonRoot = True
                        runAsUser = 1001
                        fsGroup = 1001
                }
                if oxr.spec.securityContext?.enableWritableTmp != False:
                    volumes = [{
                        name = "tmp"
                        emptyDir = {}
                    }]
                if oxr.spec.spreadAcrossZones:
                    topologySpreadConstraints = [{
                        maxSkew = 1
                        topologyKey = "topology.kubernetes.io/zone"
                        whenUnsatisfiable = "ScheduleAnyway"
                        labelSelector = _podSelector
                    }]
                # Build affinity configuration (node + pod affinity)
                if oxr.spec.onDemand or oxr.spec.antiAffinityPreset:
                    affinity = _buildAffinity(oxr.spec.onDemand or False, oxr.spec.antiAffinityPreset or "")
                containers = [{
                    name = _name
                    image = oxr.spec.image.repository + ":" + (oxr.spec.image.tag or "latest")
                    imagePullPolicy = oxr.spec.image.pullPolicy or "IfNotPresent"
                    securityContext = {
                        allowPrivilegeEscalation = False if oxr.spec.securityContext?.allowPrivilegeEscalation == None else oxr.spec.securityContext.allowPrivilegeEscalation
                        readOnlyRootFilesystem = True if oxr.spec.securityContext?.readOnlyRootFilesystem == None else oxr.spec.securityContext.readOnlyRootFilesystem
                        runAsNonRoot = True if oxr.spec.securityContext?.runAsNonRoot == None else oxr.spec.securityContext.runAsNonRoot
                        capabilities = {
                            drop = oxr.spec.securityContext?.capabilities?.drop or ["ALL"]
                        }
                    }
                    if oxr.spec.securityContext?.enableWritableTmp != False:
                        volumeMounts = [{
                            name = "tmp"
                            mountPath = "/tmp"
                        }]
                    if oxr.spec.envFrom:
                        envFrom = oxr.spec.envFrom
                    # Build environment variables in order: defaults -> observability -> user
                    # Later vars can override earlier ones with the same name
                    _defaultEnv = [
                        {
                            name = "USER"
                            value = "app"
                        }
                        {
                            name = "POD_NAME"
                            valueFrom = {
                                fieldRef = {
                                    fieldPath = "metadata.name"
                                }
                            }
                        }
                        {
                            name = "POD_NAMESPACE"
                            valueFrom = {
                                fieldRef = {
                                    fieldPath = "metadata.namespace"
                                }
                            }
                        }
                        {
                            name = "POD_IP"
                            valueFrom = {
                                fieldRef = {
                                    fieldPath = "status.podIP"
                                }
                            }
                        }
                    ]
                    _otelEnv = _buildObservabilityEnv(oxr.spec.observability)
                    _userEnv = oxr.spec.env or []
                    _combinedEnv = _defaultEnv + _otelEnv + _userEnv
                    if _combinedEnv:
                        env = _combinedEnv
                    if oxr.spec.service?.port:
                        ports = [{
                            containerPort = oxr.spec.service.port
                            name = "http"
                            protocol = "TCP"
                        }]
                    resources = _setResourceRequirements(oxr.spec.resources)
                    if oxr.spec.service?.port:
                        livenessProbe = {
                            httpGet = {
                                path = oxr.spec.healthProbes?.liveness?.path or "/healthz"
                                port = "http"
                            }
                            initialDelaySeconds = oxr.spec.healthProbes?.liveness?.initialDelaySeconds or _DEFAULTS.health_check_initial_delay
                            periodSeconds = oxr.spec.healthProbes?.liveness?.periodSeconds or _DEFAULTS.health_check_period
                        }
                        readinessProbe = {
                            httpGet = {
                                path = oxr.spec.healthProbes?.readiness?.path or "/readyz"
                                port = "http"
                            }
                            initialDelaySeconds = oxr.spec.healthProbes?.readiness?.initialDelaySeconds or _DEFAULTS.readiness_initial_delay
                            periodSeconds = oxr.spec.healthProbes?.readiness?.periodSeconds or _DEFAULTS.readiness_period
                        }
                }]
            }
        }
    }
}
# Service
_service = {
    apiVersion = "v1"
    kind = "Service"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = _name + "-service"
            if _serviceReady:
                "krm.kcl.dev/ready" = "True"
        }
        labels = _appLabels
    }
    spec = {
        selector = _appLabels
        if oxr.spec.service?.port:
            ports = [{
                name = "http"
                port = oxr.spec.service.port
                targetPort = "http"
                protocol = "TCP"
            }]
        type = "ClusterIP"
    }
}

# ServiceAccount
# Always create a dedicated ServiceAccount for security and IAM integration
_serviceAccount = {
    apiVersion = "v1"
    kind = "ServiceAccount"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = _name + "-serviceaccount"
            if _serviceAccountReady:
                "krm.kcl.dev/ready" = "True"
        }
    }
}
# Add core Kubernetes resources to items
_items += [_deployment, _service, _serviceAccount]

# HorizontalPodAutoscaler
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.autoscaling?.enabled:
    _hpaResource = [{
        apiVersion = "autoscaling/v2"
        kind = "HorizontalPodAutoscaler"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-hpa"
                if _hpaReady:
                    "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            scaleTargetRef = {
                apiVersion = "apps/v1"
                kind = "Deployment"
                name = _name
            }
            minReplicas = oxr.spec.autoscaling.minReplicas or _DEFAULTS.hpa_min_replicas
            maxReplicas = oxr.spec.autoscaling.maxReplicas or _DEFAULTS.hpa_max_replicas
            metrics = [{
                type = "Resource"
                resource = {
                    name = "cpu"
                    target = {
                        type = "Utilization"
                        averageUtilization = oxr.spec.autoscaling.targetCPUUtilizationPercentage or _DEFAULTS.cpu_utilization_target
                    }
                }
            }]
        }
    }]
    _items += _hpaResource

# PodDisruptionBudget
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.pdb?.enabled:
    _pdbResource = [{
        apiVersion = "policy/v1"
        kind = "PodDisruptionBudget"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-pdb"
                if _pdbReady:
                    "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            selector = _podSelector
            minAvailable = oxr.spec.pdb.minAvailable or _DEFAULTS.pdb_min_available
            unhealthyPodEvictionPolicy = oxr.spec.pdb.unhealthyPodEvictionPolicy or _DEFAULTS.pdb_eviction_policy
        }
    }]
    _items += _pdbResource

# Gateway for ingress (create new gateway if enabled)
# When gateway.enabled=true, creates a dedicated Gateway resource
# The HTTPRoute (created below) will reference this gateway instead of platform gateways
# This allows for custom gateway configuration per application
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.gateway?.enabled:
    _gatewayName = oxr.spec.gateway.name or _name + "-gateway"
    _gatewayNamespace = oxr.spec.gateway.namespace or _namespace
    _gatewayResource = [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "Gateway"
        metadata = {
            name = _gatewayName
            namespace = _gatewayNamespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-gateway"
                if _gatewayReady:
                    "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            gatewayClassName = oxr.spec.gateway.gatewayClassName or "cilium"
            if oxr.spec.gateway.listeners:
                listeners = [{
                    name = listener.name
                    protocol = listener.protocol
                    port = listener.port
                    if listener.hostname:
                        hostname = listener.hostname
                    allowedRoutes = {
                        namespaces = {
                            from = "Same"
                        }
                    }
                } for listener in oxr.spec.gateway.listeners]
            else:
                listeners = [{
                    name = "http"
                    protocol = "HTTP"
                    port = 80
                    allowedRoutes = {
                        namespaces = {
                            from = "Same"
                        }
                    }
                }]
        }
    }]
    _items += _gatewayResource

# HTTPRoute for routing
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.route?.enabled == True:
    # Determine which gateway to reference and domain suffix based on configuration
    # Priority: custom gateway > internet-facing > platform-tailscale-general (private via Tailscale)
    # IMPORTANT: Calculate all values inline to avoid mutation (issue #285)
    _routeGatewayName = oxr.spec.gateway.name or _name + "-gateway" if oxr.spec.gateway?.enabled else "platform-public" if oxr.spec.route?.internetFacing else "platform-tailscale-general"
    _routeGatewayNamespace = oxr.spec.gateway.namespace or _namespace if oxr.spec.gateway?.enabled else "infrastructure"
    _routeDomainSuffix = "" if oxr.spec.gateway?.enabled else ".cloud.ogenki.io" if oxr.spec.route?.internetFacing else ".priv.cloud.ogenki.io"
    # Construct full hostname if hostname is provided
    _fullHostname = oxr.spec.route.hostname + _routeDomainSuffix if oxr.spec.route?.hostname else None

    # HTTPRoute - wrapped in intermediate variable to avoid duplicate detection bug
    # See: https://github.com/crossplane-contrib/function-kcl/issues/285
    _httpRouteResource = [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "HTTPRoute"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-httproute"
                if _httpRouteReady:
                    "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            if _fullHostname:
                hostnames = [_fullHostname]
            parentRefs = [{
                name = _routeGatewayName
                namespace = _routeGatewayNamespace
            }]
            rules = [{
                matches = [{
                    path = {
                        type = "PathPrefix"
                        value = rule.pathPrefix or "/"
                    }
                } for rule in (oxr.spec.route.rules or [{backendPort: oxr.spec.service?.port or 8080, pathPrefix: "/"}])]
                backendRefs = [{
                    name = _name
                    port = rule.backendPort
                } for rule in (oxr.spec.route.rules or [{backendPort: oxr.spec.service?.port or 8080}])]
            }]
        }
    }]
    _items += _httpRouteResource

# CiliumNetworkPolicy
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.networkPolicies?.enabled:
    _networkPolicyResource = [{
        apiVersion = "cilium.io/v2"
        kind = "CiliumNetworkPolicy"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-cilium-netpol"
                if _networkPolicyReady:
                    "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            endpointSelector = _podSelector
            if oxr.spec.networkPolicies.ingress:
                ingress = oxr.spec.networkPolicies.ingress
            if oxr.spec.networkPolicies.egress:
                egress = oxr.spec.networkPolicies.egress
        }
    }]
    _items += _networkPolicyResource

# Infrastructure resources
# Key-Value Store (Valkey/Redis)
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.kvStore?.enabled:
    _kvType = oxr.spec.kvStore.type or "valkey"
    _kvPreset = _kvSizeToPreset(oxr.spec.kvStore.size or "small")
    _kvStoreResource = [{
        apiVersion = "helm.toolkit.fluxcd.io/v2"
        kind = "HelmRelease"
        metadata = {
            name = _name + "-" + _kvType
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-kvstore"
                if _helmReleaseReady:
                    "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            releaseName = _name + "-" + _kvType
            driftDetection = {
                mode = "enabled"
            }
            chart = {
                spec = {
                    chart = _kvType
                    sourceRef = {
                        kind = "HelmRepository"
                        name = "bitnami"
                        namespace = "flux-system"
                    }
                    version = _DEFAULTS.valkey_chart_version
                }
            }
            interval = "10m0s"
            install = {
                remediation = {
                    retries = 3
                }
            }
            values = {
                image = {
                    registry = "docker.io"
                    repository = "bitnamilegacy/valkey"
                }
                auth = {
                    enabled = False
                }
                primary = {
                    resourcesPreset = _kvPreset
                    persistence = {
                        size = "4Gi"
                    }
                }
                replica = {
                    resourcesPreset = _kvPreset
                    persistence = {
                        size = "4Gi"
                    }
                }
                metrics = {
                    enabled = True
                    image = {
                        registry = "docker.io"
                        repository = "bitnamilegacy/redis-exporter"
                    }
                    serviceMonitor = {
                        enabled = True
                    }
                }
            }
        }
    }]
    _items += _kvStoreResource

# SQL Instance
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.sqlInstance?.enabled:
    _sqlInstanceResource = [{
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "SQLInstance"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-sqlinstance"
            }
        }
        spec = {
            size = oxr.spec.sqlInstance.size or "small"
            storageSize = oxr.spec.sqlInstance.storageSize
            if oxr.spec.sqlInstance.backup:
                backup = oxr.spec.sqlInstance.backup
            if oxr.spec.sqlInstance.instances:
                instances = oxr.spec.sqlInstance.instances
            if oxr.spec.sqlInstance.primaryUpdateStrategy:
                primaryUpdateStrategy = oxr.spec.sqlInstance.primaryUpdateStrategy
            if oxr.spec.sqlInstance.createSuperuser:
                createSuperuser = oxr.spec.sqlInstance.createSuperuser
            if oxr.spec.sqlInstance.initSQL:
                initSQL = oxr.spec.sqlInstance.initSQL
            if oxr.spec.sqlInstance.atlasSchema:
                atlasSchema = oxr.spec.sqlInstance.atlasSchema
            if oxr.spec.sqlInstance.postgresql:
                postgresql = oxr.spec.sqlInstance.postgresql
            if oxr.spec.sqlInstance.storageClass:
                storageClassName = oxr.spec.sqlInstance.storageClass
            if oxr.spec.sqlInstance.roles:
                roles = oxr.spec.sqlInstance.roles
            if oxr.spec.sqlInstance.databases:
                databases = oxr.spec.sqlInstance.databases
            if oxr.spec.sqlInstance.managementPolicies:
                managementPolicies = oxr.spec.sqlInstance.managementPolicies
            if oxr.spec.sqlInstance.objectStoreRecovery:
                objectStoreRecovery = oxr.spec.sqlInstance.objectStoreRecovery
        }
    }]
    _items += _sqlInstanceResource

# S3 Bucket
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.s3Bucket?.enabled:
    _bucketName = (oxr.spec.s3Bucket.region or envConfig.region) + "-ogenki-" + _name
    _bucketArn = "arn:aws:s3:::" + _bucketName

    _s3BucketResources = [
        {
            apiVersion = "s3.aws.m.upbound.io/v1beta1"
            kind = "Bucket"
            metadata = {
                name = _name + "-s3-bucket"
                namespace = _namespace
                annotations = {
                    "krm.kcl.dev/composition-resource-name" = _name + "-s3-bucket"
                    "crossplane.io/external-name" = _bucketName
                }
            }
            spec = {
                providerConfigRef = {
                    name = oxr.spec.s3Bucket.providerConfigRef?.name or "default"
                    kind = "ClusterProviderConfig"
                }
                forProvider = {
                    region = oxr.spec.s3Bucket.region or envConfig.region
                }
            }
        }
    ]

    # Add BucketVersioning as separate resource if versioning is enabled
    if oxr.spec.s3Bucket.versioning:
        _s3BucketResources += [{
            apiVersion = "s3.aws.m.upbound.io/v1beta1"
            kind = "BucketVersioning"
            metadata = _metadata("s3-bucket-versioning")
            spec = {
                providerConfigRef = {
                    name = oxr.spec.s3Bucket.providerConfigRef?.name or "default"
                    kind = "ClusterProviderConfig"
                }
                forProvider = {
                    region = oxr.spec.s3Bucket.region or envConfig.region
                    bucketRef = {
                        name = _name + "-s3-bucket"
                    }
                    versioningConfiguration = {
                        status = "Enabled"
                    }
                }
            }
        }]

    # Add EKS Pod Identity for S3 access
    _s3BucketResources += [
        # EKS Pod Identity for S3 access
        {
            apiVersion = "cloud.ogenki.io/v1alpha1"
            kind = "EPI"
            metadata = _metadata("s3-pod-identity")
            spec = {
                serviceAccount = {
                    name = _name
                    namespace = _namespace
                }
                clusters = [{
                    name = envConfig.clusterName
                    region = envConfig.region
                }]
                if oxr.spec.s3Bucket.permissions == "custom" and oxr.spec.s3Bucket.customPolicy:
                    policyDocument = oxr.spec.s3Bucket.customPolicy
                elif oxr.spec.s3Bucket.permissions == "readwrite":
                    policyDocument = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": \"""" + _bucketArn + """\"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": \"""" + _bucketArn + """/*\"
        }
    ]
}"""
                elif oxr.spec.s3Bucket.permissions == "readonly":
                    policyDocument = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": \"""" + _bucketArn + """\"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject"
            ],
            "Resource": \"""" + _bucketArn + """/*\"
        }
    ]
}"""
            }
        }
    ]
    _items += _s3BucketResources

# External Secrets
# Create ExternalSecrets from AWS Secrets Manager using dataFrom pattern
# This matches the pattern used throughout the codebase for secret management
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.externalSecrets:
    _externalSecretResources = [{
        apiVersion = "external-secrets.io/v1"
        kind = "ExternalSecret"
        metadata = {
            name = secret.name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-externalsecret-" + secret.name
            }
        }
        spec = {
            refreshInterval = secret.refreshInterval or "1h"
            secretStoreRef = {
                kind = "ClusterSecretStore"
                name = "clustersecretstore"
            }
            target = {
                creationPolicy = "Owner"
                deletionPolicy = "Retain"
                name = secret.name
            }
            dataFrom = [{
                extract = {
                    conversionStrategy = "Default"
                    key = secret.remoteRef
                }
            }]
        }
    } for secret in oxr.spec.externalSecrets]
    _items += _externalSecretResources

# Observability Resources
# VMServiceScrape for automatic metrics discovery
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.observability?.metrics?.enabled:
    _vmServiceScrapeResource = [{
        apiVersion = "operator.victoriametrics.com/v1beta1"
        kind = "VMServiceScrape"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-vmservicescrape"
            }
            labels = _appLabels
        }
        spec = {
            selector = {
                matchLabels = _appLabels
            }
            endpoints = [{
                port = "http"
                path = oxr.spec.observability.metrics?.path or "/metrics"
                interval = oxr.spec.observability.metrics?.interval or "30s"
                scrapeTimeout = "10s"
            }]
        }
    }]
    _items += _vmServiceScrapeResource

# VMRule for alerting and recording rules
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.observability?.alertingRules?.groups:
    _vmRuleResource = [{
        apiVersion = "operator.victoriametrics.com/v1beta1"
        kind = "VMRule"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-vmrule"
            }
            labels = _appLabels
        }
        spec = {
            groups = oxr.spec.observability.alertingRules.groups
        }
    }]
    _items += _vmRuleResource

items = _items
