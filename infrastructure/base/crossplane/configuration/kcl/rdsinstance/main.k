oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

if oxr.spec?.rds?.region:
    _region = oxr.spec.rds.region
elif envConfig?.region:
    _region = envConfig.region

if oxr.spec?.rds?.engine == "postgres":
    _dbPort = 5432
elif oxr.spec?.rds?.engine == "mariadb":
    _dbPort = 3306

if oxr.spec?.deletionPolicy:
    _deletionPolicy = oxr.spec.deletionPolicy

_metadata = lambda suffix: str -> any {
    {
        name = oxr.spec.claimRef.name + "-" + suffix
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.spec.claimRef.name + "-" + suffix
        }
    }
}

_items = []

if oxr.spec?.rds:
    _items += [
        {
            apiVersion = "rds.aws.upbound.io/v1beta1"
            kind = "SubnetGroup"
            metadata = _metadata("rds-subnet-group")
            spec: {
                providerConfigRef.name = oxr.spec.rds.providerConfigName
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
            metadata = _metadata("rds-security-group")
            spec = {
                providerConfigRef.name = oxr.spec.rds.providerConfigName
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
            metadata = _metadata("rds-security-group-rule")
            spec = {
                providerConfigRef.name = oxr.spec.rds.providerConfigName
                deletionPolicy = _deletionPolicy
                forProvider = {
                    cidrBlocks = [envConfig.CIDRBlock]
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
            metadata = _metadata("rds-instance")
            spec = {
                forProvider = {
                    identifierPrefix = oxr.spec.claimRef.name
                    region = _region
                    dbName = oxr.spec.rds.dbName
                    port = _dbPort
                    engine = oxr.spec.rds.engine
                    if oxr.spec?.rds?.engineVersion:
                        engineVersion = oxr.spec.rds.engineVersion
                    if oxr.spec.size == "small":
                        instanceClass = "db.t3.small"
                    elif oxr.spec.size == "medium":
                        instanceClass = "db.t3.medium"
                    elif oxr.spec.size == "large":
                        instanceClass = "db.t3.large"
                    dbSubnetGroupNameSelector = {matchControllerRef = True}
                    vpcSecurityGroupIdSelector = {matchControllerRef = True}
                    allocatedStorage = oxr.spec.storageGB
                    skipFinalSnapshot = True
                    username = "master"
                    passwordSecretRef = {
                        name = oxr.spec.rds.passwordSecretRef.name
                        namespace = oxr.spec.claimRef.namespace
                        key = "password"
                    }
                }
                writeConnectionSecretToRef = {
                    name = oxr.spec.claimRef.name + "-rds-connection"
                    namespace = oxr.spec.claimRef.namespace
                }
            }
        }
        {
            apiVersion = "kubernetes.crossplane.io/v1alpha2"
            kind = "Object"
            metadata = _metadata("rds-service")
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
                            if oxr.spec.claimRef.name + "-rds-instance" in ocds:
                                externalName = ocds[oxr.spec.claimRef.name + "-rds-instance"].Resource.status.atProvider.address
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
