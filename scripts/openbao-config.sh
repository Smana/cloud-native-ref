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
        # BOTH, and in this order of precedence: the AWS CLI resolves AWS_REGION
        # ahead of AWS_DEFAULT_REGION, so exporting only the latter lets an
        # AWS_REGION already in the operator's shell send the child to a
        # different region than the parent's own --region calls use -- a region
        # split inside one operation.
        export AWS_REGION="$REGION"
        export AWS_DEFAULT_REGION="$REGION"
        # Deliberately not exported when empty: that leaves an inherited
        # AWS_PROFILE alone, matching get_aws_cmd's behaviour.
        if [ -n "$PROFILE" ]; then export AWS_PROFILE="$PROFILE"; fi
    else
        export CLOUDSDK_CORE_PROJECT="$PROJECT"
        # scripts/lib/gcloud-adc.sh exposes gcp_gcloud (a wrapper) and
        # gcp_gcloud_identity (a logger), not a bare token accessor, so the
        # token is resolved directly here instead of through the library.
        #
        # `local adc_token` is not cosmetic. Bash is DYNAMICALLY SCOPED: this
        # function is called by pre_destroy_snapshot, which declares its own
        # `local token` holding the lineage root token -- an unlocalised
        # assignment plus `unset token` in here would clobber the caller's
        # variable, handing the child an empty VAULT_TOKEN. Measured in bash
        # 5.3. Naming this `adc_token` rather than `token` avoids the collision
        # outright; `local` is what makes it safe even if the name ever
        # collided again.
        if [ -z "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ]; then
            local adc_token
            if adc_token=$(gcloud auth application-default print-access-token 2>/dev/null) && [ -n "$adc_token" ]; then
                export CLOUDSDK_AUTH_ACCESS_TOKEN="$adc_token"
            fi
        fi
    fi
}

# Newest snapshot object in the lineage bucket.
#
#   stdout = the object name, or EMPTY when the bucket genuinely holds none
#   return = 0 on a successful listing, 1 when the listing itself FAILED
#
# The two must not be conflated, and conflating them is the single most
# dangerous mistake available in this file. An empty answer routes the caller
# to "first deploy of this lineage -> plain init", which WRITES a fresh root
# token and fresh recovery keys over the lineage's. Reaching that from an
# expired session or a mistyped --profile, while the bucket still holds every
# snapshot, produces an OpenBao whose stored recovery keys no longer match any
# snapshot -- discovered during an incident.
#
# The sibling script already argues this at length for its own listing
# (container-images/openbao-snapshot/openbao-snapshot.sh, `restore`): "this is a
# listing failure, NOT an empty bucket". Same rule here.
latest_snapshot() {
    if [ "$CLOUD" = "gcp" ]; then
        local listing
        if ! listing=$(gcp_gcloud storage ls "gs://${SNAPSHOT_BUCKET}/"); then
            log_message "ERROR" "could not list gs://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        # `grep || true`: grep exits 1 when it matches nothing, and this file
        # runs with `set -o pipefail`, so an unguarded grep in a pipeline turns
        # a legitimately empty bucket into a hard failure.
        printf '%s\n' "$listing" | sed 's#.*/##' | { grep '\.snap$' || true; } | sort | tail -n1
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        local out
        # Full JSON, filtered by jq, rather than --query sort_by(...)[-1]: that
        # query ERRORS on an empty bucket, so exit status alone could not
        # separate "empty" from "could not list".
        if ! out=$($aws_cmd s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" --output json); then
            log_message "ERROR" "could not list s3://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        printf '%s' "$out" | jq -r '(.Contents // []) | if length == 0 then "" else (sort_by(.LastModified) | last | .Key) end'
    fi
}

# The PKI mount's CA endpoint is unauthenticated, which makes it the one thing a
# rehydrate can assert without a token: if it answers with a certificate that
# chains to the CA we already trust, the barrier unwrapped and the mount came
# back.
verify_pki_present() {
    # argv built as an ARRAY. `"${VAULT_CACERT:+--cacert $VAULT_CACERT}"` looks
    # right and is not: quoted, it passes `--cacert /path` as ONE argv element
    # ("option --cacert /path: is unknown"), and when the variable is unset it
    # passes an empty word ("blank argument where content is expected"). Either
    # way curl exits 2 on every run and this function reports a missing PKI
    # mount that is actually present -- the most misleading message this script
    # can produce, on the disaster-recovery path. Measured, both states.
    local -a curl_args=(-fsS)
    if [ -n "${VAULT_CACERT:-}" ]; then curl_args+=(--cacert "$VAULT_CACERT"); fi
    if [ -n "${VAULT_SKIP_VERIFY:-}" ]; then curl_args+=(-k); fi

    local pem
    if ! pem=$(curl "${curl_args[@]}" "$OPENBAO_URL/v1/pki_private_issuer/ca/pem"); then
        log_message "ERROR" "pki_private_issuer/ca/pem did not answer. The transport failed, so this could be TLS trust or an unreachable node -- not necessarily a missing mount."
        return 1
    fi
    if ! printf '%s\n' "$pem" | openssl x509 -noout -subject >/dev/null 2>&1; then
        log_message "ERROR" "pki_private_issuer/ca/pem returned something that is not a certificate"
        return 1
    fi
    log_message "INFO" "PKI issuer present: $(printf '%s\n' "$pem" | openssl x509 -noout -subject)"

    # Chain it to the CA we were given, which makes this the assertion the
    # design actually promises ("issuer chains to the offline root") rather than
    # just "the bytes parse". Skipped when no --ca-file was passed, since there
    # is then nothing to verify against.
    if [ -n "${VAULT_CACERT:-}" ]; then
        if ! printf '%s\n' "$pem" | openssl verify -CAfile "$VAULT_CACERT" >/dev/null 2>&1; then
            log_message "ERROR" "the restored PKI issuer does NOT chain to ${VAULT_CACERT}. The mount came back, but under a different root than this lineage's."
            return 1
        fi
        log_message "INFO" "PKI issuer chains to ${VAULT_CACERT}."
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

    status_code=$(curl -k -s -o /dev/null -w "%{http_code}" "$OPENBAO_URL/v1/sys/health" || true)
    case "$status_code" in
        200)
            # Initialised and unsealed -- but that is also exactly what a node
            # left behind by a FAILED restore looks like: throwaway keys, no
            # lineage data. Exiting 0 on the strength of a 200 alone would turn
            # a loud failure into a silent success on the next deploy, and the
            # management stack would then run against an empty store. One
            # unauthenticated request settles it.
            if verify_pki_present; then
                log_message "INFO" "OpenBao is already initialized, unsealed, and holds the PKI -- nothing to rehydrate"
                exit 0
            fi
            log_message "ERROR" "OpenBao is initialized and unsealed but has NO PKI mount. This is the state a failed"
            log_message "ERROR" "restore leaves behind: the node holds throwaway keys that were never stored, so"
            log_message "ERROR" "nothing can authenticate to it. Destroy and redeploy the cluster stack with"
            log_message "ERROR" "TM_OPENBAO_SKIP_SNAPSHOT=true -- there is nothing on this node worth snapshotting."
            exit 1 ;;
        501) ;;
        *)
            log_message "ERROR" "Unexpected status code: $status_code"
            exit 1 ;;
    esac

    export_snapshot_env

    # Distinguish "the bucket is empty" from "we could not read the bucket".
    # Only the first may proceed to a plain init, because a plain init OVERWRITES
    # the lineage's stored root token and recovery keys. Getting there from an
    # expired session, while the bucket still holds every snapshot, is how a
    # lineage becomes unrecoverable.
    local latest
    if ! latest=$(latest_snapshot); then
        log_message "ERROR" "Refusing to initialise: cannot prove ${SNAPSHOT_BUCKET} is empty."
        log_message "ERROR" "Initialising now would overwrite this lineage's stored root token and"
        log_message "ERROR" "recovery keys. Fix the listing (credentials, region, bucket name) and re-run."
        exit 1
    fi

    if [ -z "$latest" ]; then
        log_message "INFO" "No snapshot in ${SNAPSHOT_BUCKET}: first deploy of this lineage. Initialising and storing the new keys."
        init_openbao
        return 0
    fi

    # Pre-flight, all of it before the irreversible init. Each of these used to
    # be discovered only afterwards, stranding the node.
    if ! echo "$FRESHNESS_DAYS" | grep -Eq '^[0-9]+$'; then
        log_message "ERROR" "--freshness-days must be a positive integer (got '${FRESHNESS_DAYS}')"
        exit 1
    fi
    for bin in openssl curl; do
        if ! command -v "$bin" >/dev/null 2>&1; then
            log_message "ERROR" "$bin is required by the restore path and is not installed"
            exit 1
        fi
    done
    if ! secret_read "$RECOVERY_KEYS_SECRET_NAME" >/dev/null 2>&1; then
        log_message "ERROR" "Cannot read ${RECOVERY_KEYS_SECRET_NAME}. The restore mints a root token from it,"
        log_message "ERROR" "so refusing before the init rather than stranding the node afterwards."
        exit 1
    fi

    log_message "INFO" "Snapshot ${latest} found in ${SNAPSHOT_BUCKET}. Initialising with throwaway shares, then restoring."

    local scratch
    scratch=$(mktemp -d)
    # On a trap, not duplicated per branch: the scratch dir holds the downloaded
    # snapshot, and an interrupt mid-restore would otherwise leave it behind.
    trap 'rm -rf "$scratch"' EXIT INT TERM

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

    # VAULT_TOKEN is the throwaway root token, and it is what performs the
    # restore: it is the only credential that exists on this node. The
    # LINEAGE's recovery keys are passed too, because the child needs them
    # AFTER the restore, once the snapshot's token store has replaced the
    # throwaway one.
    if ! VAULT_TOKEN="$root_token" RECOVERY_KEYS_SECRET_ID="$RECOVERY_KEYS_SECRET_NAME" \
        sh "$(dirname "$0")/openbao-snapshot.sh" restore \
            -a "$OPENBAO_URL" -b "$SNAPSHOT_BUCKET" -s "$scratch/bao.snap" \
            -d "$FRESHNESS_DAYS" --freshness warn; then
        log_message "ERROR" "Restore failed. The node is initialised with THROWAWAY keys that were never stored,"
        log_message "ERROR" "so nothing can authenticate to it. Destroy and redeploy the cluster stack; the"
        log_message "ERROR" "pre-destroy snapshot will refuse (no usable token), so pass"
        log_message "ERROR" "TM_OPENBAO_SKIP_SNAPSHOT=true -- there is nothing here worth snapshotting."
        exit 1
    fi
    unset root_token

    if ! verify_pki_present; then
        exit 1
    fi
    # Deliberately not naming ${latest}: the child re-lists and selects
    # independently, so its own "Restoring snapshot ..." line is the
    # authoritative one and this must not contradict it.
    log_message "INFO" "Rehydrate complete; see the restore output above for the snapshot used."
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

    # `export_snapshot_env` FIRST, then read the token. Order matters: that
    # function must not be able to touch this scope's `token`, and while it now
    # declares its own local, doing the read afterwards means a future edit to
    # it cannot reintroduce the clobber. (It did clobber it: bash is dynamically
    # scoped, so its non-local `token` assignment plus `unset token` destroyed
    # this one, and the child was handed an empty VAULT_TOKEN -- so a GCP
    # destroy could never take its final snapshot.)
    export_snapshot_env

    local root_token
    if ! root_token=$(secret_read "$ROOT_TOKEN_SECRET_NAME" | jq -r '.token // empty') || [ -z "$root_token" ]; then
        log_message "ERROR" "Could not read the root token from $ROOT_TOKEN_SECRET_NAME"
        exit 1
    fi

    local scratch
    scratch=$(mktemp -d)
    # On a trap: this scratch dir holds the real snapshot until it is uploaded,
    # so an interrupt mid-upload would otherwise leave it in /tmp.
    trap 'rm -rf "$scratch"' EXIT INT TERM

    if ! VAULT_TOKEN="$root_token" sh "$(dirname "$0")/openbao-snapshot.sh" save \
            -a "$OPENBAO_URL" -b "$SNAPSHOT_BUCKET" -s "$scratch/bao.snap"; then
        log_message "ERROR" "Pre-destroy snapshot failed; not destroying."
        exit 1
    fi
    unset root_token
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
