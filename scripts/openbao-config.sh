#!/bin/bash

set -e

# This script is used to configure OpenBao. It supports three operations:
# - init: Initialize the OpenBao cluster and store the root token in AWS Secrets Manager
# - pki: Configure OpenBao's private key infrastructure
# - cert-manager: Configure cert-manager to use OpenBao for certificate management

OPENBAO_URL=""
ROOT_TOKEN_SECRET_NAME=""
ROOT_CA_SECRET_NAME=""
CERTMANAGER_APPROLE_SECRET_NAME=""
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
    echo "  --url <OpenBao URL>                     OpenBao server URL (required)"
    echo "  --root-token-secret-name <Secret Name>  AWS Secrets Manager secret name for the root token (required)"
    echo "  --root-ca-secret-name <Secret Name>     AWS Secrets Manager for the root CA certificate (required for pki)"
    echo "  --skip-verify                           Skip TLS verification"
    echo "  --region <Region>                       AWS region (default: eu-west-3)"
    echo "  --profile <Profile>                     AWS profile"
    echo ""
    echo "Cert-manager Options:"
    echo "  --eks-cluster-name <Name>                           EKS cluster name (required for cert-manager)"
    echo "  --cert-manager-approle-secret-name <Secret Name>    AWS Secrets Manager secret name for the cert-manager approle credentials (required for cert-manager)"
    echo "  --approle <Name>                                    AppRole name (required for cert-manager)"
    echo ""
    echo "Example:"
    echo "  $0 init --url https://openbao:8200 --root-token-secret-name openbao/root-token"
    echo "  $0 pki --url https://openbao:8200 --root-token-secret-name openbao/root-token --root-ca-secret-name certificates/domain.tld/root-ca"
    echo "  $0 cert-manager --url https://openbao:8200 --root-token-secret-name openbao/root-token --cert-manager-secret-name cert-manager/openbao-approle --eks-cluster-name mycluster --approle cert-manager"
}

# Common function to parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)
                OPENBAO_URL="$2"
                shift 2
                ;;
            --root-token-secret-name)
                ROOT_TOKEN_SECRET_NAME="$2"
                shift 2
                ;;
            --root-ca-secret-name)
                ROOT_CA_SECRET_NAME="$2"
                shift 2
                ;;
            --cert-manager-approle-secret-name)
                CERTMANAGER_APPROLE_SECRET_NAME="$2"
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

    if [ -z "$ROOT_TOKEN_SECRET_NAME" ]; then
        echo "Root token secret name is required"
        usage
        exit 1
    fi

    if [ "$COMMAND" = "pki" ] && [ -z "$ROOT_CA_SECRET_NAME" ]; then
        echo "Root CA secret name is required for PKI configuration"
        usage
        exit 1
    fi

    if [ "$COMMAND" = "cert-manager" ] && [ -z "$CERTMANAGER_APPROLE_SECRET_NAME" ]; then
        echo "Cert-manager approle secret name is required"
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
        echo "Error: bao is not installed"
        exit 1
    fi

    # Check if jq is installed
    if ! command -v jq &> /dev/null; then
        echo "Error: jq is not installed"
        exit 1
    fi

    # Check if kubectl is installed (needed for cert-manager)
    if ! command -v kubectl &> /dev/null; then
        echo "Warning: kubectl is not installed. This is required for cert-manager configuration."
    fi
}

# Common function to get AWS command
get_aws_cmd() {
    if [ -n "$PROFILE" ]; then
        echo "aws --profile $PROFILE --region $REGION"
    else
        echo "aws --region $REGION"
    fi
}

# Function to log messages with timestamps
log_message() {
    local level=$1
    shift
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
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
        log_message "INFO" "Attempt $attempt: Checking Host: \"$HOST\" Port: \"$PORT\"..."
        if nc -z -w 5 "$HOST" "$PORT"; then
            log_message "INFO" "OpenBao is ready"
            return 0
        fi
        sleep $interval
        attempt=$((attempt + 1))
    done

    log_message "ERROR" "OpenBao is not ready after $max_retries attempts"
    return 1
}

# Function to check OpenBao status
check_openbao_status() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1

    while [[ $attempt -le $max_retries ]]
    do
        log_message "INFO" "Attempt $attempt: Checking $OPENBAO_URL..."
        status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")

        case $status_code in
            200)
                log_message "INFO" "OpenBao is initialized, unsealed, and active"
                return 0
                ;;
        esac

        sleep $interval
        attempt=$((attempt + 1))
    done

    log_message "ERROR" "OpenBao is not initialized, unsealed, or active"
    return 1
}

create_or_update_secret() {
    local aws_cmd=$1
    local secret_name=$2
    local secret_value=$3

    # First check if the secret exists
    if $aws_cmd secretsmanager describe-secret --secret-id "$secret_name" >/dev/null 2>&1; then
        log_message "INFO" "Secret exists, updating it..."
        if ! $aws_cmd secretsmanager update-secret --secret-id "$secret_name" --secret-string "$secret_value" >/dev/null 2>&1; then
            log_message "ERROR" "Failed to update secret $secret_name"
            return 1
        fi
    else
        log_message "INFO" "Secret does not exist, creating it..."
        if ! $aws_cmd secretsmanager create-secret --name "$secret_name" --secret-string "$secret_value" >/dev/null 2>&1; then
            log_message "ERROR" "Failed to create secret $secret_name"
            return 1
        fi
    fi

    log_message "INFO" "Successfully updated AWS Secrets Manager entry for $secret_name"
    return 0
}

# Initialize OpenBao
init_openbao() {
    if ! wait_for_openbao; then
        log_message "ERROR" "Failed to wait for OpenBao to be ready"
        exit 1
    fi

    # Check if OpenBao is already initialized
    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")
    if [ "$status_code" = "200" ]; then
        log_message "INFO" "OpenBao is already initialized, unsealed, and active"
        exit 0
    fi

    if [ "$status_code" = "501" ]; then
        log_message "INFO" "OpenBao is not initialized - proceeding with initialization"
        init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
        if [ $? -ne 0 ]; then
            log_message "ERROR" "Failed to initialize OpenBao"
            exit 1
        fi

        root_token=$(echo "$init_output" | jq -r '.root_token')
        if [ -z "$root_token" ]; then
            log_message "ERROR" "Failed to extract root token from initialization output"
            exit 1
        fi

        secret_value=$(jq -n --arg token "$root_token" '{"token": $token}')

        # Store the root token in AWS Secrets Manager
        log_message "INFO" "Storing root token in AWS Secrets Manager..."
        AWS_CMD=$(get_aws_cmd)

        if ! create_or_update_secret "$AWS_CMD" "$ROOT_TOKEN_SECRET_NAME" "$secret_value"; then
            log_message "ERROR" "Failed to store root token in AWS Secrets Manager"
            exit 1
        fi
    else
        log_message "ERROR" "Unexpected status code: $status_code"
        exit 1
    fi

    # Final health check
    log_message "INFO" "Performing final health check..."
    if ! check_openbao_status; then
        log_message "ERROR" "Final health check failed"
        exit 1
    fi
}

# Configure PKI
configure_pki() {
    # Check if OpenBao is reachable and initialized
    if ! curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health" | grep -q "200"; then
        log_message "ERROR" "OpenBao is not reachable or not properly initialized"
        exit 1
    fi

    # Retrieve the root token from AWS Secrets Manager
    AWS_CMD=$(get_aws_cmd)
    root_token=$($AWS_CMD secretsmanager get-secret-value --secret-id "$ROOT_TOKEN_SECRET_NAME" --output text --query 'SecretString' | jq -r '.token')
    if [ -z "$root_token" ]; then
        log_message "ERROR" "Failed to retrieve root token from AWS Secrets Manager"
        exit 1
    fi

    ca_bundle=$($AWS_CMD secretsmanager get-secret-value --secret-id "$ROOT_CA_SECRET_NAME" --query "SecretString" --output text | jq -r .bundle)
    if [ -z "$ca_bundle" ]; then
        log_message "ERROR" "Failed to retrieve CA bundle from AWS Secrets Manager"
        exit 1
    fi

    export VAULT_TOKEN="$root_token"

    # Check OpenBao status
    status_output=$(bao status -format=json)
    is_initialized=$(echo "$status_output" | jq -r '.initialized')

    if [ "$is_initialized" == "false" ]; then
        log_message "ERROR" "OpenBao is not initialized"
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
        log_message "ERROR" "EKS cluster name is required for cert-manager configuration"
        usage
        exit 1
    fi

    if [ -z "$APPROLE" ]; then
        log_message "ERROR" "AppRole name is required for cert-manager configuration"
        usage
        exit 1
    fi

    # Get the Vault token from AWS Secrets Manager
    AWS_CMD=$(get_aws_cmd)
    root_token=$($AWS_CMD secretsmanager get-secret-value --secret-id "$ROOT_TOKEN_SECRET_NAME" --output text --query 'SecretString' | jq -r '.token')
    if [ -z "$root_token" ]; then
        log_message "ERROR" "Failed to retrieve root token from AWS Secrets Manager"
        exit 1
    fi

    export VAULT_TOKEN="$root_token"

    log_message "INFO" "Using Vault address: $VAULT_ADDR"

    # Retrieve the approle id and secret
    APPROLE_ID=$(bao read --field=role_id auth/approle/role/$APPROLE/role-id)
    if [ -z "$APPROLE_ID" ]; then
        log_message "ERROR" "Failed to retrieve approle ID"
        exit 1
    fi

    APPROLE_SECRET=$(bao write --field=secret_id -f auth/approle/role/$APPROLE/secret-id)
    if [ -z "$APPROLE_SECRET" ]; then
        log_message "ERROR" "Failed to retrieve approle secret"
        exit 1
    fi

    # Check if the cluster exists
    if ! $AWS_CMD eks list-clusters --query clusters --output json --region "$REGION" | jq -e "any(.[]; . == \"$EKS_CLUSTER_NAME\")" >/dev/null; then
        log_message "ERROR" "Cluster $EKS_CLUSTER_NAME does not exist"
        exit 1
    fi

    # Update kubeconfig
    log_message "INFO" "Updating kubeconfig for cluster $EKS_CLUSTER_NAME"
    if ! $AWS_CMD eks update-kubeconfig --name "$EKS_CLUSTER_NAME" --alias "$EKS_CLUSTER_NAME" --region "$REGION" $(if [ -n "$PROFILE" ]; then echo "--profile $PROFILE"; fi); then
        log_message "ERROR" "Failed to update kubeconfig"
        exit 1
    fi

    # Create a JSON object with the approle credentials
    secret_value=$(jq -n \
        --arg approle_id "$APPROLE_ID" \
        --arg approle_secret "$APPROLE_SECRET" \
        '{"cert-manager-approle-id": $approle_id, "cert-manager-approle-secret": $approle_secret}')

    if ! create_or_update_secret "$AWS_CMD" "$CERTMANAGER_APPROLE_SECRET_NAME" "$secret_value"; then
        log_message "ERROR" "Failed to store approle credentials in AWS Secrets Manager"
        exit 1
    fi

    log_message "INFO" "Creating a secret in the cluster"

    if kubectl get secret -n flux-system cert-manager-openbao-approle > /dev/null 2>&1; then
        log_message "INFO" "Secret already exists, updating it"
        kubectl delete secret -n flux-system cert-manager-openbao-approle
    fi

    kubectl create secret generic cert-manager-openbao-approle \
    --from-literal=cert_manager_approle_id="$APPROLE_ID" \
    --from-literal=cert_manager_approle_secret="$APPROLE_SECRET" \
    --namespace flux-system
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
