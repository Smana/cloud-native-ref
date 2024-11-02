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
                        bootstrap = {
                            initdb = {
                                database = oxr.spec.claimRef.name
                                owner = oxr.spec.claimRef.name + "-owner"
                                secret = {
                                    name = oxr.spec.claimRef.name + "-cnpg-owner"
                                }
                            }
                        }
                        if oxr.spec.cnpg.backup:
                            backup = {
                                barmanObjectStore = {
                                    destinationPath = "s3://" + oxr.spec.cnpg.backup.bucketName + "/" + oxr.spec.claimRef.name
                                }
                            }
                        storage = {
                            size = oxr.spec.cnpg.storage.size
                            storageClassName = oxr.spec.cnpg.storage.storageClassName
                        }
                        resources = oxr.spec.cnpg.resources
                    }
                }
            }
        }
    }
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata("cnpg-owner")
        spec = {
            deletionPolicy = _deletionPolicy
            forProvider = {
                manifest = {
                    apiVersion = "external-secrets.io/v1beta1"
                    kind = "ExternalSecret"
                    metadata = {
                        name = oxr.spec.claimRef.name + "-cnpg-owner"
                        namespace = oxr.spec.claimRef.namespace
                    }
                    spec = {
                        dataFrom = [
                            {
                                extract = {
                                    conversionStrategy = "default"
                                    key = "cnpg/" + oxr.spec.claimRef.name + "/owner"
                                }
                            }
                        ]
                        refreshInterval = "30m"
                        secretStoreRef = {
                            kind = "ClusterSecretStore"
                            name = "clustersecretstore"
                        }
                        target = {
                            creationPolicy = "Owner"
                            deletionPolicy = "Owner"
                            name = oxr.spec.claimRef.name + "-cnpg-owner"
                        }
                    }
                }
            }
        }
    }
]

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
    "Version": "2012-10-17"
    "Statement": [
        {
            "Effect": "Allow"
            "Action": [
                "s3:GetObject"
                "s3:PutObject"
            ]
            "Resource": "arn:aws:s3:::${oxr.spec.cnpg.backup.bucketName}/${oxr.spec.claimRef.name}/*"
        }
        {
            "Effect": "Allow"
            "Action": "s3:ListBucket"
            "Resource": "arn:aws:s3:::{oxr.spec.cnpg.backup.bucketName}"
            "Condition": {
                "StringLike": {
                    "s3:prefix": "${oxr.spec.claimRef.name}/*"
                }
            }
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
                    serviceAccount = oxr.spec.claimRef.name
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
