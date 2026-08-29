#!/bin/bash

set -euo pipefail

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"

# This script is used to configure OpenBao. It supports two operations:
# - init: Initialize the OpenBao cluster, then store the root token and the
#         recovery keys in two SEPARATE secret store entries (AWS Secrets
#         Manager or GCP Secret Manager, selected with --cloud)
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
REGION_EXPLICIT=false
PROFILE=""
CLOUD="aws"
PROJECT=""

usage() {
    echo "Usage: $0 <command> [options]"
    echo "Commands:"
    echo "  init          Initialize OpenBao cluster"
    echo "  ca            Write the CA chain to a local file for TLS verification"
    echo ""
    echo "Common Options:"
    echo "  --url <OpenBao URL>                       OpenBao server URL (required for init)"
    echo "  --root-token-secret-name <Secret Name>    Secret for the root token (required for init)"
    echo "  --recovery-keys-secret-name <Secret Name> Secret for the recovery keys (required for init)"
    echo "  --recovery-shares <N>                     Number of recovery key shares (default: ${RECOVERY_SHARES})"
    echo "  --recovery-threshold <N>                  Shares needed to reconstruct (default: ${RECOVERY_THRESHOLD})"
    echo "  --root-ca-secret-name <Secret Name>       Secret holding the CA chain (required for ca)."
    echo "                                             On AWS this holds JSON with a '.ca' field."
    echo "                                             On GCP it receives the CA CHAIN secret"
    echo "                                             (raw PEM) -- by design no root-CA secret"
    echo "                                             exists on GCP, only the chain."
    echo "  --ca-output-file <Path>                   Where to write the CA chain (required for ca)"
    echo "  --skip-verify                             Skip TLS verification"
    echo "  --region <Region>                         AWS region (default: ${REGION})"
    echo "  --profile <Profile>                       AWS profile"
    echo "  --cloud <aws|gcp>                         Secret backend (default: aws)"
    echo "  --project <Project ID>                    GCP project (required for --cloud gcp)"
    echo ""
    echo "Example:"
    echo "  $0 init --url https://openbao:8200 --root-token-secret-name openbao/root-token \\"
    echo "          --recovery-keys-secret-name openbao/recovery-keys"
    echo "  $0 ca --root-ca-secret-name certificates/domain.tld/root-ca --ca-output-file .tls/ca.pem"
    echo "  $0 ca --cloud gcp --project ogenki-435905 \\"
    echo "          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem"
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
            --region)                     REGION="$2"; REGION_EXPLICIT=true; shift 2 ;;
            --profile)                    PROFILE="$2"; shift 2 ;;
            --cloud)                      CLOUD="$2"; shift 2 ;;
            --project)                    PROJECT="$2"; shift 2 ;;
            *)
                echo "Invalid argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    case "$CLOUD" in
        aws) ;;
        gcp)
            if [ -z "$PROJECT" ]; then
                echo "Error: --project is required with --cloud gcp" >&2
                exit 1
            fi
            # Fail here rather than at the API call: passing an AWS-only flag to
            # GCP is a mistake about which cloud you are on, and the API error
            # would not say so.
            if [ -n "$PROFILE" ]; then
                echo "Error: --profile is AWS-only and cannot be used with --cloud gcp" >&2
                exit 1
            fi
            if [ "$REGION_EXPLICIT" = true ]; then
                echo "Error: --region is AWS-only and cannot be used with --cloud gcp" >&2
                exit 1
            fi
            ;;
        *)
            echo "Error: --cloud must be 'aws' or 'gcp' (got '$CLOUD')" >&2
            exit 1
            ;;
    esac

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
    local cloud_bin="aws"
    if [ "$CLOUD" = "gcp" ]; then
        cloud_bin="gcloud"
    fi
    for bin in bao jq "$cloud_bin"; do
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

# gcloud runs as the identity OpenTofu uses -- see scripts/lib/gcloud-adc.sh
# for why, and for the 2026-08-29 failure that made it necessary. This was a
# private copy here first; it moved to lib/ once six more scripts turned out to
# need exactly the same thing.

# Write a secret value, creating the secret if it does not exist. Dispatches
# on $CLOUD so init_openbao() and write_ca() don't need to know which backend
# they're talking to.
# Usage: secret_write <name> <value>
secret_write() {
    local secret_name=$1
    local secret_value=$2

    if [ "$CLOUD" = "gcp" ]; then
        if gcp_gcloud secrets describe "$secret_name" --project "$PROJECT" >/dev/null 2>&1; then
            log_message "INFO" "Secret $secret_name exists, updating it..."
            if ! printf '%s' "$secret_value" | gcp_gcloud secrets versions add "$secret_name" \
                --project "$PROJECT" --data-file=- >/dev/null 2>&1; then
                log_message "ERROR" "Failed to update secret $secret_name"
                return 1
            fi
        else
            log_message "INFO" "Secret $secret_name does not exist, creating it..."
            if ! printf '%s' "$secret_value" | gcp_gcloud secrets create "$secret_name" \
                --project "$PROJECT" --replication-policy=automatic --data-file=- >/dev/null 2>&1; then
                log_message "ERROR" "Failed to create secret $secret_name"
                return 1
            fi
        fi
        log_message "INFO" "Successfully updated GCP Secret Manager entry for $secret_name"
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
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
    fi

    return 0
}

# Read the current value of a secret to stdout.
# Usage: secret_read <name>
secret_read() {
    local secret_name=$1

    if [ "$CLOUD" = "gcp" ]; then
        gcp_gcloud secrets versions access latest --secret "$secret_name" --project "$PROJECT"
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        $aws_cmd secretsmanager get-secret-value --secret-id "$secret_name" \
            --query SecretString --output text
    fi
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

    log_message "INFO" "Storing root token..."
    # On STDIN via `-Rs`, not --arg -- --arg puts the root token on jq's argv,
    # readable by any process on the box via /proc/<pid>/cmdline for as long
    # as jq runs. Same class of leak closed in zitadel-idp.sh, harbor-oidc.sh
    # and zitadel-oidc-clients.sh.
    root_token_value=$(printf '%s' "$root_token" | jq -Rs '{"token": .}')
    if ! secret_write "$ROOT_TOKEN_SECRET_NAME" "$root_token_value"; then
        log_message "ERROR" "Failed to store root token"
        exit 1
    fi

    log_message "INFO" "Storing recovery keys..."
    # Same fix, on the array this time: $recovery_keys is already a JSON
    # array (from `jq -c` above), so it goes in on STDIN as `.` rather than
    # via --argjson. $RECOVERY_THRESHOLD is a plain integer, not a secret --
    # it stays a normal --argjson.
    recovery_value=$(printf '%s' "$recovery_keys" | jq --argjson threshold "$RECOVERY_THRESHOLD" \
        '{"recovery_keys": ., "recovery_key": .[0], "threshold": $threshold}')
    if ! secret_write "$RECOVERY_KEYS_SECRET_NAME" "$recovery_value"; then
        log_message "ERROR" "Failed to store recovery keys"
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
#
# The secret's SHAPE differs by cloud, and that is by design, not an
# inconsistency to paper over:
#   - AWS: the root-CA secret (certificates/priv.aws.ogenki.io/root-ca) is
#     hand-loaded per the manual ceremony in pki-and-secrets.md as JSON with
#     `.ca` (and `.bundle`) fields.
#   - GCP: openbao-priv-gcp-ca-chain is raw PEM (`gcloud secrets create
#     ... --data-file=ca-chain.pem`, plan Task 3 Step 6) -- PEM is the natural
#     shape for a CA bundle, and the file is consumed directly as
#     VAULT_CACERT. No root-CA secret exists on GCP at all; only the chain.
# So the read has to branch on $CLOUD rather than assume one shape for both.
write_ca() {
    local raw
    if ! raw=$(secret_read "$ROOT_CA_SECRET_NAME"); then
        log_message "ERROR" "Failed to retrieve the CA chain from $ROOT_CA_SECRET_NAME"
        exit 1
    fi

    if [ "$CLOUD" = "gcp" ]; then
        ca_chain="$raw"
    else
        # Guarded explicitly rather than left to `pipefail`: piping `$raw`
        # through `jq` and letting a parse failure propagate would still exit
        # non-zero, but via jq's own stderr rather than this script's error
        # message, and set -e would kill the script before the friendly
        # message below ever printed.
        if ! ca_chain=$(printf '%s' "$raw" | jq -r '.ca // empty' 2>/dev/null); then
            ca_chain=""
        fi
    fi

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
