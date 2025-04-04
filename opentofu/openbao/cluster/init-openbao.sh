#!/bin/bash

set -x

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
fi

if [ "$SKIP_VERIFY" = true ]; then
    export VAULT_SKIP_VERIFY=true
fi

# Check if bao is installed
if ! command -v bao &> /dev/null; then
    echo "bao is not installed"
    exit 1
fi


# Check OpenBao status
status_output=$(bao status -format=json)

# Check if OpenBao is initialized
is_initialized=$(echo "$status_output" | jq -r '.initialized')

# Initialize  only if it is not initialized
if [ "$is_initialized" == "false" ]; then
    # Initialize OpenBao and store the output in a variable in JSON format
    init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)

    # Extract the root token from the JSON output using jq
    root_token=$(echo "$init_output" | jq -r '.root_token')

    # Create JSON object for the secret value
    secret_value=$(jq -n --arg token "$root_token" '{"token": $token}')

    # Store the root token in AWS Secrets Manager
    if [ -z "$PROFILE" ]; then
        if aws secretsmanager describe-secret --name "$SECRET_NAME" --region "$REGION" &>/dev/null; then
            # Secret exists, update it
            aws secretsmanager update-secret --name "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION"
        else
            # Secret doesn't exist, create it
            aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION"
        fi
    else
        if aws secretsmanager describe-secret --name "$SECRET_NAME" --region "$REGION" --profile "$PROFILE" &>/dev/null; then
            # Secret exists, update it
            aws secretsmanager update-secret --name "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION" --profile "$PROFILE"
        else
            # Secret doesn't exist, create it
            aws secretsmanager create-secret --name "$SECRET_NAME" --secret-string "$secret_value" --region "$REGION" --profile "$PROFILE"
        fi
    fi
else
    echo "OpenBao is already initialized"
fi

