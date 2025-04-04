#!/bin/bash

# This script is used to configure OpenBao's private key infrastructure.
# It will create a new CA and a new root certificate and key.
# It will also create a new intermediate certificate and key.
# It will then configure OpenBao to use the new CA.

set -e
set -x

usage() {
    echo "Usage: $0 --url <OpenBao URL> --secret-name <Secret Name> [--skip-verify] [--region <Region>] [--profile <Profile>]"
}

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
        *)
            usage
            exit 1
            ;;
    esac
done

if [ -z "$OPENBAO_URL" ]; then
    echo "OpenBao URL is not set"
    exit 1
fi

if [ -z "$SECRET_NAME" ]; then
    echo "Secret Name is not set"
    exit 1
fi

if [ -z "$SKIP_VERIFY" ]; then
    SKIP_VERIFY=false
fi

if [ -z "$REGION" ]; then
    REGION="eu-west-3"
fi

if [ -z "$PROFILE" ]; then
    PROFILE=""
fi


# Check if the OpenBao URL is reachable
if ! curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health" | grep -q "200"; then
    echo "OpenBao URL is not reachable"
    exit 1
fi

# Check if the binary bao is installed
if ! command -v bao &> /dev/null; then
    echo "bao is not installed"
    exit 1
fi

# Check if the binary jq is installed
if ! command -v jq &> /dev/null; then
    echo "jq is not installed"
    exit 1
fi

# Retrieve the root token from AWS Secrets Manager
# set the profile if it is set
if [ -n "$PROFILE" ]; then
    AWS_CMD="aws --profile $PROFILE"
else
    AWS_CMD="aws"
fi

root_token=$($AWS_CMD secretsmanager get-secret-value --secret-id "$SECRET_NAME" --region "$REGION" --output text --query 'SecretString' | jq -r '.token')

ca_bundle=$($AWS_CMD secretsmanager get-secret-value --secret-id certificates/priv.cloud.ogenki.io/root-ca --query "SecretString" --region "$REGION" --output text | jq -r .bundle)

export VAULT_TOKEN="$root_token"

# Check OpenBao status
status_output=$(bao status -format=json)

# Check if OpenBao is initialized
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
