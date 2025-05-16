oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

if oxr.spec.deletionPolicy:
    _deletionPolicy = oxr.spec.deletionPolicy

_region = envConfig.region

_metadata = lambda suffix: str -> any {
    {
        name = oxr.spec.claimRef.name + "-" + suffix
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.spec.claimRef.name + "-" + suffix
        }
    }
}
# Set the instance size
if oxr.spec.size == "small":
    _instanceResources = {
        requests: {
            cpu: "0.5"
            memory: "1Gi"
        }
        limits: {
            cpu: "1"
            memory: "1Gi"
        }
    }
elif oxr.spec.size == "medium":
    _instanceResources = {
        requests: {
            cpu: "1"
            memory: "3Gi"
        }
        limits: {
            cpu: "2"
            memory: "3Gi"
        }
    }
elif oxr.spec.size == "large":
    _instanceResources = {
        requests: {
            cpu: "2"
            memory: "8Gi"
        }
        limits: {
            cpu: "4"
            memory: "8Gi"
        }
    }

_items = []

_items = [
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata("cnpg-cluster")
        spec = {
            deletionPolicy = _deletionPolicy
            forProvider = {
                manifest = {
                    apiVersion = "postgresql.cnpg.io/v1"
                    kind = "Cluster"
                    metadata = {
                        name = oxr.spec.claimRef.name + "-cnpg-cluster"
                        namespace = oxr.spec.claimRef.namespace
                    }
                    spec = {
                        instances = oxr.spec.instances
                        primaryUpdateStrategy = oxr.spec.primaryUpdateStrategy
                        if oxr.spec.createSuperuser:
                            enableSuperuserAccess = True
                        if oxr.spec.initSQL or oxr.spec.databases or oxr.spec.objectStoreRecovery:
                            bootstrap = {
                                if oxr.spec.objectStoreRecovery:
                                    recovery: {
                                        source: oxr.spec.objectStoreRecovery.path
                                    }
                                else:
                                    initdb = {
                                        if oxr.spec.databases:
                                            database = oxr.spec.databases[0].name
                                            owner = oxr.spec.databases[0].owner
                                            secret = {
                                                name = oxr.spec.claimRef.name + "-cnpg-" + oxr.spec.databases[0].name
                                            }
                                        if oxr.spec.initSQL:
                                            postInitApplicationSQLRefs = {
                                                configMapRefs = [
                                                    {
                                                        name = oxr.spec.claimRef.name + "-cnpg-bootsrapsql"
                                                        key = "init.sql"
                                                    }
                                                ]
                                            }
                                    }
                            }
                        if oxr.spec.backup:
                            backup = {
                                barmanObjectStore = {
                                    destinationPath = "s3://" + oxr.spec.backup.bucketName
                                    s3Credentials = {
                                        inheritFromIAMRole = True
                                    }
                                    wal = {
                                        compression = "bzip2"
                                    }
                                    data = {
                                        compression = "bzip2"
                                    }
                                }
                                retentionPolicy = oxr.spec.backup.retentionPolicy
                            }
                        if oxr.spec.createSuperuser:
                            superuserSecret = {
                                name = oxr.spec.claimRef.name + "-cnpg-superuser"
                            }
                        storage = {
                            size = oxr.spec.storageSize
                            storageClassName = oxr.spec.storageClassName
                        }
                        monitoring = {
                            enablePodMonitor = True
                        }
                        resources = _instanceResources
                        if oxr.spec.objectStoreRecovery:
                            externalClusters = [
                                {
                                    name = oxr.spec.objectStoreRecovery.path
                                    barmanObjectStore = {
                                        destinationPath = "s3://" + oxr.spec.objectStoreRecovery.bucketName
                                        s3Credentials = {
                                            inheritFromIAMRole = True
                                        }
                                        wal: {
                                            maxParallel: 8
                                        }
                                    }
                                }
                            ]
                        if oxr.spec.roles:
                            managed.roles = [{
                                name = role.name
                                comment = role.comment
                                login = True
                                superuser = role.superuser
                                inRoles = role.inRoles
                                passwordSecret = {
                                    name = oxr.spec.claimRef.name + "-cnpg-role-" + role.name
                                }
                            } for role in oxr.spec.roles]
                    }
                }
            }
        }
    }
]
# Create ExternalSecrets for each role
if oxr.spec.roles:
    _items += [{
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata("cnpg-externalsecret-" + role.name)
        spec = {
            deletionPolicy = _deletionPolicy
            forProvider = {
                manifest = {
                    apiVersion = "external-secrets.io/v1"
                    kind = "ExternalSecret"
                    metadata = {
                        name = oxr.spec.claimRef.name + "-cnpg-role-" + role.name
                        namespace = oxr.spec.claimRef.namespace
                    }
                    spec = {
                        refreshInterval = "30m"
                        secretStoreRef = {
                            kind = "ClusterSecretStore"
                            name = "clustersecretstore"
                        }
                        dataFrom = [
                            {
                                extract = {
                                    conversionStrategy = "Default"
                                    key = "cnpg/" + oxr.spec.claimRef.name + "/roles/" + role.name
                                }
                            }
                        ]
                        target = {
                            creationPolicy = "Owner"
                            deletePolicy = "Retain"
                            name = oxr.spec.claimRef.name + "-cnpg-role-" + role.name
                        }
                    }
                }
            }
        }
    } for role in oxr.spec.roles]

# Create databases
if oxr.spec.databases:
    _items += [{
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata("cnpg-database-" + db.name)
        spec = {
            deletionPolicy = _deletionPolicy
            forProvider = {
                manifest = {
                    apiVersion = "postgresql.cnpg.io/v1"
                    kind = "Database"
                    metadata = {
                        name = oxr.spec.claimRef.name + "-cnpg-" + oxr.spec.databases[0].name
                        namespace = oxr.spec.claimRef.namespace
                    }
                    spec = {
                        name = db.name
                        owner = db.owner
                        cluster = {
                            name = oxr.spec.claimRef.name + "-cnpg-cluster"
                        }
                    }
                }
            }
        }
    } for db in oxr.spec.databases]

if oxr.spec.initSQL:
    _initSQL = oxr.spec.initSQL

_items += [
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata("cnpg-bootsrapsql")
        spec = {
            deletionPolicy = _deletionPolicy
            forProvider = {
                manifest = {
                    apiVersion = "v1"
                    kind = "ConfigMap"
                    metadata = {
                        name = oxr.spec.claimRef.name + "-cnpg-bootsrapsql"
                        namespace = oxr.spec.claimRef.namespace
                    }
                    data = {
                        "init.sql" = _initSQL
                    }
                }
            }
        }
    }
]
# Create superuser secret if requested
if oxr.spec.createSuperuser:
    _items += [
        {
            apiVersion = "kubernetes.crossplane.io/v1alpha2"
            kind = "Object"
            metadata = _metadata("cnpg-superuser")
            spec = {
                deletionPolicy = _deletionPolicy
                forProvider = {
                    manifest = {
                        apiVersion = "external-secrets.io/v1"
                        kind = "ExternalSecret"
                        metadata = {
                            name = oxr.spec.claimRef.name + "-cnpg-superuser"
                            namespace = oxr.spec.claimRef.namespace
                        }
                        spec = {
                            data = [
                                {
                                    secretKey = "username"
                                    remoteRef = {
                                        key = "cnpg/" + oxr.spec.claimRef.name + "/superuser"
                                        property = "username"
                                    }
                                }
                                {
                                    secretKey = "password"
                                    remoteRef = {
                                        key = "cnpg/" + oxr.spec.claimRef.name + "/superuser"
                                        property = "password"
                                    }
                                }
                            ]
                            refreshInterval = "30m"
                            secretStoreRef = {
                                kind = "ClusterSecretStore"
                                name = "clustersecretstore"
                            }
                            target = {
                                name = oxr.spec.claimRef.name + "-cnpg-superuser"
                                template = {
                                    type = "kubernetes.io/basic-auth"
                                    data = {
                                        username = '{{.username}}'
                                        password = '{{.password}}'
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    ]

# Create daily backups using EKS pod identity for AWS auth
if oxr.spec.backup?.schedule:
    _items += [
        {
            apiVersion = "kubernetes.crossplane.io/v1alpha2"
            kind = "Object"
            metadata = _metadata("cnpg-daily-backup")
            spec = {
                deletionPolicy = _deletionPolicy
                forProvider = {
                    manifest = {
                        apiVersion = "postgresql.cnpg.io/v1"
                        kind = "ScheduledBackup"
                        metadata = {
                            name = oxr.spec.claimRef.name + "-cnpg-daily-backup"
                            namespace = oxr.spec.claimRef.namespace
                        }
                        spec = {
                            schedule = oxr.spec.backup.schedule
                            backupOwnerReference = "self"
                            cluster = {
                                name = oxr.spec.claimRef.name + "-cnpg-cluster"
                            }
                        }
                    }
                }
            }
        }
        {
            apiVersion = "iam.aws.upbound.io/v1beta1"
            kind = "Role"
            metadata = _metadata("cnpg-iam-role")
            spec: {
                forProvider = {
                    assumeRolePolicy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}
"""
                }
                deletionPolicy = _deletionPolicy
            }
        }
        {
            apiVersion = "iam.aws.upbound.io/v1beta1"
            kind = "Policy"
            metadata = _metadata("cnpg-iam-policy")
            spec: {
                forProvider = {
                    policy = """{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket"
            ],
            "Resource": "arn:aws:s3:::${oxr.spec.backup.bucketName}"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:*"
            ],
            "Resource": "arn:aws:s3:::${oxr.spec.backup.bucketName}/*"
        }
    ]
}
"""
                }
                deletionPolicy = _deletionPolicy
            }
        }
        {
            apiVersion = "iam.aws.upbound.io/v1beta1"
            kind = "RolePolicyAttachment"
            metadata = _metadata("cnpg-iam-role-policy-attachment")
            spec: {
                forProvider = {
                    policyArnSelector = {
                        matchControllerRef = True
                    }
                    roleSelector = {
                        matchControllerRef: True
                    }
                }
                deletionPolicy = _deletionPolicy
            }
        }
        {
            apiVersion = "eks.aws.upbound.io/v1beta1"
            kind = "PodIdentityAssociation"
            metadata = _metadata("cnpg-pod-identity-association")
            spec: {
                forProvider = {
                    clusterName = envConfig.clusterName
                    serviceAccount = oxr.spec.claimRef.name + "-cnpg-cluster"
                    namespace = oxr.spec.claimRef.namespace
                    region = _region
                    roleArnSelector = {
                        matchControllerRef = True
                    }
                }
                deletionPolicy = _deletionPolicy
            }
        }
    ]

items = _items
