#!/bin/bash

set -euo pipefail

# This script is used to configure OpenBao. It supports two operations:
# - init: Initialize the OpenBao cluster, then store the root token and the
#         recovery keys in two SEPARATE AWS Secrets Manager entries
# - ca:   Write the CA chain to a local file so the Vault provider can verify
#         the server certificate instead of running with skip_tls_verify
#
# The former `pki` command was removed. It enabled a second `pki` mount in the
# ROOT namespace and imported the root CA bundle - private key included - into
# it. Nothing consumed that mount: cert-manager issues from
# `pki_private_issuer` in the `admin/pki` namespace, which the OpenTofu in this
# stack manages (pki.tf). It was a duplicate online copy of the root CA key
# with no role restrictions and no reader.

OPENBAO_URL=""
ROOT_TOKEN_SECRET_NAME=""
RECOVERY_KEYS_SECRET_NAME=""
ROOT_CA_SECRET_NAME=""
CA_OUTPUT_FILE=""
RECOVERY_SHARES=1
RECOVERY_THRESHOLD=1
SKIP_VERIFY=false
REGION="eu-west-3"
PROFILE=""

usage() {
    echo "Usage: $0 <command> [options]"
    echo "Commands:"
    echo "  init          Initialize OpenBao cluster"
    echo "  ca            Write the CA chain to a local file for TLS verification"
    echo ""
    echo "Common Options:"
    echo "  --url <OpenBao URL>                       OpenBao server URL (required for init)"
    echo "  --root-token-secret-name <Secret Name>    AWS Secrets Manager secret for the root token (required for init)"
    echo "  --recovery-keys-secret-name <Secret Name> AWS Secrets Manager secret for the recovery keys (required for init)"
    echo "  --recovery-shares <N>                     Number of recovery key shares (default: ${RECOVERY_SHARES})"
    echo "  --recovery-threshold <N>                  Shares needed to reconstruct (default: ${RECOVERY_THRESHOLD})"
    echo "  --root-ca-secret-name <Secret Name>       AWS Secrets Manager secret holding the CA chain (required for ca)"
    echo "  --ca-output-file <Path>                   Where to write the CA chain (required for ca)"
    echo "  --skip-verify                             Skip TLS verification"
    echo "  --region <Region>                         AWS region (default: ${REGION})"
    echo "  --profile <Profile>                       AWS profile"
    echo ""
    echo "Example:"
    echo "  $0 init --url https://openbao:8200 --root-token-secret-name openbao/root-token \\"
    echo "          --recovery-keys-secret-name openbao/recovery-keys"
    echo "  $0 ca --root-ca-secret-name certificates/domain.tld/root-ca --ca-output-file .tls/ca.pem"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --url)                        OPENBAO_URL="$2"; shift 2 ;;
            --root-token-secret-name)     ROOT_TOKEN_SECRET_NAME="$2"; shift 2 ;;
            --recovery-keys-secret-name)  RECOVERY_KEYS_SECRET_NAME="$2"; shift 2 ;;
            --recovery-shares)            RECOVERY_SHARES="$2"; shift 2 ;;
            --recovery-threshold)         RECOVERY_THRESHOLD="$2"; shift 2 ;;
            --root-ca-secret-name)        ROOT_CA_SECRET_NAME="$2"; shift 2 ;;
            --ca-output-file)             CA_OUTPUT_FILE="$2"; shift 2 ;;
            --skip-verify)                SKIP_VERIFY=true; shift ;;
            --region)                     REGION="$2"; shift 2 ;;
            --profile)                    PROFILE="$2"; shift 2 ;;
            *)
                echo "Invalid argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    if [ "$COMMAND" = "init" ]; then
        if [ -z "$OPENBAO_URL" ]; then
            echo "OpenBao URL is required"; usage; exit 1
        fi
        if [ -z "$ROOT_TOKEN_SECRET_NAME" ]; then
            echo "Root token secret name is required"; usage; exit 1
        fi
        if [ -z "$RECOVERY_KEYS_SECRET_NAME" ]; then
            echo "Recovery keys secret name is required - see the note in init_openbao()"
            usage; exit 1
        fi
        if [ "$ROOT_TOKEN_SECRET_NAME" = "$RECOVERY_KEYS_SECRET_NAME" ]; then
            echo "The root token and the recovery keys must not share a secret: the recovery keys exist to regenerate a lost root token."
            exit 1
        fi
    fi

    if [ "$COMMAND" = "ca" ]; then
        if [ -z "$ROOT_CA_SECRET_NAME" ]; then
            echo "Root CA secret name is required"; usage; exit 1
        fi
        if [ -z "$CA_OUTPUT_FILE" ]; then
            echo "CA output file is required"; usage; exit 1
        fi
    fi

    export VAULT_ADDR="$OPENBAO_URL"
    if [ "$SKIP_VERIFY" = true ]; then
        export VAULT_SKIP_VERIFY=true
    fi
}

check_prerequisites() {
    for bin in bao jq aws; do
        if ! command -v "$bin" &> /dev/null; then
            echo "Error: $bin is not installed"
            exit 1
        fi
    done
}

get_aws_cmd() {
    if [ -n "$PROFILE" ]; then
        echo "aws --profile $PROFILE --region $REGION"
    else
        echo "aws --region $REGION"
    fi
}

log_message() {
    local level=$1
    shift
    local message="$*"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $message"
}

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

check_openbao_status() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1

    while [[ $attempt -le $max_retries ]]
    do
        log_message "INFO" "Attempt $attempt: Checking $OPENBAO_URL..."
        status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")

        if [ "$status_code" = "200" ]; then
            log_message "INFO" "OpenBao is initialized, unsealed, and active"
            return 0
        fi

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

    if $aws_cmd secretsmanager describe-secret --secret-id "$secret_name" >/dev/null 2>&1; then
        log_message "INFO" "Secret $secret_name exists, updating it..."
        if ! $aws_cmd secretsmanager update-secret --secret-id "$secret_name" --secret-string "$secret_value" >/dev/null 2>&1; then
            log_message "ERROR" "Failed to update secret $secret_name"
            return 1
        fi
    else
        log_message "INFO" "Secret $secret_name does not exist, creating it..."
        if ! $aws_cmd secretsmanager create-secret --name "$secret_name" --secret-string "$secret_value" >/dev/null 2>&1; then
            log_message "ERROR" "Failed to create secret $secret_name"
            return 1
        fi
    fi

    log_message "INFO" "Successfully updated AWS Secrets Manager entry for $secret_name"
    return 0
}

# Initialize OpenBao
#
# The recovery keys are persisted, in their own secret. Previously only the
# root token was kept and the recovery keys were printed and dropped, which
# meant `bao operator generate-root` was impossible: losing or revoking the
# root token left the cluster unrecoverable, and the restore path in
# scripts/openbao-snapshot.sh could never authenticate.
#
# They go in a SEPARATE secret from the root token on purpose - co-locating a
# credential with the material that regenerates it makes the pair worth exactly
# as much as the weaker of the two.
init_openbao() {
    if ! wait_for_openbao; then
        log_message "ERROR" "Failed to wait for OpenBao to be ready"
        exit 1
    fi

    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")
    if [ "$status_code" = "200" ]; then
        log_message "INFO" "OpenBao is already initialized, unsealed, and active"
        exit 0
    fi

    if [ "$status_code" != "501" ]; then
        log_message "ERROR" "Unexpected status code: $status_code"
        exit 1
    fi

    log_message "INFO" "OpenBao is not initialized - proceeding with initialization"
    init_output=$(bao operator init \
        -recovery-shares="$RECOVERY_SHARES" \
        -recovery-threshold="$RECOVERY_THRESHOLD" \
        -format=json)

    root_token=$(echo "$init_output" | jq -r '.root_token // empty')
    if [ -z "$root_token" ]; then
        log_message "ERROR" "Failed to extract root token from initialization output"
        exit 1
    fi

    recovery_keys=$(echo "$init_output" | jq -c '.recovery_keys_b64 // empty')
    if [ -z "$recovery_keys" ] || [ "$recovery_keys" = "null" ]; then
        log_message "ERROR" "Failed to extract recovery keys from initialization output"
        exit 1
    fi

    AWS_CMD=$(get_aws_cmd)

    log_message "INFO" "Storing root token in AWS Secrets Manager..."
    root_token_value=$(jq -n --arg token "$root_token" '{"token": $token}')
    if ! create_or_update_secret "$AWS_CMD" "$ROOT_TOKEN_SECRET_NAME" "$root_token_value"; then
        log_message "ERROR" "Failed to store root token in AWS Secrets Manager"
        exit 1
    fi

    log_message "INFO" "Storing recovery keys in AWS Secrets Manager..."
    recovery_value=$(jq -n \
        --argjson keys "$recovery_keys" \
        --argjson threshold "$RECOVERY_THRESHOLD" \
        '{"recovery_keys": $keys, "recovery_key": $keys[0], "threshold": $threshold}')
    if ! create_or_update_secret "$AWS_CMD" "$RECOVERY_KEYS_SECRET_NAME" "$recovery_value"; then
        log_message "ERROR" "Failed to store recovery keys in AWS Secrets Manager"
        exit 1
    fi

    unset init_output root_token recovery_keys root_token_value recovery_value

    log_message "INFO" "Performing final health check..."
    if ! check_openbao_status; then
        log_message "ERROR" "Final health check failed"
        exit 1
    fi
}

# Write the CA chain to disk so the Vault provider can verify the server
# certificate (var.openbao_ca_cert_file in the management stack). A provider
# block cannot depend on a resource, so this cannot be a local_file.
write_ca() {
    AWS_CMD=$(get_aws_cmd)

    ca_chain=$($AWS_CMD secretsmanager get-secret-value \
        --secret-id "$ROOT_CA_SECRET_NAME" \
        --query "SecretString" --output text | jq -r '.ca // empty')

    if [ -z "$ca_chain" ]; then
        log_message "ERROR" "Failed to retrieve the CA chain from $ROOT_CA_SECRET_NAME"
        exit 1
    fi

    ca_dir=$(dirname "$CA_OUTPUT_FILE")
    if [ -L "$ca_dir" ]; then
        # `opentofu/aws/openbao/management/.tls` is a committed symlink to
        # ../cluster/.tls. On a fresh checkout that target does not exist yet
        # (.tls/ is gitignored), and `mkdir -p` on a dangling symlink fails with
        # "File exists" rather than creating the target. Resolve one level by
        # hand - `readlink -f` is not portable to BSD/macOS.
        link_target=$(cd "$(dirname "$ca_dir")" && readlink "$(basename "$ca_dir")")
        case "$link_target" in
            /*) ;;
            *) link_target="$(dirname "$ca_dir")/$link_target" ;;
        esac
        mkdir -p "$link_target"
    else
        mkdir -p "$ca_dir"
    fi

    printf '%s\n' "$ca_chain" > "$CA_OUTPUT_FILE"
    chmod 0600 "$CA_OUTPUT_FILE"

    if ! openssl x509 -in "$CA_OUTPUT_FILE" -noout -subject >/dev/null 2>&1; then
        log_message "ERROR" "$CA_OUTPUT_FILE is not a valid PEM certificate"
        exit 1
    fi

    log_message "INFO" "Wrote the CA chain to $CA_OUTPUT_FILE"
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
    ca)
        parse_args "$@"
        check_prerequisites
        write_ca
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
