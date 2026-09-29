# shellcheck shell=bash
#
# Resolve the ZITADEL admin PAT, and make it survive a database restore.
#
# THE PROBLEM THIS SOLVES
#
# The Helm chart provisions the iam-admin machine user and its PAT during
# FirstInstance, and writes the token to a Kubernetes Secret. FirstInstance runs
# only against an EMPTY database -- so a cluster restored from a backup has the
# machine user (it is in the restore) and no token anywhere (it was in a Secret
# that died with the previous cluster).
#
# On 2026-08-29 that left both clusters unable to run any ZITADEL setup script,
# while their OIDC clients still pointed at a domain retired a month earlier.
# The configuration was stale and the repair was impossible at the same time.
#
# THE FIX
#
# The chart's Secret when it exists, overwriting the stored copy; the store only
# when the cluster has none (a restore). GCP parity GP-20, owner 2026-09-29. The
# restore case works because the restored database keeps the machine user AND
# its token hash, so a token captured at first bootstrap stays valid against
# the restored instance.
#
# No ExternalSecret: nothing in the cluster consumes this credential, only
# operator scripts, and an ExternalSecret would contend with the chart for
# ownership of the Secret the chart itself creates.

# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "${BASH_SOURCE[0]}")/cloud-secret-store.sh"

ZITADEL_PAT_K8S_NAMESPACE="${ZITADEL_PAT_K8S_NAMESPACE:-security}"
ZITADEL_PAT_K8S_SECRET="${ZITADEL_PAT_K8S_SECRET:-iam-admin-pat}" # pragma: allowlist secret

# GCP Secret Manager forbids `/` in a name; AWS allows it and the repo uses it.
zitadel_pat_secret_name() {
    case "$CLOUD" in
        gcp) echo "zitadel-iam-admin-pat" ;;
        *)   echo "zitadel/iam-admin-pat" ;;
    esac
}

# Echo the token on stdout. Everything else goes to stderr -- callers capture
# this in $(...), and a log line on stdout becomes part of the token.
#
# ZITADEL_PAT_DRY_RUN is THIS function's own dry-run signal, read fresh on
# every call rather than assumed. Every caller (zitadel-oidc-clients.sh,
# zitadel-idp.sh) already tracks its own dry-run state as $APPLY, but reading
# that directly here would mean this function's behaviour depends on a
# variable it does not own happening to exist with a name and sense it
# guesses right -- true today by convention, not by contract, and the kind of
# accident that breaks silently the day one caller renames or inverts its
# own flag. A caller that wants dry-run honoured sets THIS variable,
# explicitly, before calling in. Left unset (any caller that predates this,
# or a caller that only ever runs applied), the default is "false" --
# unchanged behaviour, so nothing depends on this without asking for it.
#
# Defaulting to "false" also matters for the persist path below: a --apply
# run must still capture the PAT into the store on its first sight of one,
# same as before this existed.
resolve_zitadel_pat() {
    local name stored="" current="" token b64
    local dry_run="${ZITADEL_PAT_DRY_RUN:-false}"
    name="$(zitadel_pat_secret_name)"
    # 1. The cluster. The chart writes this Secret on FirstInstance, so when it
    #    exists it belongs to the directory that is running. A stored copy may
    #    belong to one a fresh build replaced (GCP parity GP-20), so it never
    #    wins over this.
    b64="$(kubectl get secret "$ZITADEL_PAT_K8S_SECRET" \
             -n "$ZITADEL_PAT_K8S_NAMESPACE" -o jsonpath='{.data.pat}' 2>/dev/null || true)"
    token=""
    [ -n "$b64" ] && token="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
    if [ -n "$token" ]; then
        if store_exists "$name" && stored="$(store_read "$name")"; then
            current="$(printf '%s' "$stored" | jq -r '.pat // empty' 2>/dev/null || true)"
        fi
        if [ "$current" != "$token" ]; then
            if [ "$dry_run" = "true" ]; then
                echo "[dry-run] would write the cluster's admin PAT to ${name}" >&2
            else
                echo "[persist] writing the cluster's admin PAT to ${name}" >&2
                # Own our provenance: a caller's STORE_WRITE_* globals are for its own secrets.
                local STORE_WRITE_DESCRIPTION="ZITADEL iam-admin PAT for ${CLUSTER:-this cluster}. Captured by zitadel-pat.sh."
                local STORE_WRITE_LABEL="zitadel-pat"
                # jq -Rs: the token reaches jq on stdin, never in argv.
                store_write "$name" <<< "$(printf '%s' "$token" | jq -Rs '{pat: .}')"
            fi
        fi
        printf '%s' "$token"
        return 0
    fi
    # 2. The store: the only source after a restore from a seed, where
    #    FirstInstance never ran and the chart wrote no Secret. Stored as
    #    {"pat": ...}, the one shape store_write's AWS branch accepts.
    if store_exists "$name" && stored="$(store_read "$name")" \
        && token="$(printf '%s' "$stored" | jq -r '.pat // empty' 2>/dev/null)" \
        && [ -n "$token" ]; then
        printf '%s' "$token"
        return 0
    fi

    echo "ERROR: no ZITADEL admin PAT available." >&2
    echo "       looked in: ${name} (cloud secret store)" >&2
    echo "                  ${ZITADEL_PAT_K8S_NAMESPACE}/${ZITADEL_PAT_K8S_SECRET} (cluster)" >&2
    echo >&2
    echo "The chart writes that Secret during FIRSTINSTANCE, which runs only" >&2
    echo "against an empty database. A cluster restored from a backup never runs" >&2
    echo "it, so on a restored cluster the Secret is absent and waiting will not" >&2
    echo "produce it." >&2
    echo >&2
    echo "Mint a PAT for the iam-admin machine user in the ZITADEL console, then:" >&2
    echo "  kubectl create secret generic ${ZITADEL_PAT_K8S_SECRET} \\" >&2
    echo "    -n ${ZITADEL_PAT_K8S_NAMESPACE} --from-literal=pat=<token>" >&2
    echo "and re-run this script -- it will persist the token for next time." >&2
    return 1
}
