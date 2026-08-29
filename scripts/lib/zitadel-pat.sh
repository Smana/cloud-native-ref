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
# Persist the token to the cloud secret store the first time it exists, and read
# it from there afterwards. This works because the restored database keeps the
# machine user AND its token hash, so a token captured at first bootstrap stays
# valid against the restored instance.
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
resolve_zitadel_pat() {
    local name stored token b64
    name="$(zitadel_pat_secret_name)"

    # 1. The store, which is the only source that survives a restore. Stored as
    #    a JSON object {"pat": ...} -- store_write's AWS branch parses stdin as
    #    JSON (it round-trips the payload through `jq '. | tostring'`), so a
    #    bare token string fails there with a parse error. Wrapping it is what
    #    lets both clouds share one store_write/store_read.
    if store_exists "$name" && stored="$(store_read "$name")" \
        && token="$(printf '%s' "$stored" | jq -r '.pat // empty' 2>/dev/null)" \
        && [ -n "$token" ]; then
        printf '%s' "$token"
        return 0
    fi

    # 2. The cluster, where the chart writes it on a fresh bootstrap only. This
    #    read is also the one chance to capture it.
    b64="$(kubectl get secret "$ZITADEL_PAT_K8S_SECRET" \
             -n "$ZITADEL_PAT_K8S_NAMESPACE" -o jsonpath='{.data.pat}' 2>/dev/null || true)"
    if [ -n "$b64" ]; then
        token="$(printf '%s' "$b64" | base64 -d 2>/dev/null || true)"
        if [ -n "$token" ]; then
            echo "[persist] capturing the admin PAT into ${name} so it survives a restore" >&2
            # Own our provenance rather than trusting whatever the caller set.
            # store_write reads these as plain globals, and a caller that sets
            # them for ITS OWN secrets (e.g. zitadel-oidc-clients.sh, for the
            # OIDC client secrets it writes) leaves them set in the shell that
            # eventually calls us -- a `local` here shadows that for this call
            # only, so the PAT gets ITS OWN description/label and the caller's
            # values are unchanged once we return.
            local STORE_WRITE_DESCRIPTION="ZITADEL iam-admin PAT for ${CLUSTER:-this cluster}. Captured by zitadel-pat.sh."
            local STORE_WRITE_LABEL="zitadel-pat"
            # jq -Rs reads stdin as one raw string rather than parsing it as
            # JSON -- unlike `jq --arg pat "$token"`, the token never appears
            # in an external process's argv (readable via /proc/<pid>/cmdline
            # for the life of that call), only on stdin.
            store_write "$name" <<< "$(printf '%s' "$token" | jq -Rs '{pat: .}')"
            printf '%s' "$token"
            return 0
        fi
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
