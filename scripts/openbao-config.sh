#!/bin/bash

set -e

# This script is used to configure OpenBao. It supports three operations:
# - init: Initialize the OpenBao cluster and store the root token in AWS Secrets Manager
# - pki: Configure OpenBao's private key infrastructure
# - cert-manager: Configure cert-manager to use OpenBao for certificate management

OPENBAO_URL=""
SECRET_NAME=""
SKIP_VERIFY=false
REGION="eu-west-3"
PROFILE=""
EKS_CLUSTER_NAME=""
APPROLE=""

usage() {
    echo "Usage: $0 <command> [options]"
    echo "Commands:"
    echo "  init          Initialize OpenBao cluster"
    echo "  pki           Configure PKI secrets engine"
    echo "  cert-manager  Configure cert-manager to use OpenBao"
    echo ""
    echo "Common Options:"
    echo "  --url <OpenBao URL>         OpenBao server URL (required)"
    echo "  --secret-name <Secret Name> AWS Secrets Manager secret name (required)"
    echo "  --skip-verify               Skip TLS verification"
    echo "  --region <Region>          AWS region (default: eu-west-3)"
    echo "  --profile <Profile>        AWS profile"
    echo ""
    echo "Cert-manager Options:"
    echo "  --eks-cluster-name <Name>  EKS cluster name (required for cert-manager)"
    echo "  --approle <Name>           AppRole name (required for cert-manager)"
    echo ""
    echo "Example:"
    echo "  $0 init --url https://openbao:8200 --secret-name openbao/root-token"
    echo "  $0 pki --url https://openbao:8200 --secret-name openbao/root-token"
    echo "  $0 cert-manager --url https://openbao:8200 --secret-name openbao/root-token --eks-cluster-name mycluster --approle cert-manager"
}

# Common function to parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                OPENBAO_URL="$2"
                shift 2
                ;;
            --secret-name)
                SECRET_NAME="$2"
                shift 2
                ;;
            --skip-verify)
                SKIP_VERIFY=true
                shift
                ;;
            --region)
                REGION="$2"
                shift 2
                ;;
            --profile)
                PROFILE="$2"
                shift 2
                ;;
            --eks-cluster-name)
                EKS_CLUSTER_NAME="$2"
                shift 2
                ;;
            --approle)
                APPROLE="$2"
                shift 2
                ;;
            *)
                echo "Invalid argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [ -z "$OPENBAO_URL" ]; then
        echo "OpenBao URL is required"
        usage
        exit 1
    fi

    if [ -z "$SECRET_NAME" ]; then
        echo "Secret Name is required"
        usage
        exit 1
    fi

    export VAULT_ADDR="$OPENBAO_URL"
    if [ "$SKIP_VERIFY" = true ]; then
        export VAULT_SKIP_VERIFY=true
    fi
}

# Common function to check prerequisites
check_prerequisites() {
    # Check if bao is installed
    if ! command -v bao &> /dev/null; then
        echo "bao is not installed"
        exit 1
    fi

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        echo "jq is not installed"
        exit 1
    fi
}

# Common function to get AWS command
get_aws_cmd() {
    if [ -n "$PROFILE" ]; then
        echo "aws --profile $PROFILE"
    else
        echo "aws"
    fi
}

# Function to wait for OpenBao to be ready
wait_for_openbao() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1

    HOST=$(echo "$OPENBAO_URL" | sed -E 's|https?://([^:]+):?.*|\1|')
    PORT=$(echo "$OPENBAO_URL" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')
    while [[ $attempt -le $max_retries ]]
    do
        echo "Attempt $attempt: Checking Host: \"$HOST\" Port: \"$PORT\"..."
        if nc -z -w 5 "$HOST" "$PORT"; then
            echo "OpenBao is ready"
            return 0
        fi
        sleep $interval
        attempt=$((attempt + 1))
    done
}

# Function to check OpenBao status
check_openbao_status() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1

    while [[ $attempt -le $max_retries ]]
    do
        echo "Attempt $attempt: Checking $OPENBAO_URL..."
        status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")

        case $status_code in
            200)
                echo "OpenBao is initialized, unsealed, and active"
                return 0
                ;;
        esac

        sleep $interval
        attempt=$((attempt + 1))
    done

    echo "OpenBao is not initialized, unsealed, or active"
    return 1
}

# Initialize OpenBao
init_openbao() {
    wait_for_openbao

    # Check if OpenBao is already initialized
    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")
    if [ "$status_code" = "200" ]; then
        echo "OpenBao is already initialized, unsealed, and active"
        exit 0
    fi

    if [ "$status_code" = "501" ]; then
        echo "OpenBao is not initialized - proceeding with initialization"
        init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
        root_token=$(echo "$init_output" | jq -r '.root_token')
        secret_value=$(jq -n --arg token "$root_token" '{"token": $token}')

        # Store the root token in AWS Secrets Manager
        echo "Storing root token in AWS Secrets Manager..."
        AWS_CMD=$(get_aws_cmd)

        # First check if the secret exists
        if $AWS_CMD secretsmanager describe-secret --secret-id "$SECRET_NAME" --region "$REGION" >/dev/null 2>&1; then
            echo "Secret exists, updating it..."
            $AWS_CMD secretsmanager update-secret --secret-id "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION" >/dev/null 2>&1
        else
            echo "Secret does not exist, creating it..."
            $AWS_CMD secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION" >/dev/null 2>&1
        fi
    else
        echo "Unexpected status code: $status_code"
        exit 1
    fi

    # Final health check
    echo "Performing final health check..."
    check_openbao_status
}

# Configure PKI
configure_pki() {
    # Check if OpenBao is reachable and initialized
    if ! curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health" | grep -q "200"; then
        echo "OpenBao is not reachable or not properly initialized"
        exit 1
    fi

    # Retrieve the root token from AWS Secrets Manager
    AWS_CMD=$(get_aws_cmd)
    root_token=$($AWS_CMD secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --output text --query 'SecretString' | jq -r '.token')
    ca_bundle=$($AWS_CMD secretsmanager get-secret-value --secret-id certificates/priv.cloud.ogenki.io/root-ca --query "SecretString" --region "$REGION" --output text | jq -r .bundle)

    export VAULT_TOKEN="$root_token"

    # Check OpenBao status
    status_output=$(bao status -format=json)
    is_initialized=$(echo "$status_output" | jq -r '.initialized')

    if [ "$is_initialized" == "false" ]; then
        echo "OpenBao is not initialized"
        exit 1
    fi

    # Enable PKI secrets engine
    if ! bao secrets list --format=json | jq -e '.["pki/"]' > /dev/null; then
        echo "Enabling PKI secrets engine..."
        bao secrets enable pki
    fi

    # Create a temporary file for the certificate bundle
    temp_bundle=$(mktemp)
    echo "$ca_bundle" > "$temp_bundle"

    # Configure the PKI mount with the certificate bundle
    echo "Configuring PKI mount with certificate bundle..."
    bao write pki/config/ca pem_bundle=@"$temp_bundle"

    # Clean up the temporary file
    rm -f "$temp_bundle"

    # Check the PKI configuration
    if [[ $(bao pki health-check --format=json pki|jq -r '.ca_validity_period[0].status') == "ok" ]]; then
        echo "PKI configuration is correct"
    else
        echo "PKI configuration is incorrect"
        exit 1
    fi

    # Expected max-lease-ttl value
    expected_ttl="315360000"

    # Read the configuration of the pki secrets engine
    actual_ttl=$(bao read -format=json sys/mounts/pki/tune | jq -r '.data.max_lease_ttl')

    # Check if the actual value matches the expected value
    if [ "$actual_ttl" == "$expected_ttl" ]; then
        echo "The max-lease-ttl value is as expected: $actual_ttl"
    else
        bao secrets tune -max-lease-ttl="$expected_ttl" pki
    fi
}

# Configure cert-manager
configure_cert_manager() {
    # Check if required parameters are provided
    if [ -z "$EKS_CLUSTER_NAME" ]; then
        echo "EKS cluster name is required for cert-manager configuration"
        usage
        exit 1
    fi

    if [ -z "$APPROLE" ]; then
        echo "AppRole name is required for cert-manager configuration"
        usage
        exit 1
    fi

    # Get the Vault token from AWS Secrets Manager
    AWS_CMD=$(get_aws_cmd)
    VAULT_TOKEN=$($AWS_CMD secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --output text --query SecretString | jq -r '.token')
    export VAULT_TOKEN="$VAULT_TOKEN"

    echo "Using Vault address: $VAULT_ADDR"

    # Retrieve the approle id and secret
    APPROLE_ID=$(bao read --field=role_id auth/approle/role/$APPROLE/role-id)
    APPROLE_SECRET=$(bao write --field=secret_id -f auth/approle/role/$APPROLE/secret-id)

    # Check if the cluster exists
    $AWS_CMD eks list-clusters --query clusters --output json --region "$REGION" | jq -e "any(.[]; . == \"$EKS_CLUSTER_NAME\")"
    if [ $? -ne 0 ]; then
        echo "Cluster $EKS_CLUSTER_NAME does not exist"
        exit 1
    fi

    # Update kubeconfig
    $AWS_CMD eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --alias "$EKS_CLUSTER_NAME" --region "$REGION" $(if [ -n "$PROFILE" ]; then echo "--profile $PROFILE"; fi)

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
}

# Main script
if [ $# -lt 1 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    init)
        parse_args "$@"
        check_prerequisites
        init_openbao
        ;;
    pki)
        parse_args "$@"
        check_prerequisites
        configure_pki
        ;;
    cert-manager)
        parse_args "$@"
        check_prerequisites
        configure_cert_manager
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
