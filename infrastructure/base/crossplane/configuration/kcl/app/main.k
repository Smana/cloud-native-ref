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
# Core Kubernetes resources
_kubernetesResources = [
    # Deployment
    {
        apiVersion = "apps/v1"
        kind = "Deployment"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-deployment"
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
                        if oxr.spec.route?.port:
                            ports = [{
                                containerPort = oxr.spec.route.port
                                name = "http"
                                protocol = "TCP"
                            }]
                        resources = _setResourceRequirements(oxr.spec.resources)
                        if oxr.spec.route?.port:
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
    {
        apiVersion = "v1"
        kind = "Service"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-service"
                "krm.kcl.dev/ready" = "True"
            }
            labels = _appLabels
        }
        spec = {
            selector = _appLabels
            if oxr.spec.route?.port:
                ports = [{
                    name = "http"
                    port = oxr.spec.route.port
                    targetPort = "http"
                    protocol = "TCP"
                }]
            type = "ClusterIP"
        }
    }
]

_items += _kubernetesResources
# HorizontalPodAutoscaler
if oxr.spec.autoscaling?.enabled:
    _items += [{
        apiVersion = "autoscaling/v2"
        kind = "HorizontalPodAutoscaler"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-hpa"
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

# PodDisruptionBudget
if oxr.spec.pdb?.enabled:
    _items += [{
        apiVersion = "policy/v1"
        kind = "PodDisruptionBudget"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-pdb"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            selector = _podSelector
            minAvailable = oxr.spec.pdb.minAvailable or _DEFAULTS.pdb_min_available
            unhealthyPodEvictionPolicy = oxr.spec.pdb.unhealthyPodEvictionPolicy or _DEFAULTS.pdb_eviction_policy
        }
    }]

# Gateway for ingress (create new gateway if enabled)
# When gateway.enabled=true, creates a dedicated Gateway resource
# The HTTPRoute (created below) will reference this gateway instead of platform gateways
# This allows for custom gateway configuration per application
if oxr.spec.gateway?.enabled:
    _gatewayName = oxr.spec.gateway.name or _name + "-gateway"
    _gatewayNamespace = oxr.spec.gateway.namespace or _namespace
    _items += [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "Gateway"
        metadata = {
            name = _gatewayName
            namespace = _gatewayNamespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-gateway"
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

# HTTPRoute for routing
if oxr.spec.route:
    _items += [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "HTTPRoute"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-httproute"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            if oxr.spec.route.hostname:
                hostnames = [oxr.spec.route.hostname]
            if oxr.spec.gateway?.enabled:
                # Reference the custom gateway created above
                parentRefs = [{
                    name = oxr.spec.gateway.name or _name + "-gateway"
                    namespace = oxr.spec.gateway.namespace or _namespace
                }]
            else:
                # Use platform gateways
                parentRefs = [{
                    name = "platform-public" if oxr.spec.route.internetFacing else "platform-private"
                    namespace = "infrastructure"
                }]
            rules = [{
                matches = [{
                    path = {
                        type = "PathPrefix"
                        value = rule.pathPrefix or "/"
                    }
                } for rule in (oxr.spec.route.rules or [{backendPort: oxr.spec.route.port, pathPrefix: "/"}])]
                backendRefs = [{
                    name = _name
                    port = rule.backendPort
                } for rule in (oxr.spec.route.rules or [{backendPort: oxr.spec.route.port}])]
            }]
        }
    }]

# CiliumNetworkPolicy
if oxr.spec.networkPolicies?.enabled:
    _items += [{
        apiVersion = "cilium.io/v2"
        kind = "CiliumNetworkPolicy"
        metadata = {
            name = _name
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-cilium-netpol"
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

# Infrastructure resources
# Key-Value Store (Valkey/Redis)
if oxr.spec.kvStore?.enabled:
    _kvType = oxr.spec.kvStore.type or "valkey"
    _items += [{
        apiVersion = "helm.toolkit.fluxcd.io/v2"
        kind = "HelmRelease"
        metadata = {
            name = _name + "-" + _kvType
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-kvstore"
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
                auth = {
                    enabled = False
                }
                primary = {
                    if oxr.spec.kvStore.size == "small":
                        resourcesPreset = "nano"
                    elif oxr.spec.kvStore.size == "medium":
                        resourcesPreset = "small"
                    elif oxr.spec.kvStore.size == "large":
                        resourcesPreset = "medium"
                    persistence = {
                        size = "4Gi"
                    }
                }
                replica = {
                    if oxr.spec.kvStore.size == "small":
                        resourcesPreset = "nano"
                    elif oxr.spec.kvStore.size == "medium":
                        resourcesPreset = "small"
                    elif oxr.spec.kvStore.size == "large":
                        resourcesPreset = "medium"
                    persistence = {
                        size = "4Gi"
                    }
                }
                metrics = {
                    enabled = True
                    serviceMonitor = {
                        enabled = True
                    }
                }
            }
        }
    }]

# SQL Instance
if oxr.spec.sqlInstance?.enabled:
    _items += [{
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "SQLInstance"
        metadata = _metadata("sqlinstance")
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

# S3 Bucket
if oxr.spec.s3Bucket?.enabled:
    _bucketName = _name + "-s3-bucket"
    _bucketArn = "arn:aws:s3:::" + _bucketName

    _items += [{
        apiVersion = "s3.aws.upbound.io/v1beta1"
        kind = "Bucket"
        metadata = _metadata("s3-bucket")
        spec = {
            providerConfigRef = oxr.spec.s3Bucket.providerConfigRef or {
                name = "default"
                namespace = "crossplane-system"
            }
            forProvider = {
                region = oxr.spec.s3Bucket.region or "us-east-1"
                if oxr.spec.s3Bucket.versioning:
                    versioning = [{
                        enabled = True
                    }]
                if oxr.spec.s3Bucket.retentionDays:
                    lifecycleConfiguration = [{
                        rule = [{
                            id = "retention"
                            status = "Enabled"
                            expiration = [{
                                days = oxr.spec.s3Bucket.retentionDays
                            }]
                        }]
                    }]
            }
        }
    }]
    # EKS Pod Identity for S3 access
    _items += [{
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "EKSPodIdentity"
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
            bucketName = _bucketName
            bucketArn = _bucketArn
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
    }]

items = _items
