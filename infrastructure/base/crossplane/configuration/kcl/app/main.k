oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_metadata = lambda suffix: str -> any {
    {
        name = oxr.metadata.name + "-" + suffix
        namespace = oxr.metadata.namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-" + suffix
        }
    }
}
# Set resource requirements based on size
_setResourceRequirements = lambda resources: any -> any {
    {
        requests: resources?.requests or {
            cpu: "100m"
            memory: "128Mi"
        }
        limits: resources?.limits or {
            cpu: "200m"
            memory: "256Mi"
        }
    } if resources else {
        requests: {
            cpu: "100m"
            memory: "128Mi"
        }
        limits: {
            cpu: "200m"
            memory: "256Mi"
        }
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
            name = oxr.metadata.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-deployment"
            }
            labels = {
                "app.kubernetes.io/name" = oxr.metadata.name
                "app.kubernetes.io/instance" = oxr.metadata.name
            }
        }
        spec = {
            if oxr.spec.autoscaling?.enabled != True:
                replicas = oxr.spec.replicas or 1
            selector = {
                matchLabels = {
                    "app.kubernetes.io/name" = oxr.metadata.name
                    "app.kubernetes.io/instance" = oxr.metadata.name
                }
            }
            template = {
                metadata = {
                    labels = {
                        "app.kubernetes.io/name" = oxr.metadata.name
                        "app.kubernetes.io/instance" = oxr.metadata.name
                    }
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
                            labelSelector = {
                                matchLabels = {
                                    "app.kubernetes.io/name" = oxr.metadata.name
                                }
                            }
                        }]
                    # Build affinity configuration
                    _affinity = {}

                    # On-demand instance requirement (Karpenter)
                    if oxr.spec.onDemand:
                        _affinity |= {
                            nodeAffinity = {
                                requiredDuringSchedulingIgnoredDuringExecution = {
                                    nodeSelectorTerms = [{
                                        matchExpressions = [{
                                            key = "karpenter.sh/capacity-type"
                                            operator = "In"
                                            values = ["on-demand"]
                                        }]
                                    }]
                                }
                            }
                        }

                    # Anti-affinity presets
                    if oxr.spec.antiAffinityPreset == "hard":
                        _affinity |= {
                            podAntiAffinity = {
                                requiredDuringSchedulingIgnoredDuringExecution = [{
                                    labelSelector = {
                                        matchLabels = {
                                            "app.kubernetes.io/name" = oxr.metadata.name
                                        }
                                    }
                                    topologyKey = "kubernetes.io/hostname"
                                }]
                            }
                        }
                    elif oxr.spec.antiAffinityPreset == "soft":
                        _affinity |= {
                            podAntiAffinity = {
                                preferredDuringSchedulingIgnoredDuringExecution = [{
                                    weight = 100
                                    podAffinityTerm = {
                                        labelSelector = {
                                            matchLabels = {
                                                "app.kubernetes.io/name" = oxr.metadata.name
                                            }
                                        }
                                        topologyKey = "kubernetes.io/hostname"
                                    }
                                }]
                            }
                        }

                    # Apply affinity if any rules are set
                    if _affinity:
                        affinity = _affinity
                    containers = [{
                        name = oxr.metadata.name
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
                                    path = "/health"
                                    port = "http"
                                }
                                initialDelaySeconds = 30
                                periodSeconds = 10
                            }
                            readinessProbe = {
                                httpGet = {
                                    path = "/ready"
                                    port = "http"
                                }
                                initialDelaySeconds = 5
                                periodSeconds = 5
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
            name = oxr.metadata.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-service"
            }
            labels = {
                "app.kubernetes.io/name" = oxr.metadata.name
                "app.kubernetes.io/instance" = oxr.metadata.name
            }
        }
        spec = {
            selector = {
                "app.kubernetes.io/name" = oxr.metadata.name
                "app.kubernetes.io/instance" = oxr.metadata.name
            }
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
            name = oxr.metadata.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-hpa"
            }
        }
        spec = {
            scaleTargetRef = {
                apiVersion = "apps/v1"
                kind = "Deployment"
                name = oxr.metadata.name
            }
            minReplicas = oxr.spec.autoscaling.minReplicas or 1
            maxReplicas = oxr.spec.autoscaling.maxReplicas or 5
            metrics = [{
                type = "Resource"
                resource = {
                    name = "cpu"
                    target = {
                        type = "Utilization"
                        averageUtilization = oxr.spec.autoscaling.targetCPUUtilizationPercentage or 70
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
            name = oxr.metadata.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-pdb"
            }
        }
        spec = {
            selector = {
                matchLabels = {
                    "app.kubernetes.io/name" = oxr.metadata.name
                }
            }
            minAvailable = oxr.spec.pdb.minAvailable or 1
            unhealthyPodEvictionPolicy = oxr.spec.pdb.unhealthyPodEvictionPolicy or "AlwaysAllow"
        }
    }]

# Gateway for ingress
if oxr.spec.gateway?.enabled:
    _items += [{
        apiVersion = "gateway.networking.k8s.io/v1"
        kind = "Gateway"
        metadata = {
            name = oxr.spec.gateway.name
            namespace = oxr.spec.gateway.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-gateway"
            }
        }
        spec = {
            gatewayClassName = oxr.spec.gateway.class or "shared-gateway-class"
            listeners = [{
                name = "http"
                protocol = "HTTP"
                port = 80
                if oxr.spec.gateway.tls?.enabled:
                    tls = {
                        mode = "Terminate"
                        certificateRefs = [{
                            name = oxr.spec.gateway.tls.certificateName
                            kind = "Secret"
                            group = "core"
                        }]
                    }
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
            name = oxr.metadata.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-httproute"
            }
        }
        spec = {
            if oxr.spec.gateway?.enabled:
                parentRefs = [{
                    name = oxr.spec.gateway.name
                    namespace = oxr.spec.gateway.namespace
                }]
            else:
                parentRefs = [{
                    name = "shared-gateway"
                    namespace = "gateway-system"
                }]
            rules = [{
                matches = [{
                    path = {
                        type = "PathPrefix"
                        value = rule.pathPrefix or "/"
                    }
                } for rule in (oxr.spec.route.rules or [{backendPort: oxr.spec.route.port, pathPrefix: "/"}])]
                backendRefs = [{
                    name = oxr.metadata.name
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
            name = oxr.metadata.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-cilium-netpol"
            }
        }
        spec = {
            endpointSelector = {
                matchLabels = {
                    "app.kubernetes.io/name" = oxr.metadata.name
                }
            }
            if oxr.spec.networkPolicies.ingress:
                ingress = oxr.spec.networkPolicies.ingress
            if oxr.spec.networkPolicies.egress:
                egress = oxr.spec.networkPolicies.egress
        }
    }]

# Infrastructure resources
# Key-Value Store (Valkey/Redis)
if oxr.spec.kvStore?.enabled:
    _items += [{
        apiVersion = "helm.toolkit.fluxcd.io/v2"
        kind = "HelmRelease"
        metadata = {
            name = oxr.metadata.name + "-" + (oxr.spec.kvStore.type or "valkey")
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-kvstore"
            }
        }
        spec = {
            releaseName = oxr.metadata.name + "-" + (oxr.spec.kvStore.type or "valkey")
            driftDetection = {
                mode = "enabled"
            }
            chart = {
                spec = {
                    chart = oxr.spec.kvStore.type or "valkey"
                    sourceRef = {
                        kind = "HelmRepository"
                        name = "bitnami"
                        namespace = "flux-system"
                    }
                    version = "3.0.31"
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
                name = oxr.metadata.name
                namespace = oxr.metadata.namespace
            }
            clusters = [{
                name = envConfig.clusterName
                region = envConfig.region
            }]
            bucketName = oxr.metadata.name + "-s3-bucket"
            bucketArn = "arn:aws:s3:::" + bucketName
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
            "Resource": "${bucketArn}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "${bucketArn}/*"
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
            "Resource": "${bucketArn}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject"
            ],
            "Resource": "${bucketArn}/*"
        }
    ]
}"""
        }
    }]

items = _items
