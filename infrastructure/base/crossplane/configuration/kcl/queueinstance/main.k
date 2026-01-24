# QueueInstance Composition - Unified API for Kafka and SQS message queuing
oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_region = envConfig.region
_clusterName = envConfig.clusterName

_metadata = lambda suffix: str -> any {
    {
        name = oxr.metadata.name + "-" + suffix
        namespace = oxr.metadata.namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-" + suffix
        }
    }
}

_providerConfigRef = {
    kind = "ClusterProviderConfig"
    name = "default"
}

# Common settings
_dlqEnabled = oxr.spec.deadLetterQueue?.enabled if oxr.spec.deadLetterQueue else True
_maxReceiveCount = oxr.spec.deadLetterQueue?.maxReceiveCount if oxr.spec.deadLetterQueue?.maxReceiveCount else 3
_networkPoliciesEnabled = oxr.spec.networkPolicies?.enabled if oxr.spec.networkPolicies else True

# =============================================================================
# KAFKA BACKEND
# =============================================================================
_kafkaItems = []
if oxr.spec.type == "kafka":
    _kafkaClusterRef = oxr.spec.kafka.clusterRef
    _kafkaClusterNamespace = oxr.spec.kafka.clusterNamespace if oxr.spec.kafka?.clusterNamespace else oxr.metadata.namespace
    _partitions = oxr.spec.kafka.partitions if oxr.spec.kafka?.partitions else 3
    _replicationFactor = oxr.spec.kafka.replicationFactor if oxr.spec.kafka?.replicationFactor else 2
    _retentionMs = oxr.spec.kafka.retentionMs if oxr.spec.kafka?.retentionMs else 604800000

    # Main Kafka Topic
    _kafkaItems += [{
        apiVersion = "kafka.strimzi.io/v1beta2"
        kind = "KafkaTopic"
        metadata = {
            name = oxr.metadata.name + "-topic"
            namespace = _kafkaClusterNamespace
            labels = {
                "strimzi.io/cluster" = _kafkaClusterRef
            }
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-topic"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            topicName = oxr.metadata.name
            partitions = _partitions
            replicas = _replicationFactor
            config = {
                "retention.ms" = str(_retentionMs)
                "min.insync.replicas" = str(_replicationFactor - 1) if _replicationFactor > 1 else "1"
                if oxr.spec.kafka?.config:
                    **oxr.spec.kafka.config
            }
        }
    }]

    # Dead Letter Queue Topic (if enabled)
    _kafkaItems += [{
        apiVersion = "kafka.strimzi.io/v1beta2"
        kind = "KafkaTopic"
        metadata = {
            name = oxr.metadata.name + "-dlq-topic"
            namespace = _kafkaClusterNamespace
            labels = {
                "strimzi.io/cluster" = _kafkaClusterRef
            }
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-dlq-topic"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            topicName = oxr.metadata.name + "-dlq"
            partitions = _partitions
            replicas = _replicationFactor
            config = {
                "retention.ms" = str(_retentionMs * 2)
                "min.insync.replicas" = str(_replicationFactor - 1) if _replicationFactor > 1 else "1"
            }
        }
    }] if _dlqEnabled else []

    # Kafka User with SASL/SCRAM authentication
    _kafkaItems += [{
        apiVersion = "kafka.strimzi.io/v1beta2"
        kind = "KafkaUser"
        metadata = {
            name = oxr.metadata.name + "-user"
            namespace = _kafkaClusterNamespace
            labels = {
                "strimzi.io/cluster" = _kafkaClusterRef
            }
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-user"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            authentication = {
                type = "scram-sha-512"
            }
            authorization = {
                type = "simple"
                acls = [acl for acl in [
                    {
                        resource = {
                            type = "topic"
                            name = oxr.metadata.name
                            patternType = "literal"
                        }
                        operations = ["Read", "Write", "Describe", "Create"]
                        host = "*"
                    }
                    {
                        resource = {
                            type = "topic"
                            name = oxr.metadata.name + "-dlq"
                            patternType = "literal"
                        }
                        operations = ["Read", "Write", "Describe", "Create"]
                        host = "*"
                    } if _dlqEnabled else None
                    {
                        resource = {
                            type = "group"
                            name = oxr.metadata.name + "-*"
                            patternType = "prefix"
                        }
                        operations = ["Read", "Describe"]
                        host = "*"
                    }
                ] if acl]
            }
        }
    }]

    # Connection Secret for Kafka (if connectionSecret is specified)
    _kafkaItems += [{
        apiVersion = "external-secrets.io/v1"
        kind = "ExternalSecret"
        metadata = {
            name = oxr.metadata.name + "-kafka-connection"
            namespace = oxr.spec.connectionSecret.namespace if oxr.spec.connectionSecret?.namespace else oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-kafka-connection"
            }
        }
        spec = {
            refreshInterval = "30m"
            secretStoreRef = {
                kind = "ClusterSecretStore"
                name = "clustersecretstore"
            }
            target = {
                name = oxr.spec.connectionSecret.name
                creationPolicy = "Owner"
                deletionPolicy = "Retain"
                template = {
                    engineVersion = "v2"
                    data = {
                        "bootstrap.servers" = "{{ .bootstrapServers }}"
                        "sasl.username" = "{{ .username }}"
                        "sasl.password" = "{{ .password }}"
                        "sasl.mechanism" = "SCRAM-SHA-512"
                        "security.protocol" = "SASL_SSL"
                        "topic.name" = oxr.metadata.name
                        if _dlqEnabled:
                            "topic.dlq.name" = oxr.metadata.name + "-dlq"
                    }
                }
            }
            # pragma: allowlist secret
            data = [
                {
                    # pragma: allowlist secret
                    secretKey = "bootstrapServers"
                    remoteRef = {
                        key = "kafka/" + _kafkaClusterRef + "/bootstrap-servers"
                        property = "bootstrap.servers"
                    }
                }
                {
                    # pragma: allowlist secret
                    secretKey = "username"
                    remoteRef = {
                        key = "kafka/" + _kafkaClusterRef + "/users/" + oxr.metadata.name
                        property = "username"
                    }
                }
                {
                    # pragma: allowlist secret
                    secretKey = "password"
                    remoteRef = {
                        key = "kafka/" + _kafkaClusterRef + "/users/" + oxr.metadata.name
                        property = "password"
                    }
                }
            ]
        }
    }] if oxr.spec.connectionSecret?.name else []

    # VMServiceScrape for Kafka monitoring (if enabled)
    _kafkaItems += [{
        apiVersion = "operator.victoriametrics.com/v1beta1"
        kind = "VMServiceScrape"
        metadata = _metadata("kafka-metrics")
        spec = {
            selector = {
                matchLabels = {
                    "strimzi.io/cluster" = _kafkaClusterRef
                    "strimzi.io/kind" = "Kafka"
                }
            }
            namespaceSelector = {
                matchNames = [_kafkaClusterNamespace]
            }
            endpoints = [
                {
                    port = "tcp-prometheus"
                    path = "/metrics"
                }
            ]
        }
    }] if oxr.spec.monitoring?.enabled else []

    # CiliumNetworkPolicy for Kafka access (if enabled)
    _kafkaItems += [{
        apiVersion = "cilium.io/v2"
        kind = "CiliumNetworkPolicy"
        metadata = {
            name = oxr.metadata.name + "-kafka-egress"
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-kafka-egress"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            description = "Allow egress to Kafka cluster for " + oxr.metadata.name
            endpointSelector = {
                matchLabels = {
                    "queue.cloud.ogenki.io/name" = oxr.metadata.name
                }
            }
            egress = [
                {
                    toEndpoints = [
                        {
                            matchLabels = {
                                "strimzi.io/cluster" = oxr.spec.kafka.clusterRef
                                "strimzi.io/kind" = "Kafka"
                            }
                        }
                    ]
                    toPorts = [
                        {
                            ports = [
                                {port = "9092", protocol = "TCP"}
                                {port = "9093", protocol = "TCP"}
                                {port = "9094", protocol = "TCP"}
                            ]
                        }
                    ]
                }
            ] + (oxr.spec.networkPolicies.additionalEgress if oxr.spec.networkPolicies?.additionalEgress else [])
        }
    }] if _networkPoliciesEnabled else []

# =============================================================================
# SQS BACKEND
# =============================================================================
_sqsItems = []
if oxr.spec.type == "sqs":
    _fifo = oxr.spec.sqs?.fifo if oxr.spec.sqs?.fifo else False
    _visibilityTimeout = oxr.spec.sqs?.visibilityTimeoutSeconds if oxr.spec.sqs?.visibilityTimeoutSeconds else 30
    _messageRetention = oxr.spec.sqs?.messageRetentionSeconds if oxr.spec.sqs?.messageRetentionSeconds else 345600
    _maxMessageSize = oxr.spec.sqs?.maxMessageSize if oxr.spec.sqs?.maxMessageSize else 262144
    _delaySeconds = oxr.spec.sqs?.delaySeconds if oxr.spec.sqs?.delaySeconds else 0
    _receiveWaitTime = oxr.spec.sqs?.receiveWaitTimeSeconds if oxr.spec.sqs?.receiveWaitTimeSeconds else 0
    _queueName = oxr.metadata.name + (".fifo" if _fifo else "")
    _dlqName = oxr.metadata.name + "-dlq" + (".fifo" if _fifo else "")

    # Get observed resources
    _observedDlq = ocds.get(oxr.metadata.name + "-sqs-dlq", {})?.Resource
    _dlqArn = _observedDlq?.status?.atProvider?.arn if _observedDlq else None
    _observedQueue = ocds.get(oxr.metadata.name + "-sqs-queue", {})?.Resource
    _queueArn = _observedQueue?.status?.atProvider?.arn if _observedQueue else "arn:aws:sqs:*:*:" + _queueName
    _queueUrl = _observedQueue?.status?.atProvider?.url if _observedQueue else ""

    # Dead Letter Queue (if enabled)
    _sqsItems += [{
        apiVersion = "sqs.aws.upbound.io/v1beta2"
        kind = "Queue"
        metadata = _metadata("sqs-dlq")
        spec = {
            if oxr.spec.managementPolicies:
                managementPolicies = oxr.spec.managementPolicies
            providerConfigRef = _providerConfigRef
            forProvider = {
                region = _region
                name = _dlqName
                if _fifo:
                    fifoQueue = True
                    contentBasedDeduplication = True
                visibilityTimeoutSeconds = _visibilityTimeout * 2
                messageRetentionSeconds = _messageRetention * 2
                sqsManagedSseEnabled = True
            }
        }
    }] if _dlqEnabled else []

    # Main SQS Queue
    _sqsItems += [{
        apiVersion = "sqs.aws.upbound.io/v1beta2"
        kind = "Queue"
        metadata = {
            name = oxr.metadata.name + "-sqs-queue"
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-sqs-queue"
            }
        }
        spec = {
            if oxr.spec.managementPolicies:
                managementPolicies = oxr.spec.managementPolicies
            providerConfigRef = _providerConfigRef
            forProvider = {
                region = _region
                name = _queueName
                if _fifo:
                    fifoQueue = True
                    contentBasedDeduplication = True
                visibilityTimeoutSeconds = _visibilityTimeout
                messageRetentionSeconds = _messageRetention
                maxMessageSize = _maxMessageSize
                delaySeconds = _delaySeconds
                receiveWaitTimeSeconds = _receiveWaitTime
                sqsManagedSseEnabled = True
                if _dlqEnabled and _dlqArn:
                    redrivePolicy = '{"deadLetterTargetArn": "' + _dlqArn + '", "maxReceiveCount": ' + str(_maxReceiveCount) + '}'
            }
        }
    }]

    # EKS Pod Identity for SQS access (if podIdentity is specified)
    if oxr.spec.podIdentity:
        _saName = oxr.spec.podIdentity.serviceAccountName
        _saNamespace = oxr.spec.podIdentity.serviceAccountNamespace
        _dlqArnForPolicy = _dlqArn if _dlqEnabled and _dlqArn else None

        # Build IAM policy JSON manually for proper formatting
        _mainQueueStatement = '{"Effect": "Allow", "Action": ["sqs:SendMessage", "sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl", "sqs:ChangeMessageVisibility"], "Resource": "' + _queueArn + '"}'
        _dlqStatement = ', {"Effect": "Allow", "Action": ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"], "Resource": "' + str(_dlqArnForPolicy) + '"}' if _dlqArnForPolicy else ""
        _policyJson = '{"Version": "2012-10-17", "Statement": [' + _mainQueueStatement + _dlqStatement + ']}'

        # IAM Role for Pod Identity
        _sqsItems += [{
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
            kind = "Role"
            metadata = _metadata("sqs-iam-role")
            spec = {
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
                providerConfigRef = _providerConfigRef
                forProvider = {
                    assumeRolePolicy = '{"Version": "2012-10-17", "Statement": [{"Effect": "Allow", "Principal": {"Service": "pods.eks.amazonaws.com"}, "Action": ["sts:AssumeRole", "sts:TagSession"]}]}'
                }
            }
        }]

        # IAM Policy for SQS access
        _sqsItems += [{
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
            kind = "Policy"
            metadata = _metadata("sqs-iam-policy")
            spec = {
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
                providerConfigRef = _providerConfigRef
                forProvider = {
                    policy = _policyJson
                }
            }
        }]

        # Role Policy Attachment
        _sqsItems += [{
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
            kind = "RolePolicyAttachment"
            metadata = _metadata("sqs-iam-role-policy-attachment")
            spec = {
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
                providerConfigRef = _providerConfigRef
                forProvider = {
                    policyArnSelector = {
                        matchControllerRef = True
                    }
                    roleSelector = {
                        matchControllerRef = True
                    }
                }
            }
        }]

        # Pod Identity Association
        _sqsItems += [{
            apiVersion = "eks.aws.m.upbound.io/v1beta1"
            kind = "PodIdentityAssociation"
            metadata = _metadata("sqs-pod-identity")
            spec = {
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
                providerConfigRef = _providerConfigRef
                forProvider = {
                    clusterName = _clusterName
                    serviceAccount = _saName
                    namespace = _saNamespace
                    region = _region
                    roleArnSelector = {
                        matchControllerRef = True
                    }
                }
            }
        }]

    # ConfigMap with queue URL (for application configuration)
    _sqsItems += [{
        apiVersion = "v1"
        kind = "ConfigMap"
        metadata = {
            name = oxr.spec.connectionSecret.name
            namespace = oxr.spec.connectionSecret.namespace if oxr.spec.connectionSecret?.namespace else oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-sqs-configmap"
                if _queueUrl:
                    "krm.kcl.dev/ready" = "True"
            }
        }
        data = {
            "queue.url" = _queueUrl if _queueUrl else "pending"
            "queue.name" = _queueName
            "queue.region" = _region
            if _dlqEnabled:
                "queue.dlq.name" = _dlqName
        }
    }] if oxr.spec.connectionSecret?.name else []

    # CiliumNetworkPolicy for SQS access (if enabled)
    _sqsItems += [{
        apiVersion = "cilium.io/v2"
        kind = "CiliumNetworkPolicy"
        metadata = {
            name = oxr.metadata.name + "-sqs-egress"
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-sqs-egress"
                "krm.kcl.dev/ready" = "True"
            }
        }
        spec = {
            description = "Allow egress to AWS SQS for " + oxr.metadata.name
            endpointSelector = {
                matchLabels = {
                    "queue.cloud.ogenki.io/name" = oxr.metadata.name
                }
            }
            egress = [
                {
                    toFQDNs = [
                        {matchPattern = "sqs." + _region + ".amazonaws.com"}
                        {matchPattern = "*.sqs." + _region + ".amazonaws.com"}
                    ]
                    toPorts = [
                        {
                            ports = [{port = "443", protocol = "TCP"}]
                        }
                    ]
                }
            ] + (oxr.spec.networkPolicies.additionalEgress if oxr.spec.networkPolicies?.additionalEgress else [])
        }
    }] if _networkPoliciesEnabled else []

# =============================================================================
# OUTPUT
# =============================================================================
items = _kafkaItems + _sqsItems
