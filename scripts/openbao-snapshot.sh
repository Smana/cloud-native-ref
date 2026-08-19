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

    bao operator generate-root -init --format json | jq -cr '.nonce, .otp' > tmpfile
    read -r VAULT_NONCE VAULT_OTP < tmpfile
    rm tmpfile
    VAULT_ENCODED_TOKEN=$(echo "${RECOVERY_SECRET}" | jq -r '.recovery_key' | bao operator generate-root -nonce="${VAULT_NONCE}" --format json - | jq -cr '.encoded_root_token')
    VAULT_TOKEN=$(bao operator generate-root -decode "${VAULT_ENCODED_TOKEN}" -otp "${VAULT_OTP}")
    unset RECOVERY_SECRET
    echo "${VAULT_TOKEN}"
}

# One AppRole login per run. `discover_leader` used to authenticate, then unset
# the token, and `save` logged in again immediately afterwards - two logins and
# two token leases for one snapshot. An OpenBao token is valid against any node
# in the cluster, so it survives the VAULT_ADDR switch to the leader.
authenticate() {
    echo "${info}: Authenticating with OpenBao..."
    VAULT_TOKEN=$(bao write -field=token auth/approle/login role_id="${APPROLE_ROLE_ID}" secret_id="${APPROLE_SECRET_ID}")
    if [ -z "${VAULT_TOKEN}" ]; then
        echo "${err}: Authentication failed. Unable to retrieve OpenBao token."
        exit 1
    fi
    export VAULT_TOKEN
}

discover_leader() {
    echo "${info}: Discovering the leader node..."
    LEADER_ADDRESS=$(bao read -format=json sys/storage/raft/configuration | jq -r '.data.config.servers[] | select(.leader == true) | .address' | sed 's/:8201/:8200/')

    if [ -z "${LEADER_ADDRESS}" ]; then
        echo "${err}: Unable to discover the leader node."
        echo "${err}: sys/storage/raft/* exists only with raft storage. In dev mode the"
        echo "${err}: cluster runs the file backend and this command cannot work at all."
        exit 1
    fi
    echo "${info}: Leader node discovered at ${LEADER_ADDRESS}"
    # Exported explicitly: in the CronJob VAULT_ADDR arrives via envFrom and is
    # already in the environment, so a plain assignment happened to stay
    # exported. Run outside the pod with only -a, it would not have been.
    VAULT_ADDR="https://${LEADER_ADDRESS}"
    export VAULT_ADDR
}

save() {
    echo "${info}: Starting OpenBao backup to S3..."
    check_required_bin
    authenticate
    discover_leader
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
    discover_leader

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

    # Root token only from here on, and revoked on the way out whatever happens.
    VAULT_TOKEN=$(generate_root_token)
    export VAULT_TOKEN
    trap 'bao token revoke "${VAULT_TOKEN}" >/dev/null 2>&1 || true' EXIT

    bao operator raft snapshot restore -force /tmp/bao.snap

    echo "${info}: Check that the timestamp from the path secret/check_timestamp is less than ${NUM_DAYS} days"
    CURR_TS=$(date "+%s")
    VAULT_TS=$(bao kv get --field=value secret/check_timestamp)

    if [ $((CURR_TS - VAULT_TS)) -gt $((NUM_DAYS * 86400)) ]; then
        echo "${err}: The restored snapshot is more than ${NUM_DAYS} days old."
        exit 1
    fi

    bao kv put secret/check_timestamp "value=$(date "+%s")" >/dev/null 2>&1
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
