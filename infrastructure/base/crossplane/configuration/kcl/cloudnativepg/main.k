oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_region = envConfig.region

_metadata = lambda suffix: str -> any {
    {
        name = oxr.metadata.name + "-" + suffix
        namespace = oxr.metadata.namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-" + suffix
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
        apiVersion = "postgresql.cnpg.io/v1"
        kind = "Cluster"
        metadata = {
            name = oxr.metadata.name + "-cnpg-cluster"
            namespace = oxr.metadata.namespace
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
                                    name = oxr.metadata.name + "-cnpg-" + oxr.spec.databases[0].name
                                }
                            if oxr.spec.initSQL:
                                postInitApplicationSQLRefs = {
                                    configMapRefs = [
                                        {
                                            name = oxr.metadata.name + "-cnpg-bootsrapsql"
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
                    name = oxr.metadata.name + "-cnpg-superuser"
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
                        name = oxr.metadata.name + "-cnpg-role-" + role.name
                    }
                } for role in oxr.spec.roles]
        }
    }
]
# Create ExternalSecrets for each role
if oxr.spec.roles:
    _items += [{
        apiVersion = "external-secrets.io/v1"
        kind = "ExternalSecret"
        metadata = {
            name = oxr.metadata.name + "-cnpg-role-" + role.name
            namespace = oxr.metadata.namespace
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
                        key = "cnpg/" + oxr.metadata.name + "/roles/" + role.name
                    }
                }
            ]
            target = {
                creationPolicy = "Owner"
                deletionPolicy = "Retain"
                name = oxr.metadata.name + "-cnpg-role-" + role.name
            }
        }
    } for role in oxr.spec.roles]

# Create databases
if oxr.spec.databases:
    _items += [{
        apiVersion = "postgresql.cnpg.io/v1"
        kind = "Database"
        metadata = {
            name = oxr.metadata.name + "-cnpg-" + oxr.spec.databases[0].name
            namespace = oxr.metadata.namespace
            if ocds?.status?.applied == "true":
                annotations = {
                    "krm.kcl.dev/ready": "True"
                }
        }
        spec = {
            name = db.name
            owner = db.owner
            cluster = {
                name = oxr.metadata.name + "-cnpg-cluster"
            }
        }
    } for db in oxr.spec.databases]

if oxr.spec.initSQL:
    _initSQL = oxr.spec.initSQL

    _items += [
        {
            apiVersion = "v1"
            kind = "ConfigMap"
            metadata = {
                name = oxr.metadata.name + "-cnpg-bootsrapsql"
                namespace = oxr.metadata.namespace
            }
            data = {
                "init.sql" = _initSQL
            }
        }
    ]

# Create superuser secret if requested
if oxr.spec.createSuperuser:
    _items += [
        {
            apiVersion = "external-secrets.io/v1"
            kind = "ExternalSecret"
            metadata = {
                name = oxr.metadata.name + "-cnpg-superuser"
                namespace = oxr.metadata.namespace
            }
            spec = {
                data = [
                    {
                        secretKey = "username"
                        remoteRef = {
                            key = "cnpg/" + oxr.metadata.name + "/superuser"
                            property = "username"
                        }
                    }
                    {
                        secretKey = "password"
                        remoteRef = {
                            key = "cnpg/" + oxr.metadata.name + "/superuser"
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
                    name = oxr.metadata.name + "-cnpg-superuser"
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
    ]

# Create daily backups using EKS pod identity for AWS auth
if oxr.spec.backup?.schedule:
    _items += [
        {
            apiVersion = "postgresql.cnpg.io/v1"
            kind = "ScheduledBackup"
            metadata = {
                name = oxr.metadata.name + "-cnpg-daily-backup"
                namespace = oxr.metadata.namespace
                # There isn't any field status that tells the resource is healthy so we need this annotation
                annotations = {
                    "krm.kcl.dev/ready": "True"
                }
            }
            spec = {
                schedule = oxr.spec.backup.schedule
                backupOwnerReference = "self"
                cluster = {
                    name = oxr.metadata.name + "-cnpg-cluster"
                }
            }
        }
        {
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
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
            }
        }
        {
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
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
            }
        }
        {
            apiVersion = "iam.aws.m.upbound.io/v1beta1"
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
            }
        }
        {
            apiVersion = "eks.aws.m.upbound.io/v1beta1"
            kind = "PodIdentityAssociation"
            metadata = _metadata("cnpg-pod-identity-association")
            spec: {
                forProvider = {
                    clusterName = envConfig.clusterName
                    serviceAccount = oxr.metadata.name + "-cnpg-cluster"
                    namespace = oxr.metadata.namespace
                    region = _region
                    roleArnSelector = {
                        matchControllerRef = True
                    }
                }
            }
        }
    ]

items = _items
