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
generate_root_token() {
    bao operator generate-root -init --format json | jq -cr '.nonce, .otp' > tmpfile
    read -r VAULT_NONCE VAULT_OTP < tmpfile
    rm tmpfile
    VAULT_ENCODED_TOKEN=$(aws secretsmanager get-secret-value --secret-id bao-staging-hungry-hamster | jq -r '.SecretString' | jq -r '.recovery_key' | bao operator generate-root -nonce="${VAULT_NONCE}" --format json - | jq -cr '.encoded_root_token')
    VAULT_TOKEN=$(bao operator generate-root -decode "${VAULT_ENCODED_TOKEN}" -otp "${VAULT_OTP}")
    echo "${VAULT_TOKEN}"
}

discover_leader() {
    echo "${info}: Authenticating with OpenBao..."
    VAULT_TOKEN=$(bao write -field=token auth/approle/login role_id="${APPROLE_ROLE_ID}" secret_id="${APPROLE_SECRET_ID}")
    if [ -z "${VAULT_TOKEN}" ]; then
        echo "${err}: Authentication failed. Unable to retrieve OpenBao token."
        exit 1
    fi

    echo "${info}: Discovering the leader node..."
    export VAULT_TOKEN
    LEADER_ADDRESS=$(bao read -format=json sys/storage/raft/configuration | jq -r '.data.config.servers[] | select(.leader == true) | .address' | sed 's/:8201/:8200/')
    unset VAULT_TOKEN

    if [ -z "${LEADER_ADDRESS}" ]; then
        echo "${err}: Unable to discover the leader node."
        exit 1
    fi
    echo "${info}: Leader node discovered at ${LEADER_ADDRESS}"
    VAULT_ADDR="https://${LEADER_ADDRESS}"
}

save() {
    echo "${info}: Starting OpenBao backup to S3..."
    check_required_bin
    discover_leader
    bao login -no-print "$(bao write -field=token auth/approle/login role_id="${APPROLE_ROLE_ID}" secret_id="${APPROLE_SECRET_ID}")"
    bao operator raft snapshot save "${SNAPSHOT_FILE}"
    aws s3 cp "${SNAPSHOT_FILE}" "s3://${BUCKET_NAME}/$(date +"%Y-%m-%d_%H:%M:%S_%Z").snap"
}

restore() {
    echo "${info}: Restoring OpenBao from S3..."
    check_required_bin
    discover_leader
    VAULT_TOKEN=$(generate_root_token)
    echo "${info}: Fetching latest backup from S3 bucket ${BUCKET_NAME}"
    SNAP=$(aws s3 ls "${BUCKET_NAME}" | sort | tail -n 1 | awk '{print $4}')
    aws s3 cp "s3://${BUCKET_NAME}/${SNAP}" /tmp/bao.snap
    echo "${info}: Restoring snapshot ${SNAP}"
    bao operator raft snapshot restore -force /tmp/bao.snap

    trap 'bao token revoke "${VAULT_TOKEN}"' EXIT

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
