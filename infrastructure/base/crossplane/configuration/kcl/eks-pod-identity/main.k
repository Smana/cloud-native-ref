oxr = option("params").oxr
ocds = option("params").ocds
envConfig = option("params").ctx["apiextensions.crossplane.io/environment"]

_metadata = lambda suffix: str -> any {
    {
        name = oxr.metadata.name + "-" + suffix
        namespace = oxr.metadata.namespace
        annotations = {
            "krm.kcl.dev/composition-resource-name" = oxr.metadata.name + "-" + suffix
        }
    }
}

_providerConfigRef = oxr.spec.providerConfigRef or {
    kind = "ClusterProviderConfig"
    name = "default"
}

_attachPolicy = lambda policyArn: any -> any {
    {
        apiVersion = "iam.aws.m.upbound.io/v1beta1"
        kind = "RolePolicyAttachment"
        metadata = _metadata(policyArn.name + "-iam-role-policy-attachment")
        spec: {
            if oxr.spec.managementPolicies:
                managementPolicies = oxr.spec.managementPolicies
            providerConfigRef = _providerConfigRef
            forProvider = {
                policyArn = policyArn.arn
                roleSelector = {
                    matchControllerRef = True
                }
            }
        }
    }
}

_items = [
    {
        apiVersion = "iam.aws.m.upbound.io/v1beta1"
        kind = "Role"
        metadata = _metadata("iam-role")
        spec: {
            if oxr.spec.managementPolicies:
                managementPolicies = oxr.spec.managementPolicies
            providerConfigRef = _providerConfigRef
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
        metadata = _metadata("iam-policy")
        spec: {
            providerConfigRef = _providerConfigRef
            forProvider = {
                policy = oxr.spec.policyDocument
            }
        }
    }
    {
        apiVersion = "iam.aws.m.upbound.io/v1beta1"
        kind = "RolePolicyAttachment"
        metadata = _metadata("iam-role-policy-attachment")
        spec: {
            if oxr.spec.managementPolicies:
                managementPolicies = oxr.spec.managementPolicies
            providerConfigRef = _providerConfigRef
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
]

_items += [{
    apiVersion = "eks.aws.m.upbound.io/v1beta1"
    kind = "PodIdentityAssociation"
    metadata = _metadata("pod-identity-association")
    spec: {
        if oxr.spec.managementPolicies:
            managementPolicies = oxr.spec.managementPolicies
        providerConfigRef = _providerConfigRef
        forProvider = {
            clusterName = cluster.name
            serviceAccount = oxr.spec.serviceAccount.name
            namespace = oxr.spec.serviceAccount.namespace
            region = cluster.region
            roleArnSelector = {
                matchControllerRef = True
            }
        }
    }
} for cluster in oxr.spec.clusters]

if oxr.spec.parameters?.additionalPolicyArns:
    _items += [_attachPolicy(policy) for policy in oxr.spec.additionalPolicyArns]

items = _items
