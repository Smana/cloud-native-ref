oxr = option("params").oxr
ocds = option("params").ocds
#envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]
envConfig = {
    "region": "eu-west-3"
    "privateSubnetIds": ["subnet-0b1e7b7b1b1b1b1b1", "subnet-0b1e7b7b1b1b1b1b2"]
}

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

_metadata = lambda suffix: str -> any {
    {
        name = oxr.spec.claimRef.name + "-" + suffix
        namespace = oxr.spec.claimRef.namespace
        labels = {
            "app.kubernetes.io/managed-by": "crossplane"
        }
    }
}

_items = [
    {
        apiVersion = "rds.aws.upbound.io/v1beta1"
        kind = "SubnetGroup"
        metadata = _metadata(oxr.spec.claimRef.name)
        spec: {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            forProvider: {
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
        metadata = _metadata(oxr.spec.claimRef.name)
        spec = {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            deletionPolicy = _deletionPolicy
            forProvider = {
                description = "Allow RDS Inbound traffic"
                vpcId = oxr.spec.vpcId
                region = _region
            }
        }
    }
    {
        apiVersion = "ec2.aws.upbound.io/v1beta1"
        kind = "SecurityGroupRule"
        metadata = _metadata(oxr.spec.claimRef.name)
        spec = {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            deletionPolicy = _deletionPolicy
            forProvider = {
                cidrIpv4 = oxr.spec.parameters.CIDRBlock
                ipProtocol = "tcp"
                region = _region
                securityGroupIdSelector = {matchControllerRef = True}
                fromPort = _dbPort
                toPort = _dbPort
            }
        }
    }
    {
        apiVersion = "rds.aws.upbound.io/v1beta2"
        kind = "Instance"
        metadata = _metadata(oxr.spec.claimRef.name)
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
                passwordSecretRef = {
                    name = oxr.spec.id + "-password"
                    namespace = oxr.spec.claimRef.namespace
                    key = "password"
                }
            }
        }
    }
    {
        apiVersion = "kubernetes.crossplane.io/v1alpha1"
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
