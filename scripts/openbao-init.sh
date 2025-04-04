#!/bin/bash

set -e

# This script is used to initialize the Openbao cluster.
# The root token is then stored in AWS Secrets Manager.

OPENBAO_URL=""
SECRET_NAME=""
SKIP_VERIFY=false
REGION="eu-west-3"
PROFILE=""

usage() {
    echo "Usage: $0 --url <OpenBao URL> --secret-name <Secret Name> [--skip-verify] [--region <Region>] [--profile <Profile>]"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --url)
            OPENBAO_URL="$2"
            shift 2
            ;;
        --skip-verify)
            SKIP_VERIFY=true
            shift
            ;;
        --secret-name)
            SECRET_NAME="$2"
            shift 2
            ;;
        --region)
            REGION="$2"
            shift 2
            ;;
        --profile)
            PROFILE="$2"
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
    echo "OpenBao URL is not set"
    exit 1
else
    export VAULT_ADDR="$OPENBAO_URL"
fi

if [ "$SKIP_VERIFY" = true ]; then
    export VAULT_SKIP_VERIFY=true
fi

# Check if bao is installed
if ! command -v bao &> /dev/null; then
    echo "bao is not installed"
    exit 1
fi

wait_for_openbao() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1
    local last_status=""

    HOST=$(echo "$OPENBAO_URL" | sed -E 's|https?://([^:]+):?.*|\1|')
    PORT=$(echo "$OPENBAO_URL" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')
    while [[ $attempt -le $max_retries ]]
    do
        echo "Attempt $attempt: Checking host:$HOST port:$PORT..."
        if nc -z -w 5 "$HOST" "$PORT"; then
            echo "OpenBao is ready"
            return 0
        fi
        sleep $interval
        attempt=$((attempt + 1))
    done
}

check_openbao_status() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1
    local last_status=""

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

wait_for_openbao

status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")

case $status_code in
    200)
        echo "OpenBao is initialized, unsealed, and active"
        exit 0
        ;;
    501)
        echo "OpenBao is not initialized - proceeding with initialization"
        init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
        root_token=$(echo "$init_output" | jq -r '.root_token')
        secret_value=$(jq -n --arg token "$root_token" '{"token": $token}')

        # Store the root token in AWS Secrets Manager
        echo "Storing root token in AWS Secrets Manager..."

        # Prepare AWS command with profile if specified
        AWS_CMD="aws"
        if [ -n "$PROFILE" ]; then
            AWS_CMD="$AWS_CMD --profile $PROFILE"
        fi

        # Check if secret exists
        if $AWS_CMD secretsmanager describe-secret --name "$SECRET_NAME" --region "$REGION" &>/dev/null; then
            echo "Secret already exists, updating it..."
            $AWS_CMD secretsmanager update-secret --name "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION"
        else
            echo "Secret does not exist, creating it..."
            $AWS_CMD secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION"
        fi
        ;;
    *)
        echo "Unexpected status code: $status_code"
        exit 1
        ;;
esac

# Final health check
echo "Performing final health check..."
check_openbao_status

if [ $? -eq 0 ]; then
    echo "OpenBao is properly initialized"
fi
