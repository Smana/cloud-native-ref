#!/bin/sh
set -e

# Removed color variables
err="ERROR"
info="INFO"
# warn is used in error messages
export warn="WARNING"

# Replacing array with individual checks
#
# `curl` joined the list when the seal segment did (see "Seal legibility"
# below): the seal type is read from /v1/sys/seal-status, which is unwrapped
# and unauthenticated, and `bao status` cannot stand in for it -- that command
# exits 2 whenever the node is sealed, which is precisely its state on the
# restore path. curl is already in this image (see the Dockerfile's apt step)
# and is already a pre-flight requirement of the caller in
# scripts/openbao-config.sh, so this adds nothing an operator does not have.
check_required_bin() {
    for BIN in bao jq curl; do
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

# ---------------------------------------------------------------------------
# Seal legibility
# ---------------------------------------------------------------------------
#
# A Raft snapshot can only be restored under THE SEAL THAT ENCRYPTED IT, and
# the platform exploits that on purpose: a GCP standby unseals with the *AWS*
# KMS key so it can restore AWS snapshots (ADR-0033). The consequence is that
# the GCP bucket becomes a mixed-seal namespace after a failover -- mirrored
# objects are AWS-sealed by construction, and the standby's own are AWS-sealed
# too, because it ran with seal_provider = "awskms".
#
# So the seal goes IN THE OBJECT NAME:
#
#     <UTC timestamp>-<seal>.snap        e.g. 2026-09-02T041500Z-awskms.snap
#
# A trailing SEGMENT, not a key prefix. A prefix (`awskms/<ts>.snap`) makes an
# object drop out of the candidate set altogether -- both selection paths list
# non-recursively and strip through the last "/" -- which is exactly what you
# want from "move this aside" and exactly wrong for normal operation. Keeping
# the timestamp leading, and fixed-width, also keeps lexicographic order
# chronological across seals, which is what the GCP selector relies on.
SNAP_NAME_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-[a-z0-9]+\.snap$'

# Objects with NO seal segment -- everything written before this scheme, and
# anything moved under a prefix -- are never selected. Their seal cannot be
# determined from anything a selector can read, so accepting one reintroduces
# the whole hazard; and silently skipping one could restore an older snapshot
# while a newer sits there, which is silent data loss on the disaster-recovery
# path. Both selectors refuse and name the object instead.
#
# The escape hatch, for the one legitimate case: a bucket whose newest objects
# are foreign-sealed and are not coming back (the failback in
# website/content/docs/guides/openbao-cross-cloud-failover.md). Set this and
# the newest object THIS NODE'S seal can unwrap is used, with the skipped ones
# counted in the log. Deliberately not the default: skipping a newer snapshot
# discards data, and that decision belongs to an operator rather than to a
# selector.
SKIP_FOREIGN_SEAL="${OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL:-false}"
case "${SKIP_FOREIGN_SEAL}" in
    true|false) ;;
    *) echo "${err}: OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL must be 'true' or 'false', got '${SKIP_FOREIGN_SEAL}'." ; exit 1 ;;
esac

# GET /v1/sys/seal-status, honouring the same TLS choices as everything else
# here. Built as explicit branches rather than by word-splitting a variable of
# flags: `"${VAULT_CACERT:+--cacert $VAULT_CACERT}"` passes `--cacert /path` as
# ONE argv element when quoted and an empty word when unset -- the exact trap
# already documented in verify_pki_present() in scripts/openbao-config.sh.
seal_status_raw() {
    if [ -n "${VAULT_CACERT:-}" ] && [ -n "${VAULT_SKIP_VERIFY:-}" ]; then
        curl -sS -k --cacert "${VAULT_CACERT}" "${VAULT_ADDR}/v1/sys/seal-status"
    elif [ -n "${VAULT_CACERT:-}" ]; then
        curl -sS --cacert "${VAULT_CACERT}" "${VAULT_ADDR}/v1/sys/seal-status"
    elif [ -n "${VAULT_SKIP_VERIFY:-}" ]; then
        curl -sS -k "${VAULT_ADDR}/v1/sys/seal-status"
    else
        curl -sS "${VAULT_ADDR}/v1/sys/seal-status"
    fi
}

# The seal this node actually runs, on stdout; empty and non-zero when it
# cannot be established.
#
# Read from the NODE, not from a variable: `seal_provider` in a tfvars file can
# disagree with the process that is running, and the whole point of the segment
# is to record what really wrapped the bytes. /v1/sys/seal-status is
# UNAUTHENTICATED -- it sits on OpenBao's bare HTTP mux next to /v1/sys/init
# and /v1/sys/health (openbao/openbao, http/handler.go:164 at v2.6.2) -- so both
# the writer (save, holding a JWT token) and the reader (restore, running
# against a node that is up but may not be initialised yet) can ask it.
#
# `.type` is the BARRIER seal type: awskms, gcpckms, shamir. That is only true
# from OpenBao 2.4.0 onward -- before openbao/openbao#1638 the field was
# hardcoded "shamir" for every configuration (issue #1633). Both clusters pin
# 2.6.2 (`openbao_version`, opentofu/{aws,gcp}/openbao/cluster/variables.tf),
# and the guard below refuses rather than trusting a misreport: labelling every
# object "-shamir" on both clouds would reintroduce, invisibly, the very hazard
# the segment exists to remove.
node_seal_type() {
    seal_out=$(seal_status_raw 2>/dev/null) || seal_out=""
    if [ -z "${seal_out}" ]; then
        echo "${err}: could not read ${VAULT_ADDR}/v1/sys/seal-status." >&2
        echo "${err}: that endpoint needs no token, so this is the node or the TLS trust," >&2
        echo "${err}: not a credential. The seal type is what names a snapshot and what" >&2
        echo "${err}: decides whether one can be restored here, so refusing rather than" >&2
        echo "${err}: writing or selecting an object whose seal is unknown." >&2
        return 1
    fi

    seal_type=$(printf '%s' "${seal_out}" | jq -r '.type // empty' 2>/dev/null) || seal_type=""
    seal_recovery=$(printf '%s' "${seal_out}" | jq -r 'if .recovery_seal == true then "true" else "false" end' 2>/dev/null) || seal_recovery="false"

    if [ -z "${seal_type}" ]; then
        echo "${err}: ${VAULT_ADDR}/v1/sys/seal-status returned no '.type' field." >&2
        echo "${err}: response was: ${seal_out}" >&2
        return 1
    fi
    # It goes into an object key and into a regex; keep it boring.
    if ! printf '%s' "${seal_type}" | grep -Eq '^[a-z0-9]+$'; then
        echo "${err}: seal type '${seal_type}' is not a plain lowercase token, so it cannot" >&2
        echo "${err}: safely become part of an object name. Refusing." >&2
        return 1
    fi
    # An impossible combination, and a precise fingerprint of a server older
    # than OpenBao 2.4.0: before openbao/openbao#1638, sys/seal-status reported
    # "shamir" for EVERY barrier -- auto-unseal included -- while still setting
    # recovery_seal for the auto-unseal case. A real Shamir barrier has no
    # recovery seal, so the pair cannot both be honest.
    if [ "${seal_type}" = "shamir" ] && [ "${seal_recovery}" = "true" ]; then
        echo "${err}: this node reports a 'shamir' barrier AND recovery_seal=true, which" >&2
        echo "${err}: cannot both be true -- a Shamir barrier has no recovery seal. That is" >&2
        echo "${err}: what an OpenBao older than 2.4.0 reports for an auto-unseal barrier" >&2
        echo "${err}: (openbao/openbao#1633, fixed by #1638). Trusting it would label every" >&2
        echo "${err}: object '-shamir' on both clouds and hide the mixed-seal hazard again." >&2
        echo "${err}: Upgrade the server; \`openbao_version\` pins 2.6.2." >&2
        return 1
    fi
    printf '%s' "${seal_type}"
}

# The seal segment an object name carries, or empty when it carries none.
#
# Anchored against the WHOLE name rather than split on the last "-": the
# timestamp contains dashes too, so splitting a legacy "2026-09-02T041500Z.snap"
# yields "02T041500Z" -- a string that is not a seal, but is not obviously not
# one either.
snapshot_seal_segment() {
    printf '%s' "$1" | grep -Eq "${SNAP_NAME_RE}" || return 0
    printf '%s' "$1" | sed -E 's/^.*Z-([a-z0-9]+)\.snap$/\1/'
}

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
      OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL
                                : 'true' lets 'restore' skip objects sealed by a
                                  DIFFERENT seal than this node's, and use the newest
                                  object this node's seal can unwrap. Default 'false',
                                  which REFUSES instead -- skipping a newer snapshot
                                  discards every write after it. Only for a failback,
                                  where the foreign-sealed objects are not coming back.

      Object naming:
      Objects are written as <UTC timestamp>-<seal>.snap, e.g.
      2026-09-02T041500Z-awskms.snap. The seal is read from the node itself
      (/v1/sys/seal-status, unauthenticated), because a snapshot can only be
      restored under the seal that encrypted it -- so 'restore' selects the newest
      object and REFUSES if its seal is not this node's. Objects with no seal
      segment (written before this scheme) are never selected; see the container
      image README for how to retag one.

      ex:
      # Run a snapshot (backup)
      ./${SCRIPT_NAME} save -a https://bao.domain.tld:8200 -s /path/backup.snap -b mybucketname

      # Restore from a snapshot
      ./${SCRIPT_NAME} restore -a https://bao.domain.tld:8200 -s /path/backup.snap -b mybucketname -d 10
EOF
}

# Options parsing
#
# The guard is load-bearing on the entry point of the disaster-recovery path.
# `COMMAND=$1; shift` under `set -e` handled neither end of a bad invocation:
# with NO arguments, `shift` fails ("shift: can't shift that many") and the
# shell exits -- 2 under dash, 1 under bash -- having printed nothing at all;
# and with `-h` first, the option was consumed AS the command, so an operator
# asking for help was answered with "The OpenBao address must be provided
# (--addr)!" and a non-zero exit.
if [ $# -eq 0 ]; then
    echo "${err}: a command is required: 'save' or 'restore'." >&2
    usage
    exit 2
fi
case "$1" in
    -h | --help) usage; exit 0;;
esac
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

# RECOVERY_KEYS_SECRET_ID, on stderr, returning rather than exiting.
#
# Split out of generate_root_token so restore() can ask the same question on the
# NEAR side of `snapshot restore -force`. It is required by every restore, not
# only by the ones that authenticate with it: see the unconditional mint after
# the restore for why.
require_recovery_keys_secret() {
    if [ -n "${RECOVERY_KEYS_SECRET_ID:-}" ]; then
        return 0
    fi
    echo "${err}: RECOVERY_KEYS_SECRET_ID must be set to run a restore." >&2
    echo "${err}: It names the secret holding the OpenBao recovery keys --" >&2
    echo "${err}: an AWS Secrets Manager entry, or a GCP Secret Manager secret." >&2
    echo "${err}: A restore needs it EVEN WHEN VAULT_TOKEN is supplied: a raft" >&2
    echo "${err}: restore replaces the token store, so the token that performed" >&2
    echo "${err}: the restore no longer exists, and everything after it runs on a" >&2
    echo "${err}: token minted from these keys." >&2
    return 1
}

# Check if required binaries are installed
# Only used by `restore`, which is an operator action run with operator
# credentials - not something the CronJob can do. The job's EKS Pod Identity
# role has no secretsmanager access on purpose: a daily backup pod able to read
# the material that regenerates a root token is a privilege escalation.
#
# The secret is written by `openbao-config.sh init` as
# {"recovery_keys": [...], "recovery_key": "<first>", "threshold": N}.
# This handles threshold 1; a higher threshold needs one -nonce round per share.
#
# EVERY diagnostic below goes to STDERR, and that is not a style choice: this
# function is only ever called as `VAULT_TOKEN=$(generate_root_token)`, so a
# message on stdout is captured by the command substitution and the operator
# sees a bare non-zero exit with no reason -- measured, on both of its error
# paths. Same bug, same fix, as node_seal_type() above and log_err() in
# scripts/openbao-config.sh.
# The LINEAGE's root token, as stored at init time. Used after a raft restore,
# where the snapshot's token store makes it valid again -- see the long note at
# the post-restore call site for why this is preferred over minting.
#
# Same stderr discipline as generate_root_token below: this is called as
# `VAULT_TOKEN=$(stored_root_token)`, so anything on stdout would be captured
# into the token itself.
stored_root_token() {
    _srt_raw=""
    if [ "${CLOUD}" = "gcp" ]; then
        _srt_raw=$(gcloud secrets versions access latest --secret="${ROOT_TOKEN_SECRET_ID}" 2>/dev/null) || return 1
    else
        _srt_raw=$(aws secretsmanager get-secret-value --secret-id "${ROOT_TOKEN_SECRET_ID}" 2>/dev/null | jq -r '.SecretString') || return 1
    fi
    [ -n "${_srt_raw}" ] || return 1
    # `.token` is the shape openbao-config.sh's init writes. `.root_token` is
    # accepted too because that is what `bao operator init -format=json` calls
    # it, and an operator storing the raw init output is the obvious mistake.
    _srt_tok=$(printf '%s' "${_srt_raw}" | jq -r '.token // .root_token // empty' 2>/dev/null)
    [ -n "${_srt_tok}" ] || return 1
    printf '%s' "${_srt_tok}"
}

generate_root_token() {
    require_recovery_keys_secret || exit 1

    if [ "${CLOUD}" = "gcp" ]; then
        RECOVERY_SECRET=$(gcloud secrets versions access latest --secret="${RECOVERY_KEYS_SECRET_ID}")
    else
        RECOVERY_SECRET=$(aws secretsmanager get-secret-value --secret-id "${RECOVERY_KEYS_SECRET_ID}" | jq -r '.SecretString')
    fi

    RECOVERY_THRESHOLD=$(echo "${RECOVERY_SECRET}" | jq -r '.threshold // 1')
    if [ "${RECOVERY_THRESHOLD}" -gt 1 ]; then
        echo "${err}: recovery threshold is ${RECOVERY_THRESHOLD}; this script only automates a threshold of 1." >&2
        echo "${err}: Run 'bao operator generate-root' by hand, supplying ${RECOVERY_THRESHOLD} shares." >&2
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
    # One `read` PER LINE. `jq -cr '.nonce, .otp'` prints two lines, and a
    # single `read -r VAULT_NONCE VAULT_OTP` consumes only the first -- so the
    # OTP came out empty and `generate-root -decode` failed with "otp string is
    # wrong length", after the destructive restore had already run. Introduced
    # in #1844 and never caught, because nothing exercised this path.
    { read -r VAULT_NONCE; read -r VAULT_OTP; } < "$nonce_file"
    rm -f "$nonce_file"
    VAULT_ENCODED_TOKEN=$(echo "${RECOVERY_SECRET}" | jq -r '.recovery_key' | bao operator generate-root -nonce="${VAULT_NONCE}" --format json - | jq -cr '.encoded_root_token')
    VAULT_TOKEN=$(bao operator generate-root -decode "${VAULT_ENCODED_TOKEN}" -otp "${VAULT_OTP}")
    unset RECOVERY_SECRET
    echo "${VAULT_TOKEN}"
}

# Four ways in, tried in order. VAULT_TOKEN wins so an operator (or the
# rehydrate step, which holds a fresh root token) can drive save/restore
# directly; the JWT path is what the CronJob uses; AppRole is kept for a
# snapshot taken by hand against a lineage that predates the JWT mounts; and
# bao's own token helper (~/.vault-token, from a prior `bao login`) covers an
# operator who is already authenticated but has no VAULT_TOKEN exported.
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
    # The seal FIRST, before anything is written anywhere. A snapshot whose
    # seal cannot be established cannot be named, and an object with no seal
    # segment is one no future restore will select -- so it is not a backup,
    # it is a silent gap. Failing here is loud: the CronJob's next miss trips
    # OpenBaoSnapshotStale.
    SEAL_TYPE=$(node_seal_type) || exit 1
    echo "${info}: This node's seal is '${SEAL_TYPE}'; the object will carry it."
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
    # UTC, colon-free, lexicographically sortable, then the seal. The previous
    # "%Y-%m-%d_%H:%M:%S_%Z" embedded colons (legal in S3, awkward everywhere
    # downstream) and a local timezone abbreviation, so key order broke across a
    # DST change. The timestamp stays FIRST and fixed-width so `sort | tail -n1`
    # remains chronological even in a bucket holding two seals.
    SNAP_OBJECT="$(date -u +"%Y-%m-%dT%H%M%SZ")-${SEAL_TYPE}.snap"
    if [ "${CLOUD}" = "gcp" ]; then
        gcloud storage cp "${SNAPSHOT_FILE}" "gs://${BUCKET_NAME}/${SNAP_OBJECT}"
    else
        aws s3 cp "${SNAPSHOT_FILE}" "s3://${BUCKET_NAME}/${SNAP_OBJECT}"
    fi
    echo "${info}: Wrote ${SNAP_OBJECT}"
}

restore() {
    echo "${info}: Restoring OpenBao from object storage..."
    check_required_bin
    # Demanded HERE, on the near side of `snapshot restore -force`, because the
    # mint AFTER the restore needs it unconditionally. Discovering it afterwards
    # produced the worst combination available on this path: the storage backend
    # WAS replaced, the run still exited non-zero, and rehydrate_openbao read
    # that as "Restore failed ... Destroy and redeploy the cluster stack" about a
    # node that had in fact been restored.
    require_recovery_keys_secret || exit 1
    # Advisory, not required. Nothing between here and the restore uses this
    # token: generate_root_token below mints one from the recovery keys, needs
    # no authentication, and overwrites VAULT_TOKEN. Demanding a credential
    # here would refuse the case this command exists for -- a node that is
    # initialised but has no usable auth method yet.
    if ! authenticate; then
        echo "${warn}: no ordinary credential available; continuing, because a"
        echo "${warn}: restore authenticates with the recovery keys instead."
    fi

    # The seal BEFORE anything is selected or downloaded. On a rehydrate this
    # runs against the node that is about to be restored INTO -- which is
    # exactly the node whose seal has to unwrap the object -- and the endpoint
    # answers there because it needs no token and no initialised barrier.
    SEAL_TYPE=$(node_seal_type) || exit 1
    echo "${info}: This node's seal is '${SEAL_TYPE}'."

    echo "${info}: Fetching latest backup from bucket ${BUCKET_NAME}"
    # CANDIDATES is the whole candidate set, oldest first, one object name per
    # line -- not just the newest. The seal gate below has to be able to count
    # what it is refusing and, under the escape hatch, to reach past it.
    #
    # Top-level objects only, both clouds. An object moved under a prefix
    # ("awskms/<ts>.snap") is by definition one an operator moved ASIDE, and
    # must not be selected; GCP already dropped those (a non-recursive listing
    # plus `sed 's#.*/##'` leaves a directory entry that no longer matches
    # '\.snap$'), and AWS now does too rather than selecting any key at all.
    if [ "${CLOUD}" = "gcp" ]; then
        # Lexicographic is chronological here, and only here. The AWS bucket
        # still holds objects in the old "%Y-%m-%d_%H:%M:%S_%Z" format, where
        # '_' sorts after 'T' so every legacy key ranks above every new one --
        # hence the LastModified sort below. The GCP bucket was created after
        # the format change and has only ever held the sortable form.
        #
        # Listing is split from the sed|grep|sort pipeline on purpose: under
        # `set -e` (no `pipefail` here -- see below), a pipeline's exit status
        # is its last command's, so a failed `gcloud storage ls` (expired auth,
        # no bucket permission, network down) would be masked by `sort` exiting
        # 0 on empty input, and fall through to the "No snapshots found" guard
        # below -- a misleading diagnosis on the restore path, during an
        # incident. Testing the listing on its own keeps that failure loud and
        # distinct from a genuinely empty bucket. (Not fixed with `set -o
        # pipefail` instead: `grep` exits 1 when it matches nothing, so
        # pipefail would turn a legitimately empty bucket into a hard failure
        # too -- hence the `|| true` guards on every grep below as well.)
        if ! LISTING=$(gcloud storage ls "gs://${BUCKET_NAME}/"); then
            echo "${err}: could not list gs://${BUCKET_NAME} -- see the gcloud error above."
            echo "${err}: this is a listing failure, NOT an empty bucket."
            exit 1
        fi
        CANDIDATES=$(echo "${LISTING}" | sed 's#.*/##' | { grep '\.snap$' || true; } | sort)
    else
        # Sorted by LastModified, not by key name. Key-name ordering would be
        # actively dangerous during the changeover from the old
        # "%Y-%m-%d_%H:%M:%S_%Z" format: '_' sorts after 'T', so every old-format
        # object ranks above every new one and `tail -n1` would keep selecting a
        # stale snapshot until the 120-day lifecycle rule aged them out.
        #
        # Full JSON through jq rather than `--query 'sort_by(...)[-1].Key'`, for
        # the same reason latest_snapshot() in scripts/openbao-config.sh does
        # it this way: that query ERRORS on an empty bucket, so exit status
        # alone could not separate "empty" from "could not list" -- and the
        # gate below needs the whole set, not only the last element.
        if ! LISTING=$(aws s3api list-objects-v2 --bucket "${BUCKET_NAME}" --output json); then
            echo "${err}: could not list s3://${BUCKET_NAME} -- see the aws error above."
            echo "${err}: this is a listing failure, NOT an empty bucket."
            exit 1
        fi
        CANDIDATES=$(printf '%s' "${LISTING}" | jq -r '
            (.Contents // [])
            | map(select((.Key | contains("/")) | not))
            | map(select(.Key | endswith(".snap")))
            | sort_by(.LastModified) | .[].Key')
    fi
    if [ -z "${CANDIDATES}" ]; then
        echo "${err}: No snapshots found in ${BUCKET_NAME}."
        exit 1
    fi

    SNAP=$(printf '%s\n' "${CANDIDATES}" | tail -n1)
    SNAP_SEAL=$(snapshot_seal_segment "${SNAP}")

    # THE GATE. Everything below this point is destructive -- `operator raft
    # snapshot restore -force` replaces the entire storage backend -- and a
    # snapshot restored under the wrong seal leaves the node sealed with no
    # useful error at all. So the mismatch is caught here, by name, before a
    # single byte is downloaded.
    if [ "${SNAP_SEAL}" != "${SEAL_TYPE}" ]; then
        # `grep -c` prints its count and exits 1 when that count is zero, so
        # every one of these needs the `|| true`.
        n_all=$(printf '%s\n' "${CANDIDATES}" | { grep -c . || true; })
        n_tagged=$(printf '%s\n' "${CANDIDATES}" | { grep -cE "${SNAP_NAME_RE}" || true; })
        n_mine=$(printf '%s\n' "${CANDIDATES}" | { grep -cE "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-${SEAL_TYPE}\.snap$" || true; })
        if [ -n "${SNAP_SEAL}" ]; then
            found="sealed '${SNAP_SEAL}'"
        else
            found="carrying NO seal segment -- written before seals were legible in the name"
        fi
        NEWEST="${SNAP}"

        # THE REFUSAL IS PRINTED ONLY ON THE BRANCH THAT REFUSES. It used to be
        # printed above this test, unconditionally, so the documented failback
        # path logged "SEAL MISMATCH -- refusing to restore, before anything
        # destructive runs" and then ran `snapshot restore -force` anyway. Every
        # alert and every CI grep on that string drew the opposite conclusion
        # from what had happened. It also advised setting
        # OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true to an operator who had just
        # set it.
        if [ "${SKIP_FOREIGN_SEAL}" != "true" ]; then
            echo "${err}: SEAL MISMATCH -- refusing to restore, before anything destructive runs."
            echo "${err}:   this node's seal : ${SEAL_TYPE}"
            echo "${err}:   newest object    : ${NEWEST}"
            echo "${err}:                      ${found}"
            echo "${err}:   in ${BUCKET_NAME}: ${n_all} snapshot object(s), ${n_mine} this node can unwrap,"
            echo "${err}:                      $((n_all - n_tagged)) with no seal segment"
            echo "${err}: A Raft snapshot can only be restored under the seal that encrypted it, so"
            echo "${err}: restoring this one would leave the node sealed with no diagnosable error."
            echo "${err}: This is the mixed-seal state a cross-cloud failover leaves behind (ADR-0033):"
            echo "${err}: mirrored objects are AWS-sealed by construction, and a standby that ran with"
            echo "${err}: seal_provider = \"awskms\" wrote AWS-sealed objects of its own."
            echo "${err}: Pick one:"
            echo "${err}:   - deploy this node under the seal that matches the newest object, or"
            echo "${err}:   - re-run with OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true to restore the newest"
            echo "${err}:     object this node's '${SEAL_TYPE}' seal CAN unwrap. That DISCARDS every"
            echo "${err}:     write after it, so list the bucket and decide first."
            exit 1
        fi

        SNAP=$(printf '%s\n' "${CANDIDATES}" | { grep -E "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{6}Z-${SEAL_TYPE}\.snap$" || true; } | tail -n1)
        if [ -z "${SNAP}" ]; then
            # Self-contained: this is now the first thing printed on this path.
            echo "${err}: SEAL MISMATCH, and OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true cannot help --"
            echo "${err}: refusing to restore, before anything destructive runs."
            echo "${err}:   this node's seal : ${SEAL_TYPE}"
            echo "${err}:   newest object    : ${NEWEST}"
            echo "${err}:                      ${found}"
            echo "${err}: Nothing in ${BUCKET_NAME} carries the '-${SEAL_TYPE}' seal segment"
            echo "${err}: (${n_all} snapshot object(s), $((n_all - n_tagged)) with no seal segment), so there is"
            echo "${err}: no object to fall back to. This node cannot be rehydrated from this bucket:"
            echo "${err}: deploy it under the seal the objects carry, or point it at a bucket holding"
            echo "${err}: '${SEAL_TYPE}' snapshots."
            exit 1
        fi
        # Also self-contained, and it says PROCEEDING rather than refusing.
        echo "${warn}: SEAL MISMATCH, and OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true -- PROCEEDING."
        echo "${warn}:   this node's seal : ${SEAL_TYPE}"
        echo "${warn}:   newest object    : ${NEWEST} (${found}) -- SKIPPED"
        echo "${warn}:   restoring instead: ${SNAP}, the newest of the ${n_mine} object(s) this node can unwrap"
        echo "${warn}:   in ${BUCKET_NAME}: ${n_all} snapshot object(s), $((n_all - n_tagged)) with no seal segment"
        echo "${warn}: Whatever was written after ${NEWEST} is NOT in this restore."
    fi

    if [ "${CLOUD}" = "gcp" ]; then
        gcloud storage cp "gs://${BUCKET_NAME}/${SNAP}" "${SNAPSHOT_FILE}"
    else
        aws s3 cp "s3://${BUCKET_NAME}/${SNAP}" "${SNAPSHOT_FILE}"
    fi
    echo "${info}: Restoring snapshot ${SNAP}"

    # The revoke trap is armed BEFORE the first mint, not after the last one.
    # Armed afterwards, a token minted here and then orphaned by a failing
    # `snapshot restore -force` lived out its full TTL -- a root token, on the
    # one path where nothing is watching.
    #
    # It fires only for a token THIS function minted. A caller-supplied
    # VAULT_TOKEN -- an operator's own, or the throwaway root a rehydrate holds
    # and still needs to diagnose the node afterwards -- must survive a failure
    # here rather than be revoked by it. `-self` rather than passing the token as
    # an argument: same job, nothing on the command line.
    MINTED_ROOT_TOKEN=""
    trap 'if [ -n "${MINTED_ROOT_TOKEN}" ]; then bao token revoke -self >/dev/null 2>&1 || true; fi' EXIT

    # The pre-restore mint exists for the JWT and AppRole paths, whose tokens
    # lack sys/storage/raft/snapshot-force. A caller-supplied token is already
    # root on this node -- and on a rehydrate it is the ONLY thing that is,
    # because the lineage's recovery keys belong to the snapshot we are about to
    # restore, not to the throwaway init we are restoring over.
    if [ -z "${SUPPLIED_VAULT_TOKEN:-}" ]; then
        VAULT_TOKEN=$(generate_root_token)
        export VAULT_TOKEN
        MINTED_ROOT_TOKEN=1
    fi

    bao operator raft snapshot restore -force "${SNAPSHOT_FILE}"

    # A raft restore replaces the entire storage backend, TOKEN STORE INCLUDED,
    # so whatever authenticated the restore -- a token minted above, a JWT
    # token, or the throwaway root a rehydrate supplied -- does not exist in the
    # store that is now running. Everything below (the marker read, the revoke
    # in the trap) needs a token generated against the RESTORED cluster, so this
    # mint is unconditional.
    #
    # It is deliberately NOT symmetrical with the guarded mint above, and the
    # asymmetry is the whole point: the recovery keys in
    # RECOVERY_KEYS_SECRET_ID are the LINEAGE's, which is to say the snapshot's.
    # Before the restore they belong to a different barrier than the node in
    # front of us (hence skipping the mint when the caller already holds a root
    # token); after it they are exactly this node's. That is also why the
    # variable is demanded by restore()'s pre-flight rather than only by the
    # authentication paths that read it.
    #
    # PREFER THE STORED ROOT TOKEN, because minting is not available here.
    #
    # `generate_root_token` calls `bao operator generate-root`, which needs no
    # authentication -- on a SHAMIR-sealed node. Every node in this design is
    # auto-unsealed, and there the endpoint does not exist:
    #
    #   PUT /v1/sys/generate-root/attempt  -> 405 "unsupported operation"
    #
    # Its auto-unseal counterpart, /v1/sys/generate-recovery-token/attempt,
    # answers 403: it requires a token, which is the thing being obtained. So on
    # this platform the mint cannot succeed, and the first rehydrate to reach
    # this line failed here with the restore already applied -- reported as
    # "Restore failed" about a node that had in fact restored perfectly.
    #
    # The stored root token is the lineage's own, and a raft restore replaces the
    # token store WITH THE SNAPSHOT'S, so after the restore it is valid again by
    # construction. Verified on a restored node: lookup-self returns
    # display_name=root, policies=["root"].
    #
    # MINTED_ROOT_TOKEN must be CLEARED on this path, not merely left unset, and
    # the difference is the whole point: the EXIT trap revokes what this function
    # minted, and revoking the LINEAGE's root token would destroy the credential
    # the next rehydrate depends on.
    #
    # An earlier version of this comment claimed the flag "stays empty on this
    # path". It does not. The pre-restore mint above sets it to 1 whenever the
    # caller supplied no VAULT_TOKEN -- which is the JWT and AppRole path -- and
    # nothing cleared it before VAULT_TOKEN is replaced below with the lineage's
    # stored root token. The trap would then revoke THAT.
    #
    # Latent rather than live today: reaching it needs both no caller-supplied
    # token AND the pre-restore `generate_root_token` to have succeeded, and
    # generate-root/attempt returns 405 on every auto-unsealed node here, so the
    # script exits before this point. That makes it a landmine on the DR path
    # rather than a present failure, which is exactly the kind that detonates
    # once a node is Shamir-sealed or the endpoint starts working.
    if [ -n "${ROOT_TOKEN_SECRET_ID:-}" ]; then
        if ! VAULT_TOKEN=$(stored_root_token); then
            echo "${err}: could not read the stored root token from ${ROOT_TOKEN_SECRET_ID}." >&2
            echo "${err}: The restore SUCCEEDED -- the node is running the snapshot's data." >&2
            echo "${err}: Supply that token as VAULT_TOKEN and re-run, or read it by hand." >&2
            exit 1
        fi
        export VAULT_TOKEN
        # The token in hand is now the LINEAGE's, not one this function minted.
        MINTED_ROOT_TOKEN=""
        if ! bao token lookup >/dev/null 2>&1; then
            echo "${err}: the stored root token is not valid on the restored node." >&2
            echo "${err}: That happens when the token was rotated AFTER this snapshot was" >&2
            echo "${err}: taken, so the snapshot's token store predates it. Restore a newer" >&2
            echo "${err}: snapshot, or mint a token by hand from the recovery keys in" >&2
            echo "${err}: ${RECOVERY_KEYS_SECRET_ID}." >&2
            exit 1
        fi
    else
        VAULT_TOKEN=$(generate_root_token)
        export VAULT_TOKEN
        MINTED_ROOT_TOKEN=1
    fi

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
