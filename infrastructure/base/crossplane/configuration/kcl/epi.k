oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

if oxr.spec?.parameters?.region:
    _region = oxr.spec.parameters.region
elif envConfig?.region:
    _region = envConfig.region

if oxr.spec?.parameters?.deletionPolicy:
    _deletionPolicy = oxr.spec.parameters.deletionPolicy

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
        apiVersion = "iam.aws.upbound.io/v1beta1"
        kind = "Role"
        metadata = _metadata("iam-role")
        spec: {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
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
        deletionPolicy = _deletionPolicy
    }
    {
        apiVersion = "iam.aws.upbound.io/v1beta1"
        kind = "Policy"
        metadata = _metadata("iam-policy")
        spec: {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            forProvider = {
                policy = oxr.spec.parameters.policyDocument
            }
            deletionPolicy = _deletionPolicy
        }
    }
    {
        apiVersion = "iam.aws.upbound.io/v1beta1"
        kind = "RolePolicyAttachment"
        metadata = _metadata("iam-role-policy-attachment")
        spec: {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            forProvider = {
                policyArnSelector = {
                    matchControllerRef = True
                }
                roleSelector = {
                    matchControllerRef: True
                }
            }
        }
        deletionPolicy = _deletionPolicy
    }
    {
        apiVersion = "eks.aws.upbound.io/v1beta1"
        kind = "PodIdentityAssociation"
        metadata = _metadata("pod-identity-association")
        spec: {
            providerConfigRef.name = oxr.spec.parameters.providerConfigName
            forProvider = {
                clusterName = oxr.spec.parameters.clusterName
                serviceAccount = oxr.spec.parameters.serviceAccount.name
                namespace = oxr.spec.parameters.serviceAccount.namespace
                region = _region
                roleArnSelector = {
                    matchControllerRef = True
                }
            }
        }
        deletionPolicy = _deletionPolicy
    }
]

items = _items
