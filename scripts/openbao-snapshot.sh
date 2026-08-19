#!/bin/sh
set -e

# Removed color variables
err="ERROR"
info="INFO"
# warn is used in error messages
export warn="WARNING"

# Replacing array with individual checks
check_required_bin() {
    for BIN in bao jq aws; do
        if ! type "${BIN}" >/dev/null 2>&1; then
            echo "${err}: ${BIN} binary not found"
            exit 1
        fi
    done
}

export AWS_PAGER=""

SCRIPT_NAME=$(basename "${0}")
DEFAULT_DAYS=8 # Default number of days for snapshot validation

# Where the restore freshness marker lives. The kv-v2 mount is in the `app`
# tenant namespace — platform services live in root, tenants get namespaces.
CHECK_NAMESPACE="${CHECK_NAMESPACE:-app}"
CHECK_PATH="${CHECK_PATH:-secret/check_timestamp}"

# Writable volume
export HOME=/snapshot

usage() {
    cat << EOF
Backup or restore a OpenBao instance from an S3 bucket

Usage: ./${SCRIPT_NAME} [save|restore] -s <snapshot_file> -b <bucket_name> -a <VAULT_ADDR> [-d <days>]
      -h | --help               : Show this message
      -s | --snapshot           : OpenBao snapshot file location
      -b | --bucket             : AWS S3 bucket name
      -a | --addr               : OpenBao address in the form "https://<address>:<port>"
      -d | --days               : Number of days for snapshot validation (default: ${DEFAULT_DAYS} days)

      ex:
      # Run a snapshot (backup)
      ./${SCRIPT_NAME} save -u https://bao.domain.tld:8200 -s /path/backup.snap -b mybucketname

      # Restore from a snapshot
      ./${SCRIPT_NAME} restore -u https://bao.domain.tld:8200 -s /path/backup.snap -b mybucketname -d 10
EOF
}

# Options parsing
COMMAND=$1
NUM_DAYS=${DEFAULT_DAYS}
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0;;
    -s | --snapshot) SNAPSHOT_FILE=$2; shift 2;;
    -b | --bucket) BUCKET_NAME=$2; shift 2;;
    -a | --addr) VAULT_ADDR=$2; shift 2;;
    -d | --days) NUM_DAYS=$2; shift 2;;
    *)
        echo "${err} : Unknown option"
        usage
        exit 3
    ;;
  esac
done

# Validate required parameters
if [ -z "${VAULT_ADDR}" ]; then
    echo "${err}: The OpenBao address must be provided (--addr)!"
    usage
    exit 1
fi
if [ -z "${SNAPSHOT_FILE}" ]; then
    echo "${err}: The OpenBao snapshot file must be given (--snapshot)!"
    usage
    exit 1
fi
if [ -z "${BUCKET_NAME}" ]; then
    echo "${err}: The S3 bucket name must be provided (--bucket)!"
    usage
    exit 1
fi
if ! echo "${NUM_DAYS}" | grep -E '^[0-9]+$' > /dev/null; then
    echo "${err}: Number of days must be a positive integer (--days)!"
    usage
    exit 1
fi

# Check required environment variables
if [ -z "${APPROLE_ROLE_ID}" ] || [ -z "${APPROLE_SECRET_ID}" ]; then
    echo "${err}: The environment variables APPROLE_ROLE_ID and APPROLE_SECRET_ID must be set"
    exit 1
fi

# Check if required binaries are installed
# Only used by `restore`, which is an operator action run with operator
# credentials - not something the CronJob can do. The job's EKS Pod Identity
# role has no secretsmanager access on purpose: a daily backup pod able to read
# the material that regenerates a root token is a privilege escalation.
#
# The secret is written by `openbao-config.sh init` as
# {"recovery_keys": [...], "recovery_key": "<first>", "threshold": N}.
# This handles threshold 1; a higher threshold needs one -nonce round per share.
generate_root_token() {
    if [ -z "${RECOVERY_KEYS_SECRET_ID:-}" ]; then
        echo "${err}: RECOVERY_KEYS_SECRET_ID must be set to run a restore."
        echo "${err}: It is the AWS Secrets Manager entry holding the OpenBao recovery keys."
        exit 1
    fi

    RECOVERY_SECRET=$(aws secretsmanager get-secret-value --secret-id "${RECOVERY_KEYS_SECRET_ID}" | jq -r '.SecretString')

    RECOVERY_THRESHOLD=$(echo "${RECOVERY_SECRET}" | jq -r '.threshold // 1')
    if [ "${RECOVERY_THRESHOLD}" -gt 1 ]; then
        echo "${err}: recovery threshold is ${RECOVERY_THRESHOLD}; this script only automates a threshold of 1."
        echo "${err}: Run 'bao operator generate-root' by hand, supplying ${RECOVERY_THRESHOLD} shares."
        exit 1
    fi

    # Under $HOME (a writable volume), not the CWD. The container runs with
    # readOnlyRootFilesystem and CWD is `/`, so a relative `> tmpfile` fails with
    # "Read-only file system" and, under `set -e`, aborts the restore.
    nonce_file="$HOME/.generate-root.$$"
    bao operator generate-root -init --format json | jq -cr '.nonce, .otp' > "$nonce_file"
    read -r VAULT_NONCE VAULT_OTP < "$nonce_file"
    rm -f "$nonce_file"
    VAULT_ENCODED_TOKEN=$(echo "${RECOVERY_SECRET}" | jq -r '.recovery_key' | bao operator generate-root -nonce="${VAULT_NONCE}" --format json - | jq -cr '.encoded_root_token')
    VAULT_TOKEN=$(bao operator generate-root -decode "${VAULT_ENCODED_TOKEN}" -otp "${VAULT_OTP}")
    unset RECOVERY_SECRET
    echo "${VAULT_TOKEN}"
}

# One AppRole login per run. Leader discovery used to authenticate, unset the
# token, and then `save` logged in again immediately afterwards - two logins and
# two token leases for one snapshot.
authenticate() {
    echo "${info}: Authenticating with OpenBao..."
    VAULT_TOKEN=$(bao write -field=token auth/approle/login role_id="${APPROLE_ROLE_ID}" secret_id="${APPROLE_SECRET_ID}")
    if [ -z "${VAULT_TOKEN}" ]; then
        echo "${err}: Authentication failed. Unable to retrieve OpenBao token."
        exit 1
    fi
    export VAULT_TOKEN
}

# No leader discovery. This used to read sys/storage/raft/configuration, pick
# the server with leader == true, and reconnect straight to its private IP —
# which bypassed the NLB entirely, needed a security-group rule opening 8200
# from the whole pod CIDR to the instances, and could not verify TLS, because
# the server certificate carries a DNS SAN and no IP SANs.
#
# Going through the NLB instead relies on standby nodes forwarding the request:
# OpenBao standbys RPC the active node over the cluster port and only fall back
# to a 307 redirect when X-Vault-No-Request-Forwarding is set, which nothing
# here sets. Only the active node can generate a snapshot, so the forward is
# what makes an address that may land on any node work.
#
# Caveat, because this is the historically fragile path: Vault's equivalent has
# an open bug (hashicorp/vault#15258) where a snapshot taken through a
# *redirect* fails with "incomplete snapshot, unable to read SHA256SUMS.sealed
# file". If snapshots start failing that way in `ha` mode, the fix is a second
# target group whose health check omits standbyok so it contains only the active
# node — but note it must NOT be attached to the ASG, because Auto Scaling
# replaces an instance reported unhealthy by *any* attached target group, which
# would terminate every standby.
export VAULT_ADDR

save() {
    echo "${info}: Starting OpenBao backup to S3..."
    check_required_bin
    authenticate
    echo "${info}: Requesting a snapshot via ${VAULT_ADDR}"
    bao operator raft snapshot save "${SNAPSHOT_FILE}"
    # UTC, colon-free, lexicographically sortable. The previous
    # "%Y-%m-%d_%H:%M:%S_%Z" embedded colons (legal in S3, awkward everywhere
    # downstream) and a local timezone abbreviation, so key order broke across a
    # DST change.
    aws s3 cp "${SNAPSHOT_FILE}" "s3://${BUCKET_NAME}/$(date -u +"%Y-%m-%dT%H%M%SZ").snap"
}

restore() {
    echo "${info}: Restoring OpenBao from S3..."
    check_required_bin
    authenticate

    echo "${info}: Fetching latest backup from S3 bucket ${BUCKET_NAME}"
    # Sorted by LastModified, not by key name. Key-name ordering would be
    # actively dangerous during the changeover from the old
    # "%Y-%m-%d_%H:%M:%S_%Z" format: '_' sorts after 'T', so every old-format
    # object ranks above every new one and `tail -n1` would keep selecting a
    # stale snapshot until the 120-day lifecycle rule aged them out.
    SNAP=$(aws s3api list-objects-v2 --bucket "${BUCKET_NAME}" \
        --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
    if [ -z "${SNAP}" ] || [ "${SNAP}" = "None" ]; then
        echo "${err}: No snapshots found in ${BUCKET_NAME}."
        exit 1
    fi

    aws s3 cp "s3://${BUCKET_NAME}/${SNAP}" /tmp/bao.snap
    echo "${info}: Restoring snapshot ${SNAP}"

    VAULT_TOKEN=$(generate_root_token)
    export VAULT_TOKEN

    bao operator raft snapshot restore -force /tmp/bao.snap

    # A raft restore replaces the entire storage backend, token store included,
    # so the token minted above no longer exists. Everything after this point —
    # including the revoke in the exit trap — needs a token generated against
    # the *restored* cluster.
    VAULT_TOKEN=$(generate_root_token)
    export VAULT_TOKEN
    trap 'bao token revoke "${VAULT_TOKEN}" >/dev/null 2>&1 || true' EXIT

    # The kv-v2 mount lives in the `app` tenant namespace, not root — platform
    # services are in root and tenants get namespaces. Without -namespace this
    # 404s.
    echo "${info}: Check that ${CHECK_NAMESPACE}/${CHECK_PATH} is less than ${NUM_DAYS} days old"
    CURR_TS=$(date "+%s")
    VAULT_TS=$(bao kv get -namespace="${CHECK_NAMESPACE}" --field=value "${CHECK_PATH}")

    if [ -z "${VAULT_TS}" ]; then
        echo "${err}: ${CHECK_PATH} is absent from the restored snapshot; cannot judge its age."
        exit 1
    fi

    if [ $((CURR_TS - VAULT_TS)) -gt $((NUM_DAYS * 86400)) ]; then
        echo "${err}: The restored snapshot is more than ${NUM_DAYS} days old."
        exit 1
    fi

    bao kv put -namespace="${CHECK_NAMESPACE}" "${CHECK_PATH}" "value=$(date "+%s")" >/dev/null 2>&1
}

# Command execution
case "${COMMAND}" in
save) save;;
restore) restore;;
*)
    echo "${err}: Unknown command '${COMMAND}'. Use 'save' or 'restore'."
    usage
    exit 2
;;
esac
