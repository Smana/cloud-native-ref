# EKS Pod Identity KCL Module

A KCL composition function module for creating AWS EKS Pod Identity associations using Crossplane. This module simplifies the setup of IAM roles and policies that can be assumed by Kubernetes service accounts in EKS clusters.

## Overview

This module creates a complete EKS Pod Identity setup with:
- IAM role with EKS Pod Identity trust policy
- Custom IAM policy with specified permissions
- Policy attachment to the IAM role
- EKS Pod Identity association linking the role to service accounts
- Support for multiple EKS clusters
- Optional attachment of additional AWS managed policies

## Features

- **Multi-Cluster Support**: Associate the same service account across multiple EKS clusters
- **Custom Policies**: Define custom IAM policies with fine-grained permissions
- **Managed Policies**: Attach additional AWS managed policies
- **Security**: Uses EKS Pod Identity for secure, temporary credential access
- **Crossplane Integration**: Full lifecycle management through Kubernetes resources

## How EKS Pod Identity Works

EKS Pod Identity allows Kubernetes service accounts to assume IAM roles without storing long-lived credentials. When a pod uses a service account associated with an IAM role:

1. The pod requests temporary credentials from the EKS Pod Identity Agent
2. The agent validates the request and calls AWS STS to assume the role
3. Temporary credentials are provided to the pod
4. The credentials automatically rotate and expire

## Examples

### Basic S3 Access

Create pod identity for a service account that needs S3 access:

```yaml
apiVersion: identity.aws.example.com/v1alpha1
kind: EKSPodIdentity
metadata:
  name: s3-reader
  namespace: default
spec:
  clusters:
    - name: my-cluster
      region: us-west-2

  serviceAccount:
    name: s3-reader-sa
    namespace: default

  policyDocument: |
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": [
            "s3:GetObject",
            "s3:ListBucket"
          ],
          "Resource": [
            "arn:aws:s3:::my-bucket",
            "arn:aws:s3:::my-bucket/*"
          ]
        }
      ]
    }
```

### Advanced Multi-Cluster Setup with Route53 Access

```yaml
apiVersion: identity.aws.example.com/v1alpha1
kind: EKSPodIdentity
metadata:
  name: cert-manager-dns
  namespace: cert-manager
spec:
  # Associate with multiple clusters
  clusters:
    - name: prod-cluster
      region: us-east-1
    - name: staging-cluster
      region: us-west-2
    - name: dev-cluster
      region: eu-west-1

  serviceAccount:
    name: cert-manager
    namespace: cert-manager

  # Custom policy for Route53 DNS challenge
  policyDocument: |
    {
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Action": "route53:GetChange",
          "Resource": "arn:aws:route53:::change/*"
        },
        {
          "Effect": "Allow",
          "Action": [
            "route53:ChangeResourceRecordSets",
            "route53:ListResourceRecordSets"
          ],
          "Resource": "arn:aws:route53:::hostedzone/Z1234567890ABC"
        },
        {
          "Effect": "Allow",
          "Action": [
            "route53:ListHostedZones",
            "route53:ListHostedZonesByName"
          ],
          "Resource": "*"
        }
      ]
    }

  # Attach additional AWS managed policies
  additionalPolicyArns:
    - name: route53-readonly
      arn: arn:aws:iam::aws:policy/AmazonRoute53ReadOnlyAccess
    - name: cloudwatch-logs
      arn: arn:aws:iam::aws:policy/CloudWatchLogsFullAccess

  # Custom provider configuration
  providerConfigRef:
    kind: ProviderConfig
    name: aws-provider-config

  # Management policies for drift detection
  managementPolicies:
    - Create
    - Update
    - Delete
```

## Configuration Reference

### Required Fields

- `clusters`: Array of EKS clusters to associate with
  - `name`: EKS cluster name (string)
  - `region`: AWS region where the cluster is located (string)
- `serviceAccount`: Service account configuration
  - `name`: Service account name (string)
  - `namespace`: Kubernetes namespace (string)
- `policyDocument`: Custom IAM policy document in JSON format (string)

### Optional Fields

- `additionalPolicyArns`: Array of additional AWS managed policies to attach
  - `name`: Reference name for the policy (string)
  - `arn`: AWS policy ARN (string)
- `providerConfigRef`: Custom Crossplane provider configuration
  - `kind`: Provider config kind (default: `ClusterProviderConfig`)
  - `name`: Provider config name (default: `default`)
- `managementPolicies`: Crossplane management policies (array)

## Common Use Cases

### 1. External DNS Controller

```yaml
policyDocument: |
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "route53:ChangeResourceRecordSets",
          "route53:ListResourceRecordSets",
          "route53:GetHostedZone",
          "route53:ListHostedZones"
        ],
        "Resource": "*"
      }
    ]
  }
```

### 2. AWS Load Balancer Controller

```yaml
additionalPolicyArns:
  - name: alb-controller
    arn: arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess
  - name: ec2-permissions
    arn: arn:aws:iam::aws:policy/AmazonEC2ReadOnlyAccess
```

### 3. Cluster Autoscaler

```yaml
policyDocument: |
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions"
        ],
        "Resource": "*"
      },
      {
        "Effect": "Allow",
        "Action": [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup",
          "ec2:DescribeImages",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ],
        "Resource": "*"
      }
    ]
  }
```

### 4. Secrets Manager Access

```yaml
policyDocument: |
  {
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ],
        "Resource": "arn:aws:secretsmanager:*:*:secret:app/*"
      }
    ]
  }
```

## Security Best Practices

### 1. Least Privilege Principle
Always grant the minimum permissions required:
```json
{
  "Effect": "Allow",
  "Action": "s3:GetObject",
  "Resource": "arn:aws:s3:::specific-bucket/specific-prefix/*"
}
```

### 2. Resource-Specific Policies
Avoid wildcards in resource ARNs when possible:
```json
{
  "Resource": "arn:aws:route53:::hostedzone/Z1234567890ABC"
}
```

### 3. Condition-Based Access
Use conditions to further restrict access:
```json
{
  "Effect": "Allow",
  "Action": "s3:GetObject",
  "Resource": "*",
  "Condition": {
    "StringLike": {
      "s3:prefix": ["logs/*", "backups/*"]
    }
  }
}
```

## Prerequisites

1. **EKS Cluster**: Target clusters must have EKS Pod Identity enabled
2. **Crossplane AWS Provider**: Properly configured with sufficient permissions
3. **Service Account**: Target service account should exist or be created
4. **IAM Permissions**: Crossplane AWS provider needs IAM role and policy management permissions

## Created Resources

The module creates the following AWS resources:

1. **IAM Role**: With EKS Pod Identity trust policy
2. **IAM Policy**: Custom policy with specified permissions
3. **IAM Role Policy Attachment**: Links custom policy to role
4. **Additional Policy Attachments**: Links managed policies to role (if specified)
5. **EKS Pod Identity Association**: Associates role with service account in each cluster

## Monitoring and Troubleshooting

### Verify Resources

```bash
# Check pod identity association
kubectl get podidentityassociation

# Describe the association
kubectl describe podidentityassociation <name>

# Verify IAM role
aws iam get-role --role-name <role-name>

# List attached policies
aws iam list-attached-role-policies --role-name <role-name>
```

### Common Issues

1. **Association Failed**: Check EKS cluster name and region
2. **Permission Denied**: Verify IAM policy permissions and syntax
3. **Service Account Not Found**: Ensure service account exists in target namespace
4. **Cross-Region Issues**: Verify each cluster region matches the association

### Testing Pod Identity

Create a test pod to verify the association works:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: test-pod
  namespace: default
spec:
  serviceAccountName: your-service-account
  containers:
  - name: aws-cli
    image: amazon/aws-cli:latest
    command: ["sleep", "3600"]
```

Then exec into the pod and test AWS CLI:
```bash
kubectl exec -it test-pod -- aws sts get-caller-identity
```

## Version Compatibility

- **KCL**: v0.11.3+
- **EKS**: v1.24+ (Pod Identity supported)
- **Crossplane AWS Provider**: v1.0+
- **Kubernetes**: v1.24+

## Migration from IRSA

If migrating from IAM Roles for Service Accounts (IRSA):

1. Remove IRSA annotations from service accounts
2. Deploy EKS Pod Identity resources using this module
3. Restart pods to use new authentication method
4. Verify access works correctly
5. Clean up old IRSA roles and OIDC provider trust relationships
