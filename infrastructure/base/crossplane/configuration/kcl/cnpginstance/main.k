oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

if oxr.spec?.cnpg?.deletionPolicy:
    _deletionPolicy = oxr.spec.cnpg.deletionPolicy

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

if oxr.spec.cnpg:
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
                            instances = oxr.spec.cnpg.instances
                            primaryUpdateStrategy = oxr.spec.cnpg.primaryUpdateStrategy
                            if oxr.spec.cnpg?.createSuperuser:
                                enableSuperuserAccess = True
                            if oxr.spec.cnpg?.initSQL or oxr.spec.cnpg?.databases or oxr.spec.cnpg?.objectStoreRecovery:
                                bootstrap = {
                                    if oxr.spec.cnpg.objectStoreRecovery:
                                        recovery: {
                                            source: oxr.spec.cnpg.objectStoreRecovery.path
                                        }
                                    else:
                                        initdb = {
                                            if oxr.spec.databases:
                                                database = oxr.spec.databases[0].name
                                                owner = oxr.spec.databases[0].owner
                                                secret = {
                                                    name = oxr.spec.claimRef.name + "-cnpg-" + oxr.spec.databases[0].name
                                                }
                                            if oxr.spec.cnpg?.initSQL:
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
                            if oxr.spec.cnpg.backup:
                                backup = {
                                    barmanObjectStore = {
                                        destinationPath = "s3://" + oxr.spec.cnpg.backup.bucketName
                                        s3Credentials = {
                                            inheritFromIAMRole = True
                                        }
                                    }
                                }
                            if oxr.spec.cnpg?.createSuperuser:
                                superuserSecret = {
                                    name = oxr.spec.claimRef.name + "-cnpg-superuser"
                                }
                            storage = {
                                size = str(oxr.spec.storageGB) + "Gi"
                                storageClassName = oxr.spec.cnpg.storageClassName
                            }
                            monitoring = {
                                enablePodMonitor = True
                            }
                            resources = _instanceResources
                            if oxr.spec.cnpg.objectStoreRecovery:
                                externalClusters = [
                                    {
                                        name = oxr.spec.cnpg.objectStoreRecovery.path
                                        barmanObjectStore = {
                                            destinationPath = "s3://" + oxr.spec.cnpg.objectStoreRecovery.bucketName
                                            s3Credentials = {
                                                inheritFromIAMRole = True
                                            }
                                            wal: {
                                                maxParallel: 8
                                            }
                                        }
                                    }
                                ]
                        }
                    }
                }
            }
        }
    ]

    if oxr.spec.databases:
        _items += [{
            apiVersion = "kubernetes.crossplane.io/v1alpha2"
            kind = "Object"
            metadata = _metadata("cnpg-externalsecret-" + oxr.spec.databases[0].name)
            spec = {
                deletionPolicy = _deletionPolicy
                forProvider = {
                    manifest = {
                        apiVersion = "external-secrets.io/v1beta1"
                        kind = "ExternalSecret"
                        metadata = {
                            name = oxr.spec.claimRef.name + "-cnpg-" + oxr.spec.databases[0].name
                            namespace = oxr.spec.claimRef.namespace
                        }
                        spec = {
                            data = [
                                {
                                    secretKey = "username"
                                    remoteRef = {
                                        key = "cnpg/" + oxr.spec.claimRef.name + "/" + oxr.spec.databases[0].name
                                        property = "username"
                                    }
                                }
                                {
                                    secretKey = "password"
                                    remoteRef = {
                                        key = "cnpg/" + oxr.spec.claimRef.name + "/" + oxr.spec.databases[0].name
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
                                name = oxr.spec.claimRef.name + "-cnpg-" + oxr.spec.databases[0].name
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
        }]

    if oxr.spec.cnpg?.initSQL:
        _initSQL = oxr.spec.cnpg.initSQL

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
    if oxr.spec.cnpg?.createSuperuser:
        _items += [
            {
                apiVersion = "kubernetes.crossplane.io/v1alpha2"
                kind = "Object"
                metadata = _metadata("cnpg-superuser")
                spec = {
                    deletionPolicy = _deletionPolicy
                    forProvider = {
                        manifest = {
                            apiVersion = "external-secrets.io/v1beta1"
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
    if oxr.spec.cnpg.backup?.schedule:
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
                                schedule = oxr.spec.cnpg.backup.schedule
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
                "Resource": "arn:aws:s3:::${oxr.spec.cnpg.backup.bucketName}"
            },
            {
                "Effect": "Allow",
                "Action": [
                    "s3:*"
                ],
                "Resource": "arn:aws:s3:::${oxr.spec.cnpg.backup.bucketName}/*"
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
