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
    liveness_timeout = 3
    liveness_failure_threshold = 3
    readiness_initial_delay = 5
    readiness_period = 5
    readiness_timeout = 3
    readiness_failure_threshold = 3
    startup_initial_delay = 0
    startup_period = 10
    startup_failure_threshold = 30
    # Service (mirrors the XRD `service.port` schema default)
    service_port = 8080
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
    traces_endpoint = "http://victoria-traces-vt-single-server.observability.svc.cluster.local:10428/insert/opentelemetry/v1/traces"
    metrics_endpoint = "http://vmsingle-victoria-metrics-k8s-stack.observability.svc.cluster.local:8428/opentelemetry/v1/metrics"
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

# ============================================================================
# Workload type fork (SPEC-007)
# ============================================================================
# `web` (default) renders a Deployment + Service + optional route/gateway/HPA/PDB.
# `worker` renders a Deployment only (no Service/route/probe defaults).
# `cron` renders a CronJob (no Service/route/HPA/PDB).
_type = oxr.spec?.type or "web"
_isWeb = _type == "web"
_isCron = _type == "cron"

# Deployment-backed types (web + worker) share the pod-builder and the
# Available-condition readiness check; cron renders a CronJob instead.
_isDeploymentType = not _isCron

# Effective deployment strategy (FR-007): an explicit user value always wins;
# otherwise `Recreate` only for ReadWriteOnce persistence (the multi-attach
# guard), else `RollingUpdate`. ReadWriteMany supports concurrent attach and
# keeps RollingUpdate. Computed here since the XRD no longer carries a default.
_persistenceEnabled = oxr.spec.persistence?.enabled
_persistenceRWO = _persistenceEnabled and "ReadWriteOnce" in (oxr.spec.persistence?.accessModes or ["ReadWriteOnce"])
_effectiveStrategy = oxr.spec?.deploymentStrategy or ("Recreate" if _persistenceRWO else "RollingUpdate")

# Claim-constant hoists shared across the pod-builder, Service and route blocks.
_servicePort = oxr.spec.service?.port
_writableTmp = oxr.spec.securityContext?.enableWritableTmp != False
_pvcName = _name + "-data"

# ============================================================================
# Pod-builder shared by Deployment and CronJob (SPEC-007 T007)
# ============================================================================
# Constitution container security defaults, merged per-field with an optional
# per-container override. Build the dict once (function-kcl #285: never mutate).
_containerSecurityDefaults = lambda override: any -> any {
    # Use explicit key-presence checks (`in`) rather than `?.X == None`: for an
    # absent key, `override?.X` yields Undefined and `Undefined == None` makes
    # the whole ternary Undefined — which would silently DROP the field. That
    # would strip un-overridden security fields from a partially-overridden
    # container. `in` keeps every default present.
    # seccompProfile is deliberately NOT set here: the pod-level securityContext
    # in `_podSpec` sets RuntimeDefault unconditionally, which PSS=restricted
    # accepts for every container in the pod.
    _o = override or {}
    {
        allowPrivilegeEscalation = _o.allowPrivilegeEscalation if "allowPrivilegeEscalation" in _o else False
        readOnlyRootFilesystem = _o.readOnlyRootFilesystem if "readOnlyRootFilesystem" in _o else True
        runAsNonRoot = _o.runAsNonRoot if "runAsNonRoot" in _o else True
        capabilities = {
            drop = _o.capabilities.drop if "capabilities" in _o and "drop" in (_o.capabilities or {}) else ["ALL"]
        }
    }
}

# Build a probe dict for the given probe spec. `type` selects the handler
# (http default | tcp | grpc | exec). Port resolution: an explicit probe port
# wins; otherwise fall back to the named "http" container port when a service
# port exists (preserves the historical web rendered output), else the numeric
# service.port default (8080). Built in one shot (no mutation).
_buildProbe = lambda p: any, defaults: any -> any {
    _p = p or {}
    _pType = p?.type or "http"
    # Numeric port fallback for tcp/grpc (they require an integer port).
    _pPortNum = p?.port or _servicePort or _DEFAULTS.service_port

    # For http, when no explicit probe port is set and a service port exists,
    # reference the named container port "http" (byte-identical to the legacy
    # web rendered output); otherwise use the numeric fallback.
    _pPortHttp = p?.port or ("http" if _servicePort else _DEFAULTS.service_port)
    {
        if _pType == "http":
            httpGet = {
                path = p?.path or defaults.path
                port = _pPortHttp
            }
        elif _pType == "tcp":
            tcpSocket = {
                port = _pPortNum
            }
        elif _pType == "grpc":
            grpc = {
                port = _pPortNum
            }
        elif _pType == "exec":
            exec = {
                command = p?.command or []
            }
        # Key-presence checks (not `or`): an explicit 0 is valid in Kubernetes
        # and must not be swallowed by the falsy `or` fallback.
        initialDelaySeconds = _p.initialDelaySeconds if "initialDelaySeconds" in _p else defaults.initialDelaySeconds
        periodSeconds = _p.periodSeconds if "periodSeconds" in _p else defaults.periodSeconds
        failureThreshold = _p.failureThreshold if "failureThreshold" in _p else defaults.failureThreshold
        if defaults?.timeoutSeconds:
            timeoutSeconds = _p.timeoutSeconds if "timeoutSeconds" in _p else defaults.timeoutSeconds
    }
}

# Build an extra container (sidecar or init) from the reduced schema. Init
# containers omit `ports`; both inherit constitution security defaults merged
# with any per-container override. Built in one shot (no mutation, #285).
_buildExtraContainer = lambda c: any, withPorts: bool -> any {
    {
        name = c.name
        image = c.image
        securityContext = _containerSecurityDefaults(c?.securityContext)
        if c?.command:
            command = c.command
        if c?.args:
            args = c.args
        if c?.env:
            env = c.env
        if c?.envFrom:
            envFrom = c.envFrom
        resources = _setResourceRequirements(c?.resources)
        if c?.volumeMounts:
            volumeMounts = c.volumeMounts
        if withPorts and c?.ports:
            ports = [{
                if p?.name:
                    name = p.name
                containerPort = p.containerPort
                protocol = p?.protocol or "TCP"
            } for p in c.ports]
    }
}

# Default probe parameters (mirror the historical hardcoded values so web
# rendered output is unchanged).
_livenessProbeDefaults = {
    path = "/healthz"
    initialDelaySeconds = _DEFAULTS.health_check_initial_delay
    periodSeconds = _DEFAULTS.health_check_period
    failureThreshold = _DEFAULTS.liveness_failure_threshold
    timeoutSeconds = _DEFAULTS.liveness_timeout
}
_readinessProbeDefaults = {
    path = "/readyz"
    initialDelaySeconds = _DEFAULTS.readiness_initial_delay
    periodSeconds = _DEFAULTS.readiness_period
    failureThreshold = _DEFAULTS.readiness_failure_threshold
    timeoutSeconds = _DEFAULTS.readiness_timeout
}
_startupProbeDefaults = {
    path = "/healthz"
    initialDelaySeconds = _DEFAULTS.startup_initial_delay
    periodSeconds = _DEFAULTS.startup_period
    failureThreshold = _DEFAULTS.startup_failure_threshold
}

# Probe defaulting. `web` keeps today's behavior: liveness + readiness rendered
# with HTTP defaults when a service port is set. `worker`/`cron` get a probe
# ONLY when that specific probe is set on the claim — no HTTP defaults, and each
# probe is gated independently so setting one never injects the other (FR-002).
_webDefaultProbes = _isWeb and _servicePort

# Persistence volume + mount (SPEC-007 T009). PVC is named `<xr-name>-data`
# and mounted on the MAIN container only.
_persistenceVolume = [{
    name = "data"
    persistentVolumeClaim = {
        claimName = _pvcName
    }
}] if _persistenceEnabled else []
_persistenceMount = [{
    name = "data"
    mountPath = oxr.spec.persistence.mountPath
}] if _persistenceEnabled else []

# Main container env (defaults -> observability -> user), reused by the builder.
_mainDefaultEnv = [
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

# Auto-wired backend connection env: when a managed backend is enabled, inject
# the conventional connection variable pointing at the composition-created
# secret/service - UNLESS the user already set that variable (their value wins,
# so nothing is ever double-set). DATABASE_URL consumes the SQLInstance
# connection secret's `uri` key (a ready postgresql:// DSN, from the first
# database); REDIS_URL targets the kvStore primary Service. This lets a
# DB/cache-backed app work from just `sqlInstance.enabled`/`kvStore.enabled`
# with no hand-wired secretKeyRef - the App Wizard needs only the toggle.
#
# SHARED CONTRACT (restated across a module boundary - separate kcl.mod
# packages, no shared import): the `<name>-cnpg-<db>` secret name is owned by
# the cloudnativepg module (its ExternalSecret target); the `<name>-<type>`
# release name (hence `-primary` Service) is owned by the kvStore block below.
# Keep both in sync - if either convention changes, the auto-wired reference
# silently points at a non-existent secret/Service.
_userEnvNames = [e.name for e in (oxr.spec.env or [])]
_dbAutoEnv = [{name = "DATABASE_URL", valueFrom = {
    secretKeyRef = {name = _name + "-cnpg-" + oxr.spec.sqlInstance.databases[0].name, key = "uri"}
}}] if oxr.spec.sqlInstance?.enabled and len(oxr.spec.sqlInstance?.databases or []) > 0 and "DATABASE_URL" not in _userEnvNames else []
_cacheAutoEnv = [{name = "REDIS_URL", value = "redis://" + _name + "-" + (oxr.spec.kvStore?.type or "valkey") + "-primary:6379"}] if oxr.spec.kvStore?.enabled and "REDIS_URL" not in _userEnvNames else []
_mainCombinedEnv = _mainDefaultEnv + _buildObservabilityEnv(oxr.spec.observability) + _dbAutoEnv + _cacheAutoEnv + (oxr.spec.env or [])

# Main application container (SPEC-007 T007). Built in one shot (no mutation).
_mainContainer = {
    name = _name
    image = oxr.spec.image.repository + ":" + (oxr.spec.image.tag or "latest")
    imagePullPolicy = oxr.spec.image.pullPolicy or "IfNotPresent"
    if oxr.spec?.command:
        command = oxr.spec.command
    if oxr.spec?.args:
        args = oxr.spec.args
    # Same per-field default merge as sidecars/init containers (single source
    # of truth for the constitution container security defaults).
    securityContext = _containerSecurityDefaults(oxr.spec.securityContext)
    # Same one-shot assignment pattern as `volumes` in the pod spec.
    volumeMounts = ([{
        name = "tmp"
        mountPath = "/tmp"
    }] if _writableTmp else []) + (oxr.spec.extraVolumeMounts or []) + _persistenceMount
    if oxr.spec.envFrom:
        envFrom = oxr.spec.envFrom
    if _mainCombinedEnv:
        env = _mainCombinedEnv
    if _servicePort:
        ports = [{
            containerPort = _servicePort
            name = "http"
            protocol = "TCP"
        }]
    resources = _setResourceRequirements(oxr.spec.resources)
    if _webDefaultProbes or oxr.spec.healthProbes?.liveness:
        livenessProbe = _buildProbe(oxr.spec.healthProbes?.liveness, _livenessProbeDefaults)
    if _webDefaultProbes or oxr.spec.healthProbes?.readiness:
        readinessProbe = _buildProbe(oxr.spec.healthProbes?.readiness, _readinessProbeDefaults)
    if oxr.spec.healthProbes?.startup:
        startupProbe = _buildProbe(oxr.spec.healthProbes.startup, _startupProbeDefaults)
}

# Sidecar + init container lists (SPEC-007 T007). Sidecars keep ports.
_sidecarContainers = [_buildExtraContainer(c, True) for c in (oxr.spec.sidecars or [])]
_initContainerList = [_buildExtraContainer(c, False) for c in (oxr.spec.initContainers or [])]

# Shared pod template spec used by both Deployment and CronJob (SPEC-007 T007).
# Built in a single assignment (function-kcl #285: no post-creation mutation).
_podSpec = {
    serviceAccountName = _name
    automountServiceAccountToken = oxr.spec?.automountServiceAccountToken or False
    if oxr.spec?.imagePullSecrets:
        imagePullSecrets = [{name = s} for s in oxr.spec.imagePullSecrets]
    if oxr.spec?.terminationGracePeriodSeconds != None:
        terminationGracePeriodSeconds = oxr.spec.terminationGracePeriodSeconds
    securityContext = {
        seccompProfile = {
            type = "RuntimeDefault"
        }
        if oxr.spec.runAsNonRoot:
            runAsNonRoot = True
            runAsUser = 1001
            fsGroup = 1001
    }
    # Build the pod volume list once (KCL forbids post-creation dict mutation
    # — issue #285 — so the conditional `tmp` volume, user `extraVolumes` and
    # the persistence volume get combined in a single assignment.)
    volumes = ([{
        name = "tmp"
        emptyDir = {}
    }] if _writableTmp else []) + (oxr.spec.extraVolumes or []) + _persistenceVolume
    if oxr.spec.spreadAcrossZones:
        topologySpreadConstraints = _buildTopologySpreadConstraints(True)
    if oxr.spec.onDemand or oxr.spec.antiAffinityPreset:
        affinity = _buildAffinity(oxr.spec.onDemand or False, oxr.spec.antiAffinityPreset or "")
    if _initContainerList:
        initContainers = _initContainerList
    containers = [_mainContainer] + _sidecarContainers
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

# Check if VMServiceScrape is Ready
# Looks for VMServiceScrape.status.conditions[status=True] with type ending in "/Applied"
_observedVMServiceScrape = ocds[_name + "-vmservicescrape"]?.Resource if _name + "-vmservicescrape" in ocds else None
_vmServiceScrapeReady = any_true([c?.status == "True" and (c?.type or "").endswith("/Applied") for c in _observedVMServiceScrape?.status?.conditions or []])

# Check if VMRule is Ready
# Looks for VMRule.status.conditions[status=True] with type ending in "/Applied"
_observedVMRule = ocds[_name + "-vmrule"]?.Resource if _name + "-vmrule" in ocds else None
_vmRuleReady = any_true([c?.status == "True" and (c?.type or "").endswith("/Applied") for c in _observedVMRule?.status?.conditions or []])

# Core Kubernetes resources
# Deployment (web + worker types share the same pod-builder)
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
        # `Recreate` for apps with RWO PVCs (default gp3) so the old pod
        # fully releases the volume before the new one starts; otherwise
        # RollingUpdate's maxSurge spins up a parallel pod that hits a
        # `Multi-Attach error` and the rollout stalls. Default
        # RollingUpdate keeps stateless workloads zero-downtime.
        # K8s validation rejects setting `rollingUpdate` when type is
        # `Recreate`, so emit only the matching block per type. The
        # effective strategy is computed in `_effectiveStrategy` (FR-007).
        strategy = {type = "Recreate"} if _effectiveStrategy == "Recreate" else {type = "RollingUpdate", rollingUpdate = {maxSurge = "25%", maxUnavailable = "25%"}}
        selector = _podSelector
        template = {
            metadata = {
                labels = _appLabels
            }
            spec = _podSpec
        }
    }
}

# CronJob (type == cron). Pod template is built from the SAME pod-builder as
# the Deployment; batch defaults (Forbid/backoffLimit=3/history=3/OnFailure)
# are all overridable via spec.cron.*. Built in one shot (no mutation, #285).
_cronPodSpec = _podSpec | {
    restartPolicy = oxr.spec.cron?.restartPolicy or "OnFailure"
}
_cronjob = {
    apiVersion = "batch/v1"
    kind = "CronJob"
    metadata = {
        name = _name
        namespace = _namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = _name + "-cronjob"
            # CronJob is statically ready when created (like HPA/PDB today).
            "krm.kcl.dev/ready" = "True"
        }
        labels = _appLabels
    }
    spec = {
        schedule = oxr.spec.schedule
        concurrencyPolicy = oxr.spec.cron?.concurrencyPolicy or "Forbid"
        successfulJobsHistoryLimit = oxr.spec.cron?.successfulJobsHistoryLimit or 3
        failedJobsHistoryLimit = oxr.spec.cron?.failedJobsHistoryLimit or 3
        jobTemplate = {
            spec = {
                backoffLimit = oxr.spec.cron?.backoffLimit or 3
                if oxr.spec.cron?.activeDeadlineSeconds != None:
                    activeDeadlineSeconds = oxr.spec.cron.activeDeadlineSeconds
                template = {
                    metadata = {
                        labels = _appLabels
                    }
                    spec = _cronPodSpec
                }
            }
        }
    }
}
# Service (web type only)
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
        # Main port + optional extraPorts (SPEC-007 T009). Built in one shot
        # (function-kcl #285: no post-creation mutation). Sidecar ports do NOT
        # become Service ports automatically.
        _mainPorts = [{
            name = "http"
            port = _servicePort
            targetPort = "http"
            protocol = "TCP"
        }] if _servicePort else []
        _extraPorts = [{
            name = p.name
            port = p.port
            targetPort = p?.targetPort or p.port
            protocol = p?.protocol or "TCP"
        } for p in (oxr.spec.service?.extraPorts or [])]
        if _mainPorts or _extraPorts:
            ports = _mainPorts + _extraPorts
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

# PersistentVolumeClaim (persistence.enabled). Named `<xr-name>-data`,
# mounted only on the main container. Statically ready when created.
# NOTE: intermediate variable to avoid function-kcl duplicate detection (#285).
if _persistenceEnabled:
    _pvcResource = [{
        apiVersion = "v1"
        kind = "PersistentVolumeClaim"
        metadata = {
            name = _pvcName
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-pvc"
                "krm.kcl.dev/ready" = "True"
            }
            labels = _appLabels
        }
        spec = {
            accessModes = oxr.spec.persistence?.accessModes or ["ReadWriteOnce"]
            resources = {
                requests = {
                    storage = oxr.spec.persistence.size
                }
            }
            if oxr.spec.persistence?.storageClass:
                storageClassName = oxr.spec.persistence.storageClass
        }
    }]
    _items += _pvcResource

# Add core Kubernetes resources to items (workload type fork, SPEC-007 T008).
# - web:    Deployment + Service + ServiceAccount
# - worker: Deployment + ServiceAccount (no Service)
# - cron:   CronJob + ServiceAccount (no Service)
# The ServiceAccount is created for all types (IAM/EPI integration).
if _isCron:
    _items += [_cronjob, _serviceAccount]
elif _isWeb:
    _items += [_deployment, _service, _serviceAccount]
else:
    _items += [_deployment, _serviceAccount]
# HorizontalPodAutoscaler (Deployment-backed types only; CEL forbids on cron)
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.autoscaling?.enabled and _isDeploymentType:
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

# PodDisruptionBudget (Deployment-backed types only; CEL forbids on cron)
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.pdb?.enabled and _isDeploymentType:
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
if oxr.spec.gateway?.enabled and _isWeb:
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
if oxr.spec.route?.enabled == True and _isWeb:
    # Determine which gateway to reference and domain suffix based on configuration
    # Priority: custom gateway > internet-facing > platform-tailscale-general (private via Tailscale)
    # IMPORTANT: Calculate all values inline to avoid mutation (issue #285)
    _routeGatewayName = oxr.spec.gateway.name or _name + "-gateway" if oxr.spec.gateway?.enabled else "platform-public" if oxr.spec.route?.internetFacing else "platform-tailscale-general"
    _routeGatewayNamespace = oxr.spec.gateway.namespace or _namespace if oxr.spec.gateway?.enabled else "infrastructure"
    _routeDomainSuffix = "" if oxr.spec.gateway?.enabled else ".cloud.ogenki.io" if oxr.spec.route?.internetFacing else ".priv.cloud.ogenki.io"
    # Detect preview environment from namespace naming convention (preview-pr-<id>)
    _isPreview = _namespace.startswith("preview-")
    _previewSuffix = "-" + _namespace[8::] if _isPreview else ""
    _fullHostname = oxr.spec.route.hostname + _previewSuffix + _routeDomainSuffix if oxr.spec.route?.hostname else None

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
                } for rule in (oxr.spec.route.rules or [{backendPort: _servicePort or _DEFAULTS.service_port, pathPrefix: "/"}])]
                backendRefs = [{
                    name = _name
                    port = rule.backendPort
                } for rule in (oxr.spec.route.rules or [{backendPort: _servicePort or _DEFAULTS.service_port}])]
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
            if oxr.spec.sqlInstance.performanceInsights:
                performanceInsights = oxr.spec.sqlInstance.performanceInsights
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
# VMServiceScrape for automatic metrics discovery.
# Only rendered for type=web: it targets the Service by the "http" endpoint,
# and workers/cron have no Service. Metrics for worker/cron should be pushed
# via OTLP (observability.metrics endpoint env, orthogonal to type) rather
# than scraped. (SPEC-007 T008)
# NOTE: Using intermediate variable to avoid function-kcl duplicate detection bug
# See: https://github.com/crossplane-contrib/function-kcl/issues/285
if oxr.spec.observability?.metrics?.enabled and _isWeb:
    _vmServiceScrapeResource = [{
        apiVersion = "operator.victoriametrics.com/v1beta1"
        kind = "VMServiceScrape"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-vmservicescrape"
                if _vmServiceScrapeReady:
                    "krm.kcl.dev/ready" = "True"
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
                if _vmRuleReady:
                    "krm.kcl.dev/ready" = "True"
            }
            labels = _appLabels
        }
        spec = {
            groups = oxr.spec.observability.alertingRules.groups
        }
    }]
    _items += _vmRuleResource

items = _items
