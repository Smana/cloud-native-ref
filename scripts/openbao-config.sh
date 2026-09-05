#!/bin/bash

set -euo pipefail

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"
# cloud-secret-store.sh re-sources gcloud-adc.sh, which re-runs its two
# `_gcloud_adc_*=""` initialisers. Harmless HERE and only here: both `.` lines
# run at load time, before anything has resolved a token, so the reset lands on
# values that are still empty. Do not move either line below a call that uses
# the ADC token.
# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "$0")/lib/cloud-secret-store.sh"

# Provenance the library stamps on a secret it CREATES (an existing secret just
# gets a new version, description and labels untouched). Set here rather than
# left at the library's defaults so an operator reading the console lands on
# this script, not on the shared helper.
STORE_WRITE_DESCRIPTION="OpenBao lineage material, written by scripts/openbao-config.sh"
STORE_WRITE_LABEL="openbao-config"

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
# Optional. A fixed address to reach OpenBao on when its DNS name does not
# resolve -- see pre_destroy_snapshot for why a teardown is exactly when that
# happens. Empty means "no fallback", which is the correct setting wherever the
# address is not deterministic (GCP assigns its load-balancer address
# dynamically, so the GCP destroy passes nothing).
FALLBACK_ADDRESS=""
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
    echo "  --fallback-address <IP>                   Fixed address to reach OpenBao on when its DNS name does not"
    echo "                                             resolve (pre-destroy-snapshot only; TLS still verifies the name)"
    echo "  --freshness-days <N>                      Age past which a restored snapshot is reported as old (default: ${FRESHNESS_DAYS})"
    echo ""
    echo "Environment:"
    echo "  OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true   Let 'rehydrate' skip snapshots sealed by a"
    echo "                                             DIFFERENT seal than this node's, and restore"
    echo "                                             the newest one this node's seal can unwrap."
    echo "                                             Default refuses instead, before the init:"
    echo "                                             skipping a newer snapshot discards every write"
    echo "                                             after it. Only for a failback, where the"
    echo "                                             foreign-sealed objects are not coming back."
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
            --fallback-address)           FALLBACK_ADDRESS="$2"; shift 2 ;;
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

    # scripts/lib/cloud-secret-store.sh takes its cloud configuration from the
    # ENVIRONMENT, not from parameters: it reads $CLOUD and $REGION (which this
    # script already names identically) plus $GCP_PROJECT, and it has no
    # --profile of its own. Both gaps are closed here, by exporting, rather than
    # by widening the library's signature: $AWS_PROFILE names the same profile
    # the explicit `--profile` names on the paths get_aws_cmd still builds (and
    # an explicit --profile wins where both apply, so the two cannot disagree),
    # and export_snapshot_env already exports it from the same source for the
    # snapshot child. One value, one meaning.
    if [ "$CLOUD" = "gcp" ]; then
        export GCP_PROJECT="$PROJECT"
    # Deliberately not exported when empty, matching export_snapshot_env and
    # get_aws_cmd: that leaves an AWS_PROFILE already in the operator's shell
    # alone instead of blanking it.
    elif [ -n "$PROFILE" ]; then
        export AWS_PROFILE="$PROFILE"
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

# Every binary any subcommand shells out to, checked ONCE, before any of them
# runs.
#
# `curl` and `openssl` were checked 75 lines into rehydrate_openbao, which is
# after the idempotency branch has already called verify_pki_present -- and that
# function needs both. Without openssl it reported "returned something that is
# not a certificate" about a perfectly good PEM, control fell through to the
# no-PKI analysis, and the script told the operator to *destroy a healthy
# OpenBao* with TM_OPENBAO_SKIP_SNAPSHOT=true, discarding its final snapshot.
# Measured with openssl off PATH.
#
# Checked for all four subcommands rather than per-command: `ca` and
# `rehydrate` use openssl, `init`/`rehydrate`/`pre-destroy-snapshot` use curl,
# and a missing binary is worth one boring uniform failure rather than four
# subtly different late ones. Anywhere the cloud CLI is installed, both of these
# are.
check_prerequisites() {
    local cloud_bin="aws"
    if [ "$CLOUD" = "gcp" ]; then
        cloud_bin="gcloud"
    fi
    for bin in bao jq curl openssl "$cloud_bin"; do
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

# The same line, ON STDERR. Mandatory for any function whose stdout a caller
# CAPTURES -- latest_snapshot, latest_snapshot_sealed, node_seal_type are all
# called as `x=$(f)`, so a log_message inside them is swallowed by the command
# substitution and the operator sees nothing. Measured: the seal-mismatch
# refusal printed not one word until these moved to stderr, which would have
# made a loud failure a silent one -- exactly the bug the gate exists to
# remove. Same reasoning as gcp_gcloud_identity's redirect in
# scripts/lib/gcloud-adc.sh, where a log line captured as data ended up inside
# a PEM file.
log_err() {
    log_message "ERROR" "$@" >&2
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

# ONE probe of OpenBao's health endpoint. Prints the HTTP status code; "000"
# when the connection never completed.
#
# The `standbyok`/`perfstandbyok` pair is a CORRECTNESS CONTRACT, not tuning.
# Every call in this file goes through the NLB, whose target group deliberately
# reports a standby as healthy, while a bare /v1/sys/health answers 200 only on
# the ACTIVE node -- so without them a perfectly healthy standby answers 429 and
# the caller reads that as a broken cluster. It cost ten minutes of polling in
# check_openbao_status and an outright "Unexpected status code: 429" exit in
# init_openbao, which was the FOURTH copy of this line and the one that was
# missed when the other three gained the parameters. That is why it is one
# function now: four copies made the contract a four-site edit with a silent
# failure mode.
#
# (The NLB's own probe in opentofu/aws/openbao/cluster/load_balancer.tf carries
# a DIFFERENT set -- uninitcode/sealedcode/performancestandbyok -- because it
# must report an uninitialised or sealed node as healthy so this script can
# reach it and initialise it. Different contract; do not unify them.)
#
# `|| true`: curl exits 7 on a refused connection, which under `set -e` killed
# the script before the status could be reported at all.
#
# NO RETRY LOOP IN HERE, on purpose. check_openbao_status wraps it in one; the
# other three callers need a single reading they handle themselves -- 501 means
# "not initialised yet, go ahead" to init_openbao, 200-without-PKI sends
# rehydrate_openbao into its bucket analysis, and anything but 200 makes
# pre_destroy_snapshot refuse. A poll in here would turn each of those into a
# ten-minute wait for a code they were ready to act on immediately.
openbao_health_code() {
    curl -k -s -o /dev/null -w "%{http_code}" \
        "$OPENBAO_URL/v1/sys/health?standbyok=true&perfstandbyok=true" || true
}

# Poll until OpenBao answers as INITIALISED AND UNSEALED. Deliberately NOT
# "active", and the wording matters because a caller acts on it: having accepted
# a standby's 200 (see openbao_health_code), this function cannot claim
# activation, and it no longer does.
#
# Nor should it try. Asking the same address for `sys/leader`'s `is_self` asks
# "is the node this request happened to land on the leader", which through a
# round-robin listener is a coin toss that would flap between polls; and an
# active-only probe is exactly the thing that broke. The property a caller
# actually needs is weaker anyway -- OpenBao standbys RPC the active node over
# the cluster port for any request that must be served there, which is what
# makes `snapshot save` and `snapshot restore` work through this same address
# (see the "No leader discovery" note in
# container-images/openbao-snapshot/openbao-snapshot.sh). Both clusters run
# single-node `dev` today, where this address IS the active node, so the
# distinction costs nothing here; the wording is what stops a future `ha`
# reader from believing an assertion the code never made.
check_openbao_status() {
    local max_retries=20
    local timeout_seconds=600
    local interval=$((timeout_seconds / max_retries))
    local attempt=1

    while [[ $attempt -le $max_retries ]]
    do
        log_message "INFO" "Attempt $attempt: Checking $OPENBAO_URL..."
        status_code=$(openbao_health_code)

        if [ "$status_code" = "200" ]; then
            log_message "INFO" "OpenBao is initialized and unsealed (this address may be a standby; requests that need the leader are forwarded)"
            return 0
        fi

        sleep $interval
        attempt=$((attempt + 1))
    done

    log_message "ERROR" "OpenBao did not become initialized and unsealed (last status: ${status_code:-none})"
    return 1
}

# gcloud runs as the identity OpenTofu uses -- see scripts/lib/gcloud-adc.sh
# for why, and for the 2026-08-29 failure that made it necessary. This was a
# private copy here first; it moved to lib/ once six more scripts turned out to
# need exactly the same thing.

# Write a secret value, creating the secret if it does not exist. The cloud
# dispatch happens in the library below, so init_openbao() does not need to know
# which backend it is talking to.
#
# That library is scripts/lib/cloud-secret-store.sh's store_write, and the
# reason for delegating is a security property rather than code reuse. This
# function had its own AWS branch that handed the value to the aws CLI as a
# command-line VALUE FLAG, which puts the payload on that process's argv --
# readable by any process on the box via /proc/<pid>/cmdline for as long as it
# runs. The payloads here are the OpenBao ROOT TOKEN and the RECOVERY KEYS,
# i.e. the same leak class already closed for jq --arg in init_openbao, missed
# on the cloud CLI. store_write takes the value on STDIN (via an `umask 077`
# temp file whose subshell EXIT trap shreds it), so nothing but the secret's
# NAME ever reaches an argv.
#
# The GCP branch was already stdin-based (`--data-file=-`) and behaves
# identically through the library; on AWS the value now goes in as
# --cli-input-json. Both branches also lose the old `2>&1`, so a failed write
# now reaches the operator with the CLI's own error text -- the same reason
# secret_read below does not use store_read.
# scripts/test-no-secret-argv.sh greps for these value flags, so the old shape
# cannot come back silently.
# Usage: secret_write <name> <value>
secret_write() {
    local secret_name=$1
    local secret_value=$2

    # store_write branches on existence itself; this extra describe call buys
    # the create-vs-update line below, which is worth one API round-trip in
    # THIS file: "does not exist, creating it" against a lineage that should
    # already hold both secrets is the loudest early symptom of the wrong
    # account, region or profile -- the failure mode latest_snapshot()'s
    # contract is written around.
    if store_exists "$secret_name"; then
        log_message "INFO" "Secret $secret_name exists, updating it..."
    else
        log_message "INFO" "Secret $secret_name does not exist, creating it..."
    fi

    if ! printf '%s' "$secret_value" | store_write "$secret_name"; then
        log_message "ERROR" "Failed to write secret $secret_name"
        return 1
    fi

    if [ "$CLOUD" = "gcp" ]; then
        log_message "INFO" "Successfully updated GCP Secret Manager entry for $secret_name"
    else
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
        # gcp_gcloud_token is scripts/lib/gcloud-adc.sh's accessor for the token
        # it has already MEMOISED for every gcp_gcloud call in this run. This
        # used to re-run `print-access-token` here, which paid a second
        # round-trip for a token already in hand and could hand the child a
        # different one than the parent was using.
        #
        # `local adc_token` is not cosmetic. Bash is DYNAMICALLY SCOPED: this
        # function is called by pre_destroy_snapshot, which declares its own
        # `local root_token` holding the lineage root token -- an unlocalised
        # assignment plus `unset root_token` in here would clobber the caller's
        # variable, handing the child an empty VAULT_TOKEN. Measured in bash
        # 5.3. Naming this `adc_token` rather than `root_token` avoids the
        # collision outright; `local` is what makes it safe even if the name
        # ever collided again.
        if [ -z "${CLOUDSDK_AUTH_ACCESS_TOKEN:-}" ]; then
            local adc_token
            adc_token=$(gcp_gcloud_token)
            if [ -n "$adc_token" ]; then
                export CLOUDSDK_AUTH_ACCESS_TOKEN="$adc_token"
            fi
        fi
    fi
}

# Newest snapshot object in the lineage bucket.
#
#   stdout = the object name, or EMPTY when the bucket holds NOTHING AT ALL
#   return = 0 on a successful listing
#            1 when the listing itself FAILED
#            2 when the listing succeeded, the bucket is NOT empty, and none of
#              what it holds is a selectable snapshot
#
# The three must not be conflated, and conflating them is the single most
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
#
# WHAT COUNTS AS A CANDIDATE: a TOP-LEVEL object whose name ends `.snap`, on
# both clouds. The AWS branch used to apply neither filter and hand back the
# newest key of any kind, so a README, or a snapshot an operator had moved
# aside under a prefix, became "the newest snapshot" -- snapshot_seal_segment
# then returned empty and the seal gate refused on a bucket whose real newest
# snapshot was restorable. (Reproduced: a bucket holding
# 2026-09-01T000000Z-awskms.snap, awskms/<older>.snap and README.md selected
# README.md.) A prefix is how "move this aside" is spelled, which is exactly why
# a prefixed object must not be selected.
#
# Return 2 exists BECAUSE of that filter. Without it, "the bucket holds objects
# but none is a candidate" -- every snapshot moved aside, say -- would answer
# EMPTY, and empty means plain init, which overwrites the lineage's stored keys.
# That is the same catastrophe the listing-failure branch above exists to
# prevent, reached by a different road. The GCP branch has always filtered, so
# it has always had this hole; it is closed for both here.
latest_snapshot() {
    if [ "$CLOUD" = "gcp" ]; then
        local listing newest n_objects
        if ! listing=$(gcp_gcloud storage ls "gs://${SNAPSHOT_BUCKET}/"); then
            log_err "could not list gs://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        # `grep || true`: grep exits 1 when it matches nothing, and this file
        # runs with `set -o pipefail`, so an unguarded grep in a pipeline turns
        # a legitimately empty bucket into a hard failure.
        newest=$(printf '%s\n' "$listing" | sed 's#.*/##' | { grep '\.snap$' || true; } | sort | tail -n1)
        n_objects=$(printf '%s\n' "$listing" | { grep -c . || true; })
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        local out newest n_objects
        # Full JSON, filtered by jq, rather than --query sort_by(...)[-1]: that
        # query ERRORS on an empty bucket, so exit status alone could not
        # separate "empty" from "could not list".
        if ! out=$($aws_cmd s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" --output json); then
            log_err "could not list s3://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        newest=$(printf '%s' "$out" | jq -r '
            (.Contents // [])
            | map(select((.Key | contains("/")) | not))
            | map(select(.Key | endswith(".snap")))
            | if length == 0 then "" else (sort_by(.LastModified) | last | .Key) end')
        n_objects=$(printf '%s' "$out" | jq -r '(.Contents // []) | length')
    fi

    if [ -n "$newest" ]; then
        printf '%s\n' "$newest"
        return 0
    fi

    # A count that is not a number is treated as a LISTING FAILURE, not as an
    # empty bucket. Only one of those two answers lets the caller initialise
    # over the lineage's stored keys, and it must not be reachable by accident.
    case "${n_objects:-}" in
        ''|*[!0-9]*)
            log_err "could not count the objects in ${SNAPSHOT_BUCKET} (got '${n_objects:-}')."
            log_err "Refusing to report it as empty on the strength of that."
            return 1 ;;
    esac
    if [ "$n_objects" -gt 0 ]; then
        return 2
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Seal legibility
# ---------------------------------------------------------------------------
#
# A Raft snapshot can only be restored under THE SEAL THAT ENCRYPTED IT, which
# the platform exploits on purpose: a GCP standby unseals with the *AWS* KMS
# key so it can restore AWS snapshots (ADR-0033). After a failover the GCP
# bucket therefore holds a mix -- mirrored objects are AWS-sealed by
# construction, and the standby's own are AWS-sealed too, because it ran with
# seal_provider = "awskms".
#
# Objects carry the seal in their name, `<UTC timestamp>-<seal>.snap`, written
# by the sibling save path. Keep this regex and the three helpers below
# textually in step with the copies in
# container-images/openbao-snapshot/openbao-snapshot.sh -- the duplication is
# structural, not laziness: THIS file must decide before `bao operator init`,
# and the sibling only runs after it. The whole point of the gate is that it
# lands on the near side of the irreversible step.
SNAP_NAME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-[a-z0-9]+\.snap$'

# The seal this node actually runs, on stdout; non-zero when it cannot be
# established.
#
# Read from the NODE, not from a variable: `seal_provider` in a tfvars file can
# disagree with the process that is running, and the point of the segment is to
# record what really wrapped the bytes. /v1/sys/seal-status is UNAUTHENTICATED
# -- it sits on OpenBao's bare HTTP mux next to /v1/sys/init and /v1/sys/health
# (openbao/openbao, http/handler.go:164 at v2.6.2) -- so it answers here, where
# the node is up but deliberately NOT yet initialised.
#
# `.type` is the BARRIER seal type: awskms, gcpckms, shamir. True only from
# OpenBao 2.4.0 onward -- before openbao/openbao#1638 the field was hardcoded
# "shamir" for every configuration (issue #1633). Both clusters pin 2.6.2
# (`openbao_version`, opentofu/{aws,gcp}/openbao/cluster/variables.tf), and the
# guard below refuses rather than trusting a misreport: labelling every object
# "-shamir" on both clouds would reintroduce the hazard invisibly.
node_seal_type() {
    # Same array-built argv, and for the same measured reason, as
    # verify_pki_present() below -- see the comment there.
    local -a curl_args=(-sS)
    if [ -n "${VAULT_CACERT:-}" ]; then curl_args+=(--cacert "$VAULT_CACERT"); fi
    if [ -n "${VAULT_SKIP_VERIFY:-}" ]; then curl_args+=(-k); fi

    local raw seal_type recovery
    raw=$(curl "${curl_args[@]}" "$OPENBAO_URL/v1/sys/seal-status" 2>/dev/null || true)
    if [ -z "$raw" ]; then
        log_err "could not read ${OPENBAO_URL}/v1/sys/seal-status. That endpoint needs no"
        log_err "token, so this is the node or the TLS trust, not a credential. The seal"
        log_err "type is what decides whether the lineage's newest snapshot can be"
        log_err "restored here at all, so refusing before the init rather than stranding"
        log_err "the node afterwards."
        return 1
    fi

    seal_type=$(printf '%s' "$raw" | jq -r '.type // empty' 2>/dev/null || true)
    recovery=$(printf '%s' "$raw" | jq -r 'if .recovery_seal == true then "true" else "false" end' 2>/dev/null || true)

    if [ -z "$seal_type" ]; then
        log_err "${OPENBAO_URL}/v1/sys/seal-status returned no '.type' field."
        log_err "response was: ${raw}"
        return 1
    fi
    if ! printf '%s' "$seal_type" | grep -Eq '^[a-z0-9]+$'; then
        log_err "seal type '${seal_type}' is not a plain lowercase token, so it cannot be"
        log_err "matched against an object name. Refusing."
        return 1
    fi
    # An impossible combination, and a precise fingerprint of a server older
    # than OpenBao 2.4.0: before openbao/openbao#1638, sys/seal-status reported
    # "shamir" for EVERY barrier -- auto-unseal included -- while still setting
    # recovery_seal for the auto-unseal case. A real Shamir barrier has no
    # recovery seal, so the pair cannot both be honest.
    if [ "$seal_type" = "shamir" ] && [ "$recovery" = "true" ]; then
        log_err "this node reports a 'shamir' barrier AND recovery_seal=true, which cannot"
        log_err "both be true -- a Shamir barrier has no recovery seal. That is what an"
        log_err "OpenBao older than 2.4.0 reports for an auto-unseal barrier"
        log_err "(openbao/openbao#1633, fixed by #1638). Trusting it would treat every"
        log_err "object as '-shamir' on both clouds and hide the mixed-seal hazard again."
        log_err "Upgrade the server; \`openbao_version\` pins 2.6.2."
        return 1
    fi
    printf '%s' "$seal_type"
}

# The seal segment an object name carries, or empty when it carries none --
# every object written before this scheme, and anything moved under a prefix.
#
# Anchored against the WHOLE name rather than split on the last "-": the
# timestamp contains dashes too, so splitting a legacy "2026-09-02T041500Z.snap"
# yields "02T041500Z", which is not a seal but is not obviously not one either.
snapshot_seal_segment() {
    printf '%s' "$1" | grep -Eq "$SNAP_NAME_RE" || return 0
    printf '%s' "$1" | sed -E 's/^.*Z-([a-z0-9]+)\.snap$/\1/'
}

# Newest object in the bucket carrying a GIVEN seal segment. Same three-state
# contract as latest_snapshot(): stdout empty = none, return 1 = the listing
# itself failed. Used only by the escape hatch below, which is why it is
# separate rather than folded into latest_snapshot() -- overloading that
# function's emptiness answer is how "the bucket holds snapshots I will not
# select" would silently become "the bucket is empty", and that answer routes
# straight into a plain init that overwrites the lineage's stored keys.
latest_snapshot_sealed() {
    local seal=$1
    local re="^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-${seal}\\.snap$"
    if [ "$CLOUD" = "gcp" ]; then
        local listing
        if ! listing=$(gcp_gcloud storage ls "gs://${SNAPSHOT_BUCKET}/"); then
            log_err "could not list gs://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        printf '%s\n' "$listing" | sed 's#.*/##' | { grep -E "$re" || true; } | sort | tail -n1
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        local out
        if ! out=$($aws_cmd s3api list-objects-v2 --bucket "$SNAPSHOT_BUCKET" --output json); then
            log_err "could not list s3://${SNAPSHOT_BUCKET} -- a listing failure, NOT an empty bucket."
            return 1
        fi
        printf '%s' "$out" | jq -r --arg re "$re" '
            (.Contents // [])
            | map(select(.Key | test($re)))
            | if length == 0 then "" else (sort_by(.LastModified) | last | .Key) end'
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
    #
    # -sS, NOT -f: `curl -f` collapses every non-2xx into exit 22, so a 404 --
    # which IS a missing mount, and the one case the caller may act on -- looked
    # identical to a TLS or network failure, which is never a reason to destroy
    # anything. The status code is captured explicitly below instead.
    local -a curl_args=(-sS)
    if [ -n "${VAULT_CACERT:-}" ]; then curl_args+=(--cacert "$VAULT_CACERT"); fi
    if [ -n "${VAULT_SKIP_VERIFY:-}" ]; then curl_args+=(-k); fi

    local pem http_code
    pem=$(curl "${curl_args[@]}" -w '\n%{http_code}' "$OPENBAO_URL/v1/pki_private_issuer/ca/pem" 2>/dev/null || true)
    http_code=$(printf '%s' "$pem" | tail -n1)
    pem=$(printf '%s' "$pem" | sed '$d')

    case "$http_code" in
        200) ;;
        404)
            log_message "ERROR" "pki_private_issuer is not mounted on this node (HTTP 404)."
            return 1 ;;
        '')
            log_message "ERROR" "Could not reach $OPENBAO_URL at all -- TLS trust or the node itself, not the PKI mount."
            return 1 ;;
        *)
            log_message "ERROR" "pki_private_issuer/ca/pem returned HTTP ${http_code}. Not a missing mount: check TLS trust and that this node is unsealed."
            return 1 ;;
    esac
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

    # One reading, not a poll: 501 here means "uninitialised", which is the
    # state this function exists to act on, and waiting for it to change would
    # wait forever. This site is why openbao_health_code exists -- it was the
    # fourth hand-written copy of the probe and the one that missed the standby
    # parameters, so `init` (and `rehydrate`, whose empty-bucket branch calls
    # straight into here) exited 1 with "Unexpected status code: 429" against a
    # perfectly healthy standby.
    status_code=$(openbao_health_code)
    if [ "$status_code" = "200" ]; then
        log_message "INFO" "OpenBao is already initialized and unsealed"
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

    # One reading, not a poll: both codes below are terminal decisions for this
    # function, and a 501 is the normal answer on the node this command exists
    # to rehydrate.
    status_code=$(openbao_health_code)
    case "$status_code" in
        200)
            # Initialised and unsealed -- but that is also exactly what a node
            # left behind by a FAILED restore looks like: throwaway keys, no
            # lineage data. Exiting 0 on the strength of a 200 alone would turn
            # a loud failure into a silent success on the next deploy, and the
            # management stack would then run against an empty store.
            if verify_pki_present; then
                log_message "INFO" "OpenBao is already initialized, unsealed, and holds the PKI -- nothing to rehydrate"
                exit 0
            fi
            # No PKI. Two very different situations look identical from here,
            # and the BUCKET is what separates them:
            #
            #   bucket has a snapshot -> this node should have restored it and
            #                            did not. Stranded: throwaway keys
            #                            nobody holds.
            #   bucket is empty       -> a young lineage part-way through its
            #                            FIRST bootstrap. `init_openbao` has
            #                            run and stored real keys, and the PKI
            #                            mount does not exist yet because the
            #                            `tofu apply` that creates it has not
            #                            succeeded yet. Perfectly recoverable:
            #                            just let this deploy continue.
            #
            # Getting this wrong in the safe-looking direction is expensive: it
            # tells an operator whose apply merely failed to destroy a cluster
            # holding freshly stored keys.
            export_snapshot_env
            # `local` on its own line, then assign: `local x=$(cmd)` masks the
            # command's exit status behind local's own. `|| _rc=$?` rather than
            # `if !`, because latest_snapshot has THREE answers and only one of
            # them is "the listing failed" -- see its contract.
            local _latest _rc=0
            _latest=$(latest_snapshot) || _rc=$?
            case "$_rc" in
                0) ;;
                2)
                    log_message "ERROR" "OpenBao has no PKI mount, and ${SNAPSHOT_BUCKET} holds objects of which none is a"
                    log_message "ERROR" "selectable snapshot -- what the bucket looks like once every snapshot has been"
                    log_message "ERROR" "moved aside under a prefix. Not an empty bucket, so this is NOT the young"
                    log_message "ERROR" "lineage case and must not be waved through. Put the object(s) back at the top"
                    log_message "ERROR" "level (container-images/openbao-snapshot/README.md) and re-run."
                    exit 1 ;;
                *)
                    log_message "ERROR" "OpenBao has no PKI mount and the lineage bucket cannot be listed, so this"
                    log_message "ERROR" "cannot be told apart from a failed restore. Fix the listing and re-run."
                    exit 1 ;;
            esac
            if [ -z "$_latest" ]; then
                log_message "WARN" "OpenBao is initialized and unsealed with no PKI mount, and ${SNAPSHOT_BUCKET} is"
                log_message "WARN" "empty -- a first bootstrap whose 'tofu apply' has not completed. Continuing;"
                log_message "WARN" "the apply after this step is what creates the PKI."
                exit 0
            fi
            log_message "ERROR" "OpenBao is initialized and unsealed but has NO PKI mount, while ${SNAPSHOT_BUCKET}"
            log_message "ERROR" "holds ${_latest}. This is the state a failed restore leaves behind: the node holds"
            log_message "ERROR" "throwaway keys that were never stored, so nothing can authenticate to it. Destroy"
            log_message "ERROR" "and redeploy the cluster stack with TM_OPENBAO_SKIP_SNAPSHOT=true -- there is"
            log_message "ERROR" "nothing on this node worth snapshotting."
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
    local latest rc=0
    latest=$(latest_snapshot) || rc=$?
    case "$rc" in
        0) ;;
        2)
            log_message "ERROR" "Refusing to initialise: ${SNAPSHOT_BUCKET} is NOT empty, but nothing in it is a"
            log_message "ERROR" "selectable snapshot -- no top-level '<UTC timestamp>-<seal>.snap' object. That is"
            log_message "ERROR" "what the bucket looks like once every snapshot has been moved aside under a"
            log_message "ERROR" "prefix. Initialising now would overwrite this lineage's stored root token and"
            log_message "ERROR" "recovery keys, so this refuses instead. Put the object(s) back at the top level"
            log_message "ERROR" "(container-images/openbao-snapshot/README.md), or point --snapshot-bucket at the"
            log_message "ERROR" "right bucket."
            exit 1 ;;
        *)
            log_message "ERROR" "Refusing to initialise: cannot prove ${SNAPSHOT_BUCKET} is empty."
            log_message "ERROR" "Initialising now would overwrite this lineage's stored root token and"
            log_message "ERROR" "recovery keys. Fix the listing (credentials, region, bucket name) and re-run."
            exit 1 ;;
    esac

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
    # openssl and curl used to be checked here. They are in check_prerequisites
    # now -- this was 75 lines AFTER the idempotency branch that calls
    # verify_pki_present, which needs both.
    if ! secret_read "$RECOVERY_KEYS_SECRET_NAME" >/dev/null 2>&1; then
        log_message "ERROR" "Cannot read ${RECOVERY_KEYS_SECRET_NAME}. The restore mints a root token from it,"
        log_message "ERROR" "so refusing before the init rather than stranding the node afterwards."
        exit 1
    fi

    # THE SEAL GATE, and it belongs exactly here: the last thing before
    # `bao operator init`, which is irreversible, and before the child's
    # `snapshot restore -force`, which replaces the whole storage backend.
    #
    # A snapshot can only be restored under the seal that encrypted it. Get
    # this wrong and the node comes back SEALED with no diagnosable error --
    # the stranded state the 200-with-no-PKI branch above exists to describe
    # after the fact. Detecting it by name, here, is what makes that branch
    # something an operator should never reach.
    local node_seal snap_seal
    if ! node_seal=$(node_seal_type); then
        exit 1
    fi
    snap_seal=$(snapshot_seal_segment "$latest")
    log_message "INFO" "This node's seal is '${node_seal}'; ${latest} carries '${snap_seal:-none}'."

    if [ "$snap_seal" != "$node_seal" ]; then
        local found
        if [ -n "$snap_seal" ]; then
            found="sealed '${snap_seal}'"
        else
            found="carrying NO seal segment -- written before seals were legible in the name"
        fi

        # THE REFUSAL IS PRINTED ONLY ON THE BRANCH THAT REFUSES. It used to be
        # printed above this test, unconditionally, so the documented failback
        # path logged "SEAL MISMATCH -- refusing to initialise or restore.
        # Nothing has changed yet." and then ran `bao operator init` and
        # `snapshot restore -force`. Any alert or CI grep on that string drew the
        # opposite conclusion from what had happened, and the message advised
        # setting OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true to an operator who had
        # just set it. Same fix as the sibling gate in
        # container-images/openbao-snapshot/openbao-snapshot.sh.
        if [ "${OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL:-false}" != "true" ]; then
            log_message "ERROR" "SEAL MISMATCH -- refusing to initialise or restore. Nothing has changed yet."
            log_message "ERROR" "  this node's seal : ${node_seal}"
            log_message "ERROR" "  newest object    : ${latest}"
            log_message "ERROR" "                     ${found}"
            log_message "ERROR" "A Raft snapshot can only be restored under the seal that encrypted it, so"
            log_message "ERROR" "restoring this one would leave the node sealed with no useful error -- the"
            log_message "ERROR" "stranded state this script warns about once it is already too late."
            log_message "ERROR" "This is the mixed-seal state a cross-cloud failover leaves behind (ADR-0033):"
            log_message "ERROR" "mirrored objects are AWS-sealed by construction, and a standby that ran with"
            log_message "ERROR" "seal_provider = \"awskms\" wrote AWS-sealed objects of its own."
            log_message "ERROR" "Pick one:"
            log_message "ERROR" "  - deploy this node under the seal the newest object carries, or"
            log_message "ERROR" "  - re-run with OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true to restore the newest"
            log_message "ERROR" "    object this node's '${node_seal}' seal CAN unwrap. That DISCARDS every"
            log_message "ERROR" "    write after it, so list the bucket and decide first."
            exit 1
        fi

        # The escape hatch. Still not a free pass: if the bucket holds nothing
        # this seal can unwrap, we must NOT fall through to init_openbao --
        # that writes fresh keys over the lineage's stored ones. Refuse instead.
        local sealed_latest
        if ! sealed_latest=$(latest_snapshot_sealed "$node_seal"); then
            log_message "ERROR" "Refusing: cannot list ${SNAPSHOT_BUCKET} to find a '${node_seal}'-sealed object."
            exit 1
        fi
        if [ -z "$sealed_latest" ]; then
            # Self-contained: this is now the first thing printed on this path.
            log_message "ERROR" "SEAL MISMATCH, and OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true cannot help --"
            log_message "ERROR" "refusing to initialise or restore. Nothing has changed yet."
            log_message "ERROR" "  this node's seal : ${node_seal}"
            log_message "ERROR" "  newest object    : ${latest}"
            log_message "ERROR" "                     ${found}"
            log_message "ERROR" "Nothing in ${SNAPSHOT_BUCKET} carries the '-${node_seal}' seal segment, so there is"
            log_message "ERROR" "no object to fall back to. NOT falling through to a plain init -- that would"
            log_message "ERROR" "overwrite this lineage's stored root token and recovery keys. Deploy this node"
            log_message "ERROR" "under the seal the objects carry, or point it at a bucket holding"
            log_message "ERROR" "'${node_seal}' snapshots."
            exit 1
        fi
        # Also self-contained, and it says PROCEEDING rather than refusing.
        log_message "WARN" "SEAL MISMATCH, and OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true -- PROCEEDING."
        log_message "WARN" "  this node's seal : ${node_seal}"
        log_message "WARN" "  newest object    : ${latest} (${found}) -- SKIPPED"
        log_message "WARN" "  restoring instead: ${sealed_latest}, the newest this node's seal can unwrap"
        log_message "WARN" "Whatever was written after ${latest} is NOT in this restore."
        latest="$sealed_latest"
    fi

    log_message "INFO" "Snapshot ${latest} found in ${SNAPSHOT_BUCKET}. Initialising with throwaway shares, then restoring."

    local scratch
    scratch=$(mktemp -d)
    # DOUBLE quotes, so $scratch is expanded NOW, when the trap is set -- not
    # when it fires. With single quotes the expansion happens at fire time, by
    # which point a SUCCESS path has already returned and the local is out of
    # scope: `set -u` then makes the trap itself fatal, so the function returns
    # 1 after doing its job correctly, AND the directory is never removed.
    # Failure paths are unaffected (the frame is still live when `exit` fires
    # the trap), so the bug is invisible to any test that exercises an error.
    # Measured on bash 3.2 and 5.3. `mktemp -d` output contains no quotes, so
    # embedding it is safe. INT/TERM exit explicitly, or bash runs the handler
    # and resumes.
    # shellcheck disable=SC2064 # expand now, deliberately -- see the comment above
    trap "rm -rf -- '$scratch'" EXIT
    # shellcheck disable=SC2064 # expand now, deliberately -- see the comment above
    trap "rm -rf -- '$scratch'; exit 130" INT TERM

    local init_output root_token
    init_output=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
    root_token=$(printf '%s' "$init_output" | jq -r '.root_token // empty')
    unset init_output
    if [ -z "$root_token" ]; then
        log_message "ERROR" "operator init returned no root token"
        exit 1
    fi

    # "unsealed", not "active": that is all check_openbao_status proves, now
    # that it accepts a standby's 200 (see the note on that function). It is
    # also all the restore below needs -- a standby forwards
    # sys/storage/raft/snapshot-force to the active node over the cluster port.
    if ! check_openbao_status; then
        log_message "ERROR" "Node did not become initialized and unsealed after init"
        exit 1
    fi

    # VAULT_TOKEN is the throwaway root token, and it is what performs the
    # restore: it is the only credential that exists on this node. The
    # LINEAGE's recovery keys are passed too, because the child needs them
    # AFTER the restore, once the snapshot's token store has replaced the
    # throwaway one.
    # OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL is passed EXPLICITLY rather than left
    # to inheritance: an operator who set it as a shell variable rather than an
    # exported one would otherwise get a parent that skipped past the foreign
    # seal and a child that refused -- after the init, which is the one place
    # this must not happen.
    if ! VAULT_TOKEN="$root_token" RECOVERY_KEYS_SECRET_ID="$RECOVERY_KEYS_SECRET_NAME" \
        ROOT_TOKEN_SECRET_ID="$ROOT_TOKEN_SECRET_NAME" \
        OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL="${OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL:-false}" \
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

    # One reading, not a poll: this runs immediately before `tofu destroy`, and
    # anything but 200 is a refusal the operator has to resolve, not something
    # to sit and wait ten minutes for.
    status_code=$(openbao_health_code)

    # A teardown removes the DNS record, and it can do so while the node is
    # still up and serving. Measured 2026-09-05, in the same minute:
    #
    #   dig +short bao.priv.aws.ogenki.io               -> (nothing)
    #   curl --resolve ...:10.0.15.250 /v1/sys/health   -> 200
    #   the instance was running and its NLB was active
    #
    # Without this fallback that reads as "not active", the destroy stops --
    # after the EKS cluster is gone and BEFORE the NAT gateway -- and the
    # documented escape (TM_OPENBAO_SKIP_SNAPSHOT=true) throws away a snapshot
    # that was there for the taking. On a teardown where this is the newest copy
    # of the lineage, that is the data loss this function exists to prevent.
    #
    # CURL_HOME rather than --resolve: openbao-snapshot.sh runs the actual
    # snapshot through its own curl calls, and that file is a symlink into the
    # published container image, so it must not grow a flag for an operator-only
    # path. curl reads $CURL_HOME/.curlrc before $HOME's, and a `resolve` entry
    # there applies to every curl in this process tree -- the child included.
    # TLS is unaffected: the request still presents the hostname, which is
    # required, because the certificate carries no IP SAN by design.
    if [ "$status_code" != "200" ] && [ -n "$FALLBACK_ADDRESS" ]; then
        local host_port host port
        host_port=${OPENBAO_URL#*://}
        host_port=${host_port%%/*}
        host=${host_port%%:*}
        port=${host_port##*:}
        [ "$port" = "$host_port" ] && port=8200

        log_message "WARN" "$OPENBAO_URL did not answer (HTTP ${status_code:-none}); retrying at the fixed address $FALLBACK_ADDRESS."

        CURL_HOME=$(mktemp -d)
        export CURL_HOME
        # shellcheck disable=SC2064 # expand now, so the trap survives CURL_HOME changing
        trap "rm -rf -- '$CURL_HOME'" EXIT
        printf 'resolve = %s:%s:%s\n' "$host" "$port" "$FALLBACK_ADDRESS" > "$CURL_HOME/.curlrc"

        status_code=$(openbao_health_code)
        if [ "$status_code" = "200" ]; then
            log_message "INFO" "Reached OpenBao at $FALLBACK_ADDRESS presenting $host: the name is gone, the node is not."
        fi
    fi

    if [ "$status_code" != "200" ]; then
        log_message "ERROR" "OpenBao at $OPENBAO_URL did not answer (HTTP ${status_code:-none}); refusing to destroy without a snapshot."
        if [ -n "$FALLBACK_ADDRESS" ]; then
            log_message "ERROR" "The fixed address $FALLBACK_ADDRESS did not answer either, so the node is genuinely unreachable."
        else
            log_message "ERROR" "No --fallback-address was given, so this cannot tell an unresolvable NAME from a dead NODE."
            log_message "ERROR" "Check the instance and its load balancer before concluding the node is gone."
        fi
        log_message "ERROR" "Only if the node is genuinely gone, re-run with TM_OPENBAO_SKIP_SNAPSHOT=true -- that DISCARDS"
        log_message "ERROR" "every write since the last scheduled snapshot."
        exit 1
    fi

    # `export_snapshot_env` FIRST, then read the token. Order matters: that
    # function must not be able to touch this scope's `root_token`, and while
    # it now declares its own local (`adc_token`), doing the read afterwards
    # means a future edit to it cannot reintroduce the clobber. (It did clobber
    # it: bash is dynamically scoped, so its non-local `token` assignment plus
    # `unset token` destroyed this one -- back when both were named `token` --
    # and the child was handed an empty VAULT_TOKEN -- so a GCP destroy could
    # never take its final snapshot.)
    export_snapshot_env

    local root_token
    if ! root_token=$(secret_read "$ROOT_TOKEN_SECRET_NAME" | jq -r '.token // empty') || [ -z "$root_token" ]; then
        log_message "ERROR" "Could not read the root token from $ROOT_TOKEN_SECRET_NAME"
        exit 1
    fi

    local scratch
    scratch=$(mktemp -d)
    # Double-quoted for the same reason as in rehydrate_openbao: expanded at
    # set time, or a SUCCESSFUL snapshot returns 1 from the trap and leaves the
    # directory behind. That failure is worse here than it looks -- the destroy
    # workflow reads the non-zero status as 'snapshot failed' and blocks, and
    # the operator's documented escape is TM_OPENBAO_SKIP_SNAPSHOT=true, i.e.
    # destroying WITHOUT a snapshot: the exact loss this function exists to
    # prevent.
    #
    # Both directories, because the fallback probe above may have set CURL_HOME
    # to a temp dir and registered its own EXIT trap -- a second `trap ... EXIT`
    # REPLACES the first, so naming only $scratch here would leak that dir, and
    # with it a .curlrc that silently redirects every later curl in this process
    # tree. "${CURL_HOME:-}" is empty when no fallback ran, and `rm -rf --` on an
    # empty argument is a no-op.
    # shellcheck disable=SC2064 # expand now, deliberately -- see the comment above
    trap "rm -rf -- '$scratch' '${CURL_HOME:-}'" EXIT
    # shellcheck disable=SC2064 # expand now, deliberately -- see the comment above
    trap "rm -rf -- '$scratch' '${CURL_HOME:-}'; exit 130" INT TERM

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
#   - AWS: the ca-chain secret (certificates/priv.aws.ogenki.io/ca-chain) is
#     JSON with a `.ca` field only (certificates, no key), written by the
#     offline signing ceremony in pki-and-secrets.md. The root-CA secret this
#     branch used to read (certificates/priv.aws.ogenki.io/root-ca, JSON with
#     `.ca` and `.bundle`) is deleted -- the root key was never meant to reach
#     a networked secret store.
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
