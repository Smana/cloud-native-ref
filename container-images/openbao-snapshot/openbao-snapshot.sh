#!/bin/sh
set -e

# Removed color variables
err="ERROR"
info="INFO"
# warn is used in error messages
export warn="WARNING"

# Replacing array with individual checks
check_required_bin() {
    for BIN in bao jq; do
        if ! type "${BIN}" >/dev/null 2>&1; then
            echo "${err}: ${BIN} binary not found"
            exit 1
        fi
    done

    if [ "${CLOUD}" = "gcp" ]; then
        CLOUD_BIN=gcloud
    else
        CLOUD_BIN=aws
    fi
    if ! type "${CLOUD_BIN}" >/dev/null 2>&1; then
        echo "${err}: ${CLOUD_BIN} binary not found"
        exit 1
    fi
}

export AWS_PAGER=""

SCRIPT_NAME=$(basename "${0}")
DEFAULT_DAYS=8 # Default number of days for snapshot validation

# Where the freshness marker lives: the root-namespace `lineage/` kv-v2 mount
# both management stacks create. It used to be `app/secret/check_timestamp`, but
# GCP has no `app` namespace, so the restore path 404'd there, and a tenant
# namespace is the wrong home for a platform marker anyway. CHECK_NAMESPACE is
# kept for operators with an older snapshot; empty means root.
CHECK_NAMESPACE="${CHECK_NAMESPACE:-}"
CHECK_PATH="${CHECK_PATH:-lineage/check_timestamp}"

# `bao kv ... -namespace=""` is not the same as omitting the flag, so build it.
kv_ns_flag() {
    if [ -n "${CHECK_NAMESPACE}" ]; then
        printf -- '-namespace=%s' "${CHECK_NAMESPACE}"
    fi
}

# Writable scratch dir. The CronJob mounts an emptyDir at /snapshot; an operator
# shell has no such directory, and the previous unconditional export made every
# write under $HOME (the generate-root nonce file, gcloud's config) abort a
# restore under `set -e`. Use it when it is there, otherwise leave HOME alone.
if [ -d /snapshot ] && [ -w /snapshot ]; then
    export HOME=/snapshot
fi

# Which cloud's CLIs to use. Set by the CronJob; defaults to aws so an operator
# running this by hand against aws-0 needs no new environment.
CLOUD="${CLOUD:-aws}"
case "${CLOUD}" in
    aws|gcp) ;;
    *) echo "${err}: CLOUD must be 'aws' or 'gcp', got '${CLOUD}'." ; exit 1 ;;
esac

usage() {
    cat << EOF
Backup or restore a OpenBao instance from a bucket in object storage

Usage: ./${SCRIPT_NAME} [save|restore] -s <snapshot_file> -b <bucket_name> -a <VAULT_ADDR> [-d <days>] [-f fail|warn]
      -h | --help               : Show this message
      -s | --snapshot           : OpenBao snapshot file location
      -b | --bucket             : Bucket name
      -a | --addr               : OpenBao address in the form "https://<address>:<port>"
      -d | --days               : Number of days for snapshot validation (default: ${DEFAULT_DAYS} days)
      -f | --freshness          : What to do when the restored marker is older than --days,
                                  OR absent altogether: "fail" (default) exits non-zero,
                                  "warn" logs and continues. This is an ALARM, not a gate --
                                  the marker can only be read after the restore has already
                                  been applied, so it tells you (and any calling automation,
                                  via the exit code) that what you installed is stale. Use
                                  "warn" when restoring into an EMPTY node (a rehydrate),
                                  where a stale restore is still better than none, and where
                                  a lineage's first snapshot may legitimately carry no marker.

      Environment:
      VAULT_TOKEN               : an existing token. Takes precedence over everything below.
      OPENBAO_JWT_MOUNT         : e.g. jwt/aws-0    ) all three together select JWT login,
      OPENBAO_JWT_ROLE          : e.g. openbao-snapshot ) which is how the CronJob
      OPENBAO_JWT_PATH          : path to a projected SA token ) authenticates.
      APPROLE_ROLE_ID           : ) legacy AppRole login, still accepted
      APPROLE_SECRET_ID         : )
      RECOVERY_KEYS_SECRET_ID   : required by 'restore' -- names the secret-store entry
                                  holding the recovery keys a root token is minted from.
      CLOUD                     : aws (default) | gcp -- selects which CLI moves the object.
      VAULT_CACERT              : CA chain to verify the server. Set it; do not skip verify.
      CHECK_NAMESPACE           : override the marker's namespace (default: root).
      CHECK_PATH                : override the marker path (default: lineage/check_timestamp).

      ex:
      # Run a snapshot (backup)
      ./${SCRIPT_NAME} save -a https://bao.domain.tld:8200 -s /path/backup.snap -b mybucketname

      # Restore from a snapshot
      ./${SCRIPT_NAME} restore -a https://bao.domain.tld:8200 -s /path/backup.snap -b mybucketname -d 10
EOF
}

# Options parsing
COMMAND=$1
NUM_DAYS=${DEFAULT_DAYS}
FRESHNESS=fail
shift
while [ $# -gt 0 ]; do
  case "$1" in
    -h | --help) usage; exit 0;;
    -s | --snapshot) SNAPSHOT_FILE=$2; shift 2;;
    -b | --bucket) BUCKET_NAME=$2; shift 2;;
    -a | --addr) VAULT_ADDR=$2; shift 2;;
    -d | --days) NUM_DAYS=$2; shift 2;;
    -f | --freshness) FRESHNESS=$2; shift 2;;
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
    echo "${err}: The bucket name must be provided (--bucket)!"
    usage
    exit 1
fi
if ! echo "${NUM_DAYS}" | grep -E '^[0-9]+$' > /dev/null; then
    echo "${err}: Number of days must be a positive integer (--days)!"
    usage
    exit 1
fi

case "${FRESHNESS}" in
    fail|warn) ;;
    *) echo "${err}: --freshness must be 'fail' or 'warn', got '${FRESHNESS}'."; usage; exit 1;;
esac

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
        echo "${err}: It names the secret holding the OpenBao recovery keys --"
        echo "${err}: an AWS Secrets Manager entry, or a GCP Secret Manager secret."
        exit 1
    fi

    if [ "${CLOUD}" = "gcp" ]; then
        RECOVERY_SECRET=$(gcloud secrets versions access latest --secret="${RECOVERY_KEYS_SECRET_ID}")
    else
        RECOVERY_SECRET=$(aws secretsmanager get-secret-value --secret-id "${RECOVERY_KEYS_SECRET_ID}" | jq -r '.SecretString')
    fi

    RECOVERY_THRESHOLD=$(echo "${RECOVERY_SECRET}" | jq -r '.threshold // 1')
    if [ "${RECOVERY_THRESHOLD}" -gt 1 ]; then
        echo "${err}: recovery threshold is ${RECOVERY_THRESHOLD}; this script only automates a threshold of 1."
        echo "${err}: Run 'bao operator generate-root' by hand, supplying ${RECOVERY_THRESHOLD} shares."
        exit 1
    fi

    # Under $HOME (a writable volume), not the CWD. The container runs with
    # readOnlyRootFilesystem and CWD is `/`, so a relative `> tmpfile` fails with
    # "Read-only file system" and, under `set -e`, aborts the restore.
    # 0077 before creating it: with HOME now being the operator's real home on
    # a non-container run, this file (the generate-root nonce and OTP) would
    # otherwise be created with the ambient umask.
    nonce_file="$HOME/.generate-root.$$"
    ( umask 077; : > "$nonce_file" )
    bao operator generate-root -init --format json | jq -cr '.nonce, .otp' > "$nonce_file"
    read -r VAULT_NONCE VAULT_OTP < "$nonce_file"
    rm -f "$nonce_file"
    VAULT_ENCODED_TOKEN=$(echo "${RECOVERY_SECRET}" | jq -r '.recovery_key' | bao operator generate-root -nonce="${VAULT_NONCE}" --format json - | jq -cr '.encoded_root_token')
    VAULT_TOKEN=$(bao operator generate-root -decode "${VAULT_ENCODED_TOKEN}" -otp "${VAULT_OTP}")
    unset RECOVERY_SECRET
    echo "${VAULT_TOKEN}"
}

# Three ways in, tried in order. VAULT_TOKEN wins so an operator (or the
# rehydrate step, which holds a fresh root token) can drive save/restore
# directly; the JWT path is what the CronJob uses; AppRole is kept for a
# snapshot taken by hand against a lineage that predates the JWT mounts.
authenticate() {
    if [ -n "${VAULT_TOKEN:-}" ]; then
        echo "${info}: Using the token supplied in VAULT_TOKEN."
        export VAULT_TOKEN
        # Recorded so restore() knows not to replace it with a token minted from
        # recovery keys that may not belong to the node in front of us.
        SUPPLIED_VAULT_TOKEN=1
        return 0
    fi

    if [ -n "${OPENBAO_JWT_PATH:-}" ]; then
        if [ -z "${OPENBAO_JWT_MOUNT:-}" ] || [ -z "${OPENBAO_JWT_ROLE:-}" ]; then
            echo "${err}: OPENBAO_JWT_PATH is set; OPENBAO_JWT_MOUNT (e.g. jwt/aws-0) and OPENBAO_JWT_ROLE are required with it."
            exit 1
        fi
        echo "${info}: Authenticating with OpenBao via auth/${OPENBAO_JWT_MOUNT} as role ${OPENBAO_JWT_ROLE}..."
        # `jwt=@file` makes bao read the projected ServiceAccount token from disk,
        # so the token never appears on a command line.
        VAULT_TOKEN=$(bao write -field=token "auth/${OPENBAO_JWT_MOUNT}/login" \
            role="${OPENBAO_JWT_ROLE}" jwt=@"${OPENBAO_JWT_PATH}")
    elif [ -n "${APPROLE_ROLE_ID:-}" ] && [ -n "${APPROLE_SECRET_ID:-}" ]; then
        echo "${info}: Authenticating with OpenBao via AppRole..."
        # secret_id on STDIN, not argv: argv is readable through
        # /proc/<pid>/cmdline and `ps` by anything in the same PID namespace.
        # `printf` is a shell builtin, so this spawns no extra process. Same
        # reasoning as the root-token fix in openbao-config.sh's init.
        VAULT_TOKEN=$(printf '%s' "${APPROLE_SECRET_ID}" \
            | bao write -field=token auth/approle/login \
                role_id="${APPROLE_ROLE_ID}" secret_id=-)
    elif bao token lookup >/dev/null 2>&1; then
        # An operator who ran `bao login -method=userpass username=admin` -- the
        # flow CLAUDE.md documents -- has a token in ~/.vault-token and no
        # VAULT_TOKEN set. `bao` honours its own token helper, so a lookup
        # succeeding means every later call in this script will authenticate.
        # Without this branch a correctly-logged-in operator was told "no
        # credentials", which is a dead end during an incident.
        echo "${info}: Using the existing token from bao's token helper."
        return 0
    else
        echo "${err}: No OpenBao credentials. Set one of:"
        echo "${err}:   VAULT_TOKEN"
        echo "${err}:   OPENBAO_JWT_PATH + OPENBAO_JWT_MOUNT + OPENBAO_JWT_ROLE"
        echo "${err}:   APPROLE_ROLE_ID + APPROLE_SECRET_ID"
        echo "${err}: ...or run 'bao login' first. For a RESTORE on a node with no"
        echo "${err}: working auth method yet, none of these is needed: set"
        echo "${err}: RECOVERY_KEYS_SECRET_ID and a root token is minted from the"
        echo "${err}: recovery keys instead."
        # `return 1`, NOT `exit 1`: restore() treats a missing credential as
        # advisory (see below) and cannot do that if this function kills the
        # shell. save() turns it back into a hard failure at its call site.
        return 1
    fi

    if [ -z "${VAULT_TOKEN}" ]; then
        echo "${err}: Authentication failed. Unable to retrieve OpenBao token."
        return 1
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
    echo "${info}: Starting OpenBao backup to object storage..."
    check_required_bin
    # A backup with no credential is not a backup. authenticate() returns
    # rather than exits, so the exit is chosen here -- restore() makes the
    # opposite choice deliberately.
    authenticate || exit 1
    # The marker records WHEN THE SNAPSHOT WAS TAKEN, so a later restore can
    # judge the age of what it just installed -- and, because it is read back
    # from inside the restored OpenBao, prove the restore actually applied.
    # It used to be written only on restore, which meant a lineage's first
    # snapshot carried no marker at all and the first rehydrate could not
    # judge anything.
    #
    # NON-FATAL, and that is the important part. Under `set -e` a failing
    # `bao kv put` here would abort save() BEFORE the snapshot below, so a
    # bookkeeping write would produce no backup at all. It will fail in
    # practice: the `lineage/` mount and the policy grant for it are created by
    # the OpenTofu management stack (Task 5) while this CronJob is applied by
    # Flux (Task 7), and nothing orders those two control planes against each
    # other. On a platform whose newest snapshot is the store of record, a
    # missing backup is far worse than a missing marker -- and the restore path
    # already has a branch for a snapshot that carries none.
    echo "${info}: Stamping ${CHECK_PATH} before the snapshot"
    # shellcheck disable=SC2046 # kv_ns_flag prints zero or one word by design
    if ! bao kv put $(kv_ns_flag) "${CHECK_PATH}" "value=$(date -u +%s)" >/dev/null; then
        echo "${warn}: could not write ${CHECK_PATH} -- the mount is missing, or this"
        echo "${warn}: role lacks create/update on it. Taking the snapshot anyway; it"
        echo "${warn}: will carry no freshness marker, so restoring it needs"
        echo "${warn}: --freshness warn."
    fi
    echo "${info}: Requesting a snapshot via ${VAULT_ADDR}"
    bao operator raft snapshot save "${SNAPSHOT_FILE}"
    # UTC, colon-free, lexicographically sortable. The previous
    # "%Y-%m-%d_%H:%M:%S_%Z" embedded colons (legal in S3, awkward everywhere
    # downstream) and a local timezone abbreviation, so key order broke across a
    # DST change.
    if [ "${CLOUD}" = "gcp" ]; then
        gcloud storage cp "${SNAPSHOT_FILE}" "gs://${BUCKET_NAME}/$(date -u +"%Y-%m-%dT%H%M%SZ").snap"
    else
        aws s3 cp "${SNAPSHOT_FILE}" "s3://${BUCKET_NAME}/$(date -u +"%Y-%m-%dT%H%M%SZ").snap"
    fi
}

restore() {
    echo "${info}: Restoring OpenBao from object storage..."
    check_required_bin
    # Advisory, not required. Nothing between here and the restore uses this
    # token: generate_root_token below mints one from the recovery keys, needs
    # no authentication, and overwrites VAULT_TOKEN. Demanding a credential
    # here would refuse the case this command exists for -- a node that is
    # initialised but has no usable auth method yet.
    if ! authenticate; then
        echo "${warn}: no ordinary credential available; continuing, because a"
        echo "${warn}: restore authenticates with the recovery keys instead."
    fi

    echo "${info}: Fetching latest backup from bucket ${BUCKET_NAME}"
    if [ "${CLOUD}" = "gcp" ]; then
        # Lexicographic is chronological here, and only here. The AWS bucket
        # still holds objects in the old "%Y-%m-%d_%H:%M:%S_%Z" format, where
        # '_' sorts after 'T' so every legacy key ranks above every new one --
        # hence the LastModified sort below. The GCP bucket was created after
        # the format change and has only ever held the sortable form.
        #
        # Listing is split from the sed|grep|sort|tail pipeline on purpose:
        # under `set -e` (no `pipefail` here -- see below), a pipeline's exit
        # status is its last command's, so a failed `gcloud storage ls`
        # (expired auth, no bucket permission, network down) would be masked
        # by `tail -n1` exiting 0 on empty input, and fall through to the
        # "No snapshots found" guard below -- a misleading diagnosis on the
        # restore path, during an incident. Testing the listing on its own
        # keeps that failure loud and distinct from a genuinely empty bucket.
        # (Not fixed with `set -o pipefail` instead: `grep` exits 1 when it
        # matches nothing, so pipefail would turn a legitimately empty bucket
        # into a hard failure too.)
        if ! LISTING=$(gcloud storage ls "gs://${BUCKET_NAME}/"); then
            echo "${err}: could not list gs://${BUCKET_NAME} -- see the gcloud error above."
            echo "${err}: this is a listing failure, NOT an empty bucket."
            exit 1
        fi
        SNAP=$(echo "${LISTING}" | sed 's#.*/##' | grep '\.snap$' | sort | tail -n1)
    else
        # Sorted by LastModified, not by key name. Key-name ordering would be
        # actively dangerous during the changeover from the old
        # "%Y-%m-%d_%H:%M:%S_%Z" format: '_' sorts after 'T', so every old-format
        # object ranks above every new one and `tail -n1` would keep selecting a
        # stale snapshot until the 120-day lifecycle rule aged them out.
        SNAP=$(aws s3api list-objects-v2 --bucket "${BUCKET_NAME}" \
            --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
    fi
    if [ -z "${SNAP}" ] || [ "${SNAP}" = "None" ]; then
        echo "${err}: No snapshots found in ${BUCKET_NAME}."
        exit 1
    fi

    if [ "${CLOUD}" = "gcp" ]; then
        gcloud storage cp "gs://${BUCKET_NAME}/${SNAP}" "${SNAPSHOT_FILE}"
    else
        aws s3 cp "s3://${BUCKET_NAME}/${SNAP}" "${SNAPSHOT_FILE}"
    fi
    echo "${info}: Restoring snapshot ${SNAP}"

    # The pre-restore mint exists for the JWT and AppRole paths, whose tokens
    # lack sys/storage/raft/snapshot-force. A caller-supplied token is already
    # root on this node -- and on a rehydrate it is the ONLY thing that is,
    # because the lineage's recovery keys belong to the snapshot we are about to
    # restore, not to the throwaway init we are restoring over.
    if [ -z "${SUPPLIED_VAULT_TOKEN:-}" ]; then
        VAULT_TOKEN=$(generate_root_token)
        export VAULT_TOKEN
    fi

    bao operator raft snapshot restore -force "${SNAPSHOT_FILE}"

    # A raft restore replaces the entire storage backend, token store included,
    # so the token minted above no longer exists. Everything after this point —
    # including the revoke in the exit trap — needs a token generated against
    # the *restored* cluster.
    VAULT_TOKEN=$(generate_root_token)
    export VAULT_TOKEN
    # `-self` rather than passing the token as an argument: same job, nothing
    # on the command line.
    trap 'bao token revoke -self >/dev/null 2>&1 || true' EXIT

    echo "${info}: Checking that ${CHECK_PATH} is less than ${NUM_DAYS} days old (--freshness ${FRESHNESS})"
    CURR_TS=$(date -u "+%s")

    # A READ FAILURE IS NOT AN ABSENT MARKER, and collapsing the two is the
    # mistake this file already argues against fifteen lines up, for bucket
    # listing: "keeps that failure loud and distinct from a genuinely empty
    # bucket". `2>/dev/null || true` would make permission-denied, mount-absent,
    # network-down, token-expired and genuinely-absent indistinguishable -- so
    # under --freshness warn a misconfigured read would silently mean "no
    # marker, carry on" and the guard could never fire. Fail open on purpose is
    # one thing; failing open by accident is another.
    kv_err="${HOME:-/tmp}/.kvget.$$"
    # shellcheck disable=SC2046 # kv_ns_flag prints zero or one word by design
    if VAULT_TS=$(bao kv get $(kv_ns_flag) --field=value "${CHECK_PATH}" 2>"${kv_err}"); then
        :
    elif grep -qi 'no value found\|not found' "${kv_err}"; then
        VAULT_TS=""
    else
        echo "${err}: could not READ ${CHECK_PATH}. This is a read failure, not an"
        echo "${err}: absent marker -- the mount may be missing, or this token may"
        echo "${err}: lack read on it. The snapshot HAS already been restored."
        cat "${kv_err}" >&2
        rm -f "${kv_err}"
        exit 1
    fi
    rm -f "${kv_err}"

    if [ -z "${VAULT_TS}" ]; then
        if [ "${FRESHNESS}" = "fail" ]; then
            echo "${err}: ${CHECK_PATH} is absent from the restored snapshot; cannot judge its age."
            exit 1
        fi
        echo "${warn}: ${CHECK_PATH} is absent from the restored snapshot (one taken before save() stamped it, or taken while the mount did not exist). Continuing."
        VAULT_TS=""
    fi

    # Guard the arithmetic: a non-numeric value would abort even under
    # --freshness warn, with `bad number` from dash rather than anything a
    # reader could act on.
    case "${VAULT_TS}" in
        '') : ;;
        *[!0-9]*)
            echo "${warn}: ${CHECK_PATH} holds a non-numeric value; cannot judge age."
            VAULT_TS="" ;;
    esac

    if [ -n "${VAULT_TS}" ]; then
        AGE_DAYS=$(( (CURR_TS - VAULT_TS) / 86400 ))
        echo "${info}: The restored snapshot was taken ${AGE_DAYS} day(s) ago."
        if [ $((CURR_TS - VAULT_TS)) -gt $((NUM_DAYS * 86400)) ]; then
            if [ "${FRESHNESS}" = "fail" ]; then
                echo "${err}: The restored snapshot is more than ${NUM_DAYS} days old."
                exit 1
            fi
            echo "${warn}: The restored snapshot is more than ${NUM_DAYS} days old. Continuing (--freshness warn)."
        fi
    fi
    # No re-stamp here: the marker means "when the snapshot was taken", and
    # only save() knows that.
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
