#!/bin/bash

set -e

# This script is run after the OpenBao cluster is initialized and the PKI secrets engine is configured.
# An approle has already been created by the openbao management module and we need to create a secret that contains the approle credentials.
# This secret will be used by cert-manager to create the certificates.

while [[ $# -gt 0 ]]; do
    case "$1" in
        --eks-cluster-name)
            EKS_CLUSTER_NAME="$2"
            shift 2
            ;;
        --aws-profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --aws-region)
            AWS_REGION="$2"
            shift 2
            ;;
        --approle)
            APPROLE="$2"
            shift 2
            ;;
        --vault-addr)
            VAULT_ADDR="$2"
            shift 2
            ;;
        --vault-skip-verify)
            VAULT_SKIP_VERIFY=true
            shift
            ;;
        --vault-secret-name)
            VAULT_SECRET_NAME="$2"
            shift 2
            ;;
        *)
            echo "Invalid argument: $1"
            exit 1
            ;;
    esac
done

if [ -z "$EKS_CLUSTER_NAME" ]; then
    echo "EKS cluster name is required"
    exit 1
fi

if [ -z "$AWS_REGION" ]; then
    AWS_REGION="eu-west-3"
fi

if [ -z "$APPROLE" ]; then
    echo "Approle is required"
    exit 1
fi

if [ -z "$VAULT_SECRET_NAME" ]; then
    echo "Vault secret name is required"
    exit 1
fi

# Build AWS command parameters
AWS_CMD_PARAMS="--region $AWS_REGION"
if [ -n "$AWS_PROFILE" ]; then
    AWS_CMD_PARAMS="$AWS_CMD_PARAMS --profile $AWS_PROFILE"
fi

# Set Vault environment variables
if [ -z "$VAULT_ADDR" ]; then
    VAULT_ADDR="https://bao.priv.cloud.ogenki.io:8200"
fi

# Get the Vault token from AWS Secrets Manager
VAULT_TOKEN=$(aws secretsmanager get-secret-value --secret-id $VAULT_SECRET_NAME $AWS_CMD_PARAMS --output text --query SecretString | jq -r '.token')

# Set Vault skip verify if provided
if [ "$VAULT_SKIP_VERIFY" = "true" ]; then
    export VAULT_SKIP_VERIFY="true"
fi

# Export Vault environment variables
export VAULT_ADDR="$VAULT_ADDR"
export VAULT_TOKEN="$VAULT_TOKEN"

echo "Using Vault address: $VAULT_ADDR"

# Retrieve the approle id and secret
APPROLE_ID=$(bao read --field=role_id auth/approle/role/$APPROLE/role-id)
APPROLE_SECRET=$(bao write --field=secret_id -f auth/approle/role/$APPROLE/secret-id)

# Check if the cluster exists
aws eks list-clusters --query clusters --output json --region $AWS_REGION | jq -e "any(.[]; . == \"$EKS_CLUSTER_NAME\")"
if [ $? -ne 0 ]; then
    echo "Cluster $EKS_CLUSTER_NAME does not exist"
    exit 1
fi

# Update kubeconfig
aws eks update-kubeconfig --name $EKS_CLUSTER_NAME --alias $EKS_CLUSTER_NAME $AWS_CMD_PARAMS

# Check the namespace `flux-system` exists. It should have been created by the EKS module.
if ! kubectl get namespace flux-system >> /dev/null 2>&1; then
    echo "Namespace flux-system does not exist"
    exit 1
fi

# Create the secret that contains the approle credentials
# Delete it first if it exists
if kubectl get secret cert-manager-openbao-approle --namespace flux-system >> /dev/null 2>&1; then
    kubectl delete secret cert-manager-openbao-approle --namespace flux-system
fi

kubectl create secret generic cert-manager-openbao-approle \
    --namespace flux-system \
    --from-literal=cert-manager-approle-id=$APPROLE_ID \
    --from-literal=cert-manager-approle-secret=$APPROLE_SECRET
