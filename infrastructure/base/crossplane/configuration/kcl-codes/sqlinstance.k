import base64

oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

schema aws:
    _region: str = "eu-west-3"
    _providerConfigRef?: str
    _deletionPolicy?: str

if oxr.spec?.parameters?.region:
    _region = oxr.spec.parameters.region
elif envConfig?.region:
    _region = envConfig.region

if oxr.spec.parameters.engine == "postgres":
    _dbPort = 5432
elif oxr.spec.parameters.engine == "mariadb":
    _dbPort = 3306

if oxr.spec?.parameters?.deletionPolicy:
    _deletionPolicy = oxr.spec.parameters.deletionPolicy

_metadata = lambda resourceName: str -> any {
    {
        name = oxr.spec.claimRef.name
        annotations = {
            "krm.kcl.dev/composition-resource-name" = resourceName
        }
    }
}

_items = [
    {
        apiVersion = "rds.aws.upbound.io/v1beta1"
        kind = "SubnetGroup"
        metadata = _metadata(oxr.spec.claimRef.name + "-subnet-group")
        spec: {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            forProvider = {
                description = "List of subnets to attach the RDS instance to."
                subnetIds = envConfig.privateSubnetIds
                region = _region
            }
        }
        deletionPolicy = _deletionPolicy
    }
    {
        apiVersion = "ec2.aws.upbound.io/v1beta1"
        kind = "SecurityGroup"
        metadata = _metadata(oxr.spec.claimRef.name + "-security-group")
        spec = {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            deletionPolicy = _deletionPolicy
            forProvider = {
                name = oxr.spec.claimRef.name
                description = "Allow RDS Inbound traffic"
                vpcId = envConfig.vpcId
                region = _region
            }
        }
    }
    {
        apiVersion = "ec2.aws.upbound.io/v1beta1"
        kind = "SecurityGroupRule"
        metadata = _metadata(oxr.spec.claimRef.name + "-security-group-rule")
        spec = {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            deletionPolicy = _deletionPolicy
            forProvider = {
                cidrBlocks = [envConfig.vpc_cidr_block]
                protocol = "tcp"
                region = _region
                securityGroupIdSelector = {matchControllerRef = True}
                fromPort = _dbPort
                toPort = _dbPort
                type = "ingress"
            }
        }
    }
    {
        apiVersion = "rds.aws.upbound.io/v1beta2"
        kind = "Instance"
        metadata = _metadata(oxr.spec.claimRef.name + "-rds-instance")
        spec = {
            forProvider = {
                identifierPrefix = oxr.spec.claimRef.name
                region = _region
                dbName = oxr.spec.parameters.dbName
                port = _dbPort
                engine = oxr.spec.parameters.engine
                if oxr.spec?.parameters?.engineVersion:
                    engineVersion = oxr.spec.parameters.engineVersion
                if oxr.spec.parameters.size == "small":
                    instanceClass = "db.t3.small"
                elif oxr.spec.parameters.size == "medium":
                    instanceClass = "db.t3.medium"
                elif oxr.spec.parameters.size == "large":
                    instanceClass = "db.t3.large"
                dbSubnetGroupNameSelector = {matchControllerRef = True}
                vpcSecurityGroupIdSelector = {matchControllerRef = True}
                allocatedStorage = oxr.spec.parameters.storageGB
                skipFinalSnapshot = True
                username = "master"
                passwordSecretRef = {
                    name = oxr.spec.parameters.passwordSecretRef.name
                    if oxr.spec?.parameters?.passwordSecretRef?.namespace:
                        namespace = oxr.spec.claimRef.namespace
                    else:
                        namespace = oxr.spec.claimRef.namespace
                    key = "password"
                }
            }
        }
    }
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata(oxr.spec.claimRef.name + "-rds-secret")
        spec = {
            references = [
                {
                    patchesFrom = {
                        apiVersion = "rds.aws.upbound.io/v1beta1"
                        kind = "Instance"
                        name = oxr.spec.claimRef.name
                        namespace = "crossplane-system"
                        fieldPath = "spec.forProvider.username"
                    }
                    toFieldPath = "stringData.username"
                }
                {
                    patchesFrom = {
                        apiVersion = "v1"
                        kind = "Secret"
                        name = oxr.spec.parameters.passwordSecretRef.name
                        if oxr.spec?.parameters?.passwordSecretRef?.namespace:
                            namespace = oxr.spec.claimRef.namespace
                        else:
                            namespace = oxr.spec.claimRef.namespace
                        fieldPath = "data.password"
                    }
                    toFieldPath = "data.password"
                }
                {
                    patchesFrom = {
                        apiVersion = "rds.aws.upbound.io/v1beta1"
                        kind = "Instance"
                        name = oxr.spec.claimRef.name
                        namespace = "crossplane-system"
                        fieldPath = "status.atProvider.address"
                    }
                    toFieldPath = "stringData.endpoint"
                }
            ]
            forProvider.manifest = {
                apiVersion = "v1"
                kind = "Secret"
                metadata = {
                    name = oxr.spec.claimRef.name
                    namespace = oxr.spec.claimRef.namespace
                }
                data.port = base64.encode(str(_dbPort))
            }
            providerConfigRef.name = oxr.spec.id + "-sql"
        }
    }
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha2"
        kind = "Object"
        metadata = _metadata(oxr.spec.claimRef.name + "-rds-service")
        spec = {
            forProvider = {
                manifest = {
                    apiVersion = "v1"
                    kind = "Service"
                    metadata = {
                        name = oxr.spec.claimRef.name + "-rds-service"
                        namespace = oxr.spec.claimRef.namespace
                    }
                    spec = {
                        externalName = oxr.spec.claimRef.name + "-rds-instance"
                        ports = [
                            {
                                port = _dbPort
                                targetPort = _dbPort
                            }
                        ]
                        type = "ExternalName"
                    }
                }
            }
        }
    }
]

items = _items
