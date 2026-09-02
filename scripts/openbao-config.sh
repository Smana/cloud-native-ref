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
SNAPSHOT_BUCKET=""
CA_FILE=""
FRESHNESS_DAYS=8

usage() {
    echo "Usage: $0 <command> [options]"
    echo "Commands:"
    echo "  init          Initialize OpenBao cluster"
    echo "  ca            Write the CA chain to a local file for TLS verification"
    echo "  rehydrate     Initialise a fresh node and restore the lineage's newest snapshot"
    echo "                (falls back to a plain init when the bucket holds none)"
    echo "  pre-destroy-snapshot"
    echo "                Take one last snapshot before the cluster stack is destroyed"
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
    echo "  --snapshot-bucket <Name>                  S3 bucket (aws) or GCS bucket (gcp) holding raft snapshots"
    echo "                                             (required for rehydrate and pre-destroy-snapshot)"
    echo "  --ca-file <Path>                          CA chain to verify the server with (sets VAULT_CACERT)"
    echo "  --freshness-days <N>                      Age past which a restored snapshot is reported as old (default: ${FRESHNESS_DAYS})"
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
            --snapshot-bucket)            SNAPSHOT_BUCKET="$2"; shift 2 ;;
            --ca-file)                    CA_FILE="$2"; shift 2 ;;
            --freshness-days)             FRESHNESS_DAYS="$2"; shift 2 ;;
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

    if [ "$COMMAND" = "init" ] || [ "$COMMAND" = "rehydrate" ]; then
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

    if [ "$COMMAND" = "rehydrate" ] || [ "$COMMAND" = "pre-destroy-snapshot" ]; then
        if [ -z "$SNAPSHOT_BUCKET" ]; then
            echo "--snapshot-bucket is required for $COMMAND"; usage; exit 1
        fi
    fi
    if [ "$COMMAND" = "pre-destroy-snapshot" ]; then
        if [ -z "$OPENBAO_URL" ] || [ -z "$ROOT_TOKEN_SECRET_NAME" ]; then
            echo "--url and --root-token-secret-name are required for pre-destroy-snapshot"; usage; exit 1
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
    if [ -n "$CA_FILE" ]; then
        if [ ! -r "$CA_FILE" ]; then
            echo "Error: --ca-file $CA_FILE is not readable (run the 'ca' subcommand first)" >&2
            exit 1
        fi
        export VAULT_CACERT="$CA_FILE"
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

# Environment the sibling snapshot script needs. It is POSIX sh and calls the
# cloud CLIs bare, so the region/profile/ADC choices made here have to reach it
# through the environment rather than flags.
export_snapshot_env() {
    export CLOUD
    if [ "$CLOUD" = "aws" ]; then
        export AWS_DEFAULT_REGION="$REGION"
        if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
    else
        export CLOUDSDK_CORE_PROJECT="$PROJECT"
        # Same identity OpenTofu uses -- see scripts/lib/gcloud-adc.sh for the
        # day this cost when it was left to the CLI account.
        if [ -z "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ]; then
            if token=$(gcloud auth application-default print-access-token 2>/dev/null) && [ -n "$token" ]; then
                export CLOUDSDK_AUTH_ACCESS_TOKEN="$token"
            fi
            unset token
        fi
    fi
}

# Name of the newest snapshot object in the lineage bucket, or empty.
latest_snapshot() {
    if [ "$CLOUD" = "gcp" ]; then
        local listing
        if ! listing=$(gcp_gcloud storage ls "gs://${SNAPSHOT_BUCKET}/" 2>/dev/null); then
            echo ""
            return 0
        fi
        printf '%s\n' "$listing" | sed 's#.*/##' | grep '\.snap$' | sort | tail -n1
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        local key
        key=$($aws_cmd s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" \
            --query 'sort_by(Contents, &LastModified)[-1].Key' --output text 2>/dev/null || true)
        if [ "$key" = "None" ]; then key=""; fi
        printf '%s' "$key"
    fi
}

# The PKI mount's CA endpoint is unauthenticated, which makes it the one thing a
# rehydrate can assert without a token: if it answers with a certificate, the
# barrier unwrapped and the mount came back.
verify_pki_present() {
    local pem
    if ! pem=$(curl -fsS "${VAULT_CACERT:+--cacert $VAULT_CACERT}" ${VAULT_SKIP_VERIFY:+-k} "$OPENBAO_URL/v1/pki_private_issuer/ca/pem"); then
        log_message "ERROR" "pki_private_issuer/ca/pem did not answer -- the PKI mount is missing from the restored state"
        return 1
    fi
    if ! printf '%s\n' "$pem" | openssl x509 -noout -subject >/dev/null 2>&1; then
        log_message "ERROR" "pki_private_issuer/ca/pem returned something that is not a certificate"
        return 1
    fi
    log_message "INFO" "PKI issuer present: $(printf '%s\n' "$pem" | openssl x509 -noout -subject)"
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
    # as jq runs. Same class of leak closed in zitadel-idp.sh and
    # zitadel-oidc-clients.sh.
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

# Rehydrate a freshly booted, uninitialised node from the lineage's newest
# snapshot. This is what makes OpenBao's storage a derived artefact: the
# durable copy is the snapshot in the lineage bucket, sealed by the lineage's
# KMS key, and the running process is rebuilt from it on every deploy.
#
# Three rules, in code below and in the design:
#   1. The throwaway root token and recovery shares from `operator init` are
#      NEVER written to the secret store. The restore replaces them with the
#      snapshot's, which are the ones already stored.
#   2. Idempotent: a node that is already initialised and unsealed is left alone.
#   3. The freshness guard is `warn`, not `fail`: there is no populated cluster
#      to protect, so age is information here.
rehydrate_openbao() {
    if ! wait_for_openbao; then
        log_message "ERROR" "Failed to wait for OpenBao to be ready"
        exit 1
    fi

    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health")
    case "$status_code" in
        200)
            log_message "INFO" "OpenBao is already initialized, unsealed, and active -- nothing to rehydrate"
            exit 0 ;;
        501) ;;
        *)
            log_message "ERROR" "Unexpected status code: $status_code"
            exit 1 ;;
    esac

    export_snapshot_env
    local latest
    latest=$(latest_snapshot)
    if [ -z "$latest" ]; then
        log_message "INFO" "No snapshot in ${SNAPSHOT_BUCKET}: first deploy of this lineage. Initialising and storing the new keys."
        init_openbao
        return 0
    fi

    log_message "INFO" "Snapshot ${latest} found in ${SNAPSHOT_BUCKET}. Initialising with throwaway shares, then restoring."
    local init_output root_token
    init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
    root_token=$(printf '%s' "$init_output" | jq -r '.root_token // empty')
    unset init_output
    if [ -z "$root_token" ]; then
        log_message "ERROR" "operator init returned no root token"
        exit 1
    fi

    if ! check_openbao_status; then
        log_message "ERROR" "Node did not become active after init"
        exit 1
    fi

    local scratch
    scratch=$(mktemp -d)
    # VAULT_TOKEN drives the snapshot script's authenticate(); the recovery keys
    # secret is the LINEAGE's, which is what generate_root_token needs once the
    # restored token store has replaced the throwaway one.
    if ! VAULT_TOKEN="$root_token" RECOVERY_KEYS_SECRET_ID="$RECOVERY_KEYS_SECRET_NAME" \
        sh "$(dirname "$0")/openbao-snapshot.sh" restore \
            -a "$OPENBAO_URL" -b "$SNAPSHOT_BUCKET" -s "$scratch/bao.snap" \
            -d "$FRESHNESS_DAYS" --freshness warn; then
        rm -rf "$scratch"
        log_message "ERROR" "Restore failed. The node is initialised with THROWAWAY keys that were not stored: destroy and redeploy the cluster stack rather than trying to use it."
        exit 1
    fi
    rm -rf "$scratch"
    unset root_token

    if ! verify_pki_present; then
        exit 1
    fi
    log_message "INFO" "Rehydrated from ${latest}."
}

# One last snapshot before `tofu destroy` takes the node away. Runs from the
# operator's context with the lineage root token: the in-cluster CronJob cannot
# do this because `--reverse destroy` has already removed the cluster it ran in.
#
# Fails hard when OpenBao is unreachable, because destroying anyway loses every
# write since the last scheduled snapshot. TM_OPENBAO_SKIP_SNAPSHOT=true is the
# explicit override for a node that is already gone.
pre_destroy_snapshot() {
    if [ "${TM_OPENBAO_SKIP_SNAPSHOT:-false}" = "true" ]; then
        log_message "WARN" "TM_OPENBAO_SKIP_SNAPSHOT=true -- skipping the pre-destroy snapshot"
        exit 0
    fi

    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health" || true)
    if [ "$status_code" != "200" ]; then
        log_message "ERROR" "OpenBao at $OPENBAO_URL is not active (HTTP ${status_code:-none}); refusing to destroy without a snapshot."
        log_message "ERROR" "If the node is genuinely gone, re-run with TM_OPENBAO_SKIP_SNAPSHOT=true."
        exit 1
    fi

    local token
    if ! token=$(secret_read "$ROOT_TOKEN_SECRET_NAME" | jq -r '.token // empty') || [ -z "$token" ]; then
        log_message "ERROR" "Could not read the root token from $ROOT_TOKEN_SECRET_NAME"
        exit 1
    fi

    export_snapshot_env
    local scratch
    scratch=$(mktemp -d)
    if ! VAULT_TOKEN="$token" sh "$(dirname "$0")/openbao-snapshot.sh" save \
            -a "$OPENBAO_URL" -b "$SNAPSHOT_BUCKET" -s "$scratch/bao.snap"; then
        rm -rf "$scratch"
        log_message "ERROR" "Pre-destroy snapshot failed; not destroying."
        exit 1
    fi
    rm -rf "$scratch"
    unset token
    log_message "INFO" "Pre-destroy snapshot stored in ${SNAPSHOT_BUCKET}."
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
    rehydrate)
        parse_args "$@"
        check_prerequisites
        rehydrate_openbao
        ;;
    pre-destroy-snapshot)
        parse_args "$@"
        check_prerequisites
        # The CA is fetched by the caller (`ca` subcommand) so VAULT_CACERT can be
        # set; --skip-verify is the fallback for a first bootstrap.
        pre_destroy_snapshot
        ;;
    *)
        echo "Unknown command: $COMMAND"
        usage
        exit 1
        ;;
esac
