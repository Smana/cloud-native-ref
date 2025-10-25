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

_postgresVersion = oxr.spec.postgresVersion if oxr.spec.postgresVersion else "18"
_imageName = "ghcr.io/cloudnative-pg/postgresql:" + _postgresVersion + "-system-trixie"

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
            imageName = _imageName
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
            data = [
                {
                    secretKey = "username"
                    remoteRef = {
                        key = "cnpg/" + oxr.metadata.name + "/roles/" + role.name
                        property = "username"
                    }
                }
                {
                    secretKey = "password"
                    remoteRef = {
                        key = "cnpg/" + oxr.metadata.name + "/roles/" + role.name
                        property = "password"
                    }
                }
            ]
            target = {
                creationPolicy = "Owner"
                deletionPolicy = "Retain"
                name = oxr.metadata.name + "-cnpg-role-" + role.name
                if oxr.spec.atlasSchema:
                    template = {
                        engineVersion = "v2"
                        data = {
                            username = "{{ .username }}"
                            password = "{{ .password }}"
                            uri = "postgresql://{{ .username | urlquery }}:{{ .password | urlquery }}@" + oxr.metadata.name + "-cnpg-cluster-rw." + oxr.metadata.namespace + ".svc:5432/" + [db.name for db in oxr.spec.databases if db.owner == role.name][0]
                        }
                    }
            }
        }
    } for role in oxr.spec.roles]

# Create databases
if oxr.spec.databases:
    _items += [{
        apiVersion = "postgresql.cnpg.io/v1"
        kind = "Database"
        metadata = {
            name = oxr.metadata.name + "-cnpg-" + db.name
            namespace = oxr.metadata.namespace
            annotations = {
                "krm.kcl.dev/ready": "True"
            } if ocds?[oxr.metadata.name + "-cnpg-" + db.name]?.Resource?.status?.applied == True else {}
        }
        spec = {
            name = db.name
            owner = db.owner
            cluster = {
                name = oxr.metadata.name + "-cnpg-cluster"
            }
        }
    } for db in oxr.spec.databases]

    # Atlas Schema Migrations per database - GitOps Pattern
    # When atlasSchema is defined, creates a complete migration pipeline per database:
    # 1. GitRepository - Flux pulls migration files from Git (url, ref, path)
    # 2. Kustomization - Generates ConfigMap from migrations using configMapGenerator
    # 3. AtlasMigration - Applies migrations using ConfigMap reference
    
    # Helper: Conditional suffix for Atlas resources to avoid name duplication
    # When there's only one database, omit the database name from resource names
    # Example: xplane-image-gallery-atlas-migrations-repo (single DB)
    #          xplane-image-gallery-db1-atlas-migrations-repo (multiple DBs)
    _atlasNameSuffix = lambda dbName: str -> str {
        "" if len(oxr.spec.databases) == 1 else "-" + dbName
    }

    if oxr.spec.atlasSchema:
        # Validate required atlasSchema fields
        assert oxr.spec.atlasSchema.url, "atlasSchema.url is required when atlasSchema is enabled"
        assert oxr.spec.atlasSchema.ref, "atlasSchema.ref is required when atlasSchema is enabled"
        assert oxr.spec.atlasSchema.path, "atlasSchema.path is required when atlasSchema is enabled"

        # GitRepository per database
        _items += [{
            apiVersion = "source.toolkit.fluxcd.io/v1"
            kind = "GitRepository"
            metadata = {
                name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migrations-repo"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                url = oxr.spec.atlasSchema.url
                ref = {
                    if oxr.spec.atlasSchema.ref.startswith("v"):
                        tag = oxr.spec.atlasSchema.ref
                    else:
                        branch = oxr.spec.atlasSchema.ref
                }
            }
        } for db in oxr.spec.databases]

        # Kustomization per database
        _items += [{
            apiVersion = "kustomize.toolkit.fluxcd.io/v1"
            kind = "Kustomization"
            metadata = {
                name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migrations-configmap"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                sourceRef = {
                    kind = "GitRepository"
                    name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migrations-repo"
                }
                path = oxr.spec.atlasSchema.path
                prune = True
                targetNamespace = oxr.metadata.namespace
            }
        } for db in oxr.spec.databases]

        # AtlasMigration per database
        _items += [{
            apiVersion = "db.atlasgo.io/v1alpha1"
            kind = "AtlasMigration"
            metadata = {
                name = oxr.metadata.name + _atlasNameSuffix(db.name) + "-atlas-migration"
                namespace = oxr.metadata.namespace
            }
            spec = {
                urlFrom = {
                    secretKeyRef = {
                        key = "uri"
                        # Connect using the database owner's role secret
                        name = oxr.metadata.name + "-cnpg-role-" + db.owner
                    }
                }
                dir = {
                    configMapRef = {
                        name = "atlas-db-migrations"
                    }
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
elif oxr.spec.createSuperuser and oxr.spec.atlasSchema:
    # Atlas Schema Migrations for superuser mode (when no databases are defined) - GitOps Pattern
    # When atlasSchema is defined with superuser only, creates a migration pipeline:
    # 1. GitRepository - Flux pulls migration files from Git
    # 2. Kustomization - Generates ConfigMap from migrations
    # 3. AtlasMigration - Applies migrations using superuser credentials
    
    # Validate required atlasSchema fields
    assert oxr.spec.atlasSchema.url, "atlasSchema.url is required when atlasSchema is enabled"
    assert oxr.spec.atlasSchema.ref, "atlasSchema.ref is required when atlasSchema is enabled"
    assert oxr.spec.atlasSchema.path, "atlasSchema.path is required when atlasSchema is enabled"

    _items += [
        {
            apiVersion = "source.toolkit.fluxcd.io/v1"
            kind = "GitRepository"
            metadata = {
                name = oxr.metadata.name + "-atlas-migrations-repo"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                url = oxr.spec.atlasSchema.url
                ref = {
                    if oxr.spec.atlasSchema.ref.startswith("v"):
                        tag = oxr.spec.atlasSchema.ref
                    else:
                        branch = oxr.spec.atlasSchema.ref
                }
            }
        }
        {
            apiVersion = "kustomize.toolkit.fluxcd.io/v1"
            kind = "Kustomization"
            metadata = {
                name = oxr.metadata.name + "-atlas-migrations-configmap"
                namespace = oxr.metadata.namespace
            }
            spec = {
                interval = "10m"
                sourceRef = {
                    kind = "GitRepository"
                    name = oxr.metadata.name + "-atlas-migrations-repo"
                }
                path = oxr.spec.atlasSchema.path
                prune = True
                targetNamespace = oxr.metadata.namespace
            }
        }
        {
            apiVersion = "db.atlasgo.io/v1alpha1"
            kind = "AtlasMigration"
            metadata = {
                name = oxr.metadata.name + "-atlas-migration"
                namespace = oxr.metadata.namespace
            }
            spec = {
                urlFrom = {
                    secretKeyRef = {
                        key = "uri"
                        # Use superuser secret for migrations
                        name = oxr.metadata.name + "-cnpg-superuser"
                    }
                }
                dir = {
                    configMapRef = {
                        name = "atlas-db-migrations"
                    }
                }
            }
        }
    ]

# Create daily backups using EKS pod identity for AWS auth
if oxr.spec.backup?.schedule:
    _backupResources = [
        {
            apiVersion = "postgresql.cnpg.io/v1"
            kind = "ScheduledBackup"
            metadata = {
                name = oxr.metadata.name + "-cnpg-daily-backup"
                namespace = oxr.metadata.namespace
                # We need this annotations because there aren't any field status that tells the resource is healthy
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
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
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
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
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
                if oxr.spec.managementPolicies:
                    managementPolicies = oxr.spec.managementPolicies
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
    _items += _backupResources

items = _items
