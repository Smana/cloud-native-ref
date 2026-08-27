#!/usr/bin/env bash
#
# Inspect and migrate the cloud secret store that backs External Secrets.
#
# WHY THIS EXISTS
#
# `clustersecretstore` is AWS Secrets Manager on aws-0 and GCP Secret Manager on
# gcp-0. A missing entry there is close to undiagnosable from the cluster: the
# ExternalSecret reports SecretSyncedError, the workload that wanted the Secret
# sits in CreateContainerConfigError, its HelmRelease never goes Ready, and the
# Flux Kustomization health check fails ten minutes later naming only the
# HelmRelease. On gcp-0 that exact chain took out four Kustomizations at once --
# observability-victoria-metrics-k8s-stack plus the three that dependsOn it --
# for one absent Grafana admin secret.
#
# `check` turns that ten-minute silence into an immediate list.
#
# COMMANDS
#
#   check --cloud aws|gcp [--context CTX]
#       For every ExternalSecret in the cluster, resolve the key it asks the
#       store for and report whether it exists. Read-only.
#
#   grant --cloud gcp --project ID [--context CTX] [--apply]
#       Grant External Secrets read access, per secret, to every key the
#       cluster's ExternalSecrets ask for. GCP only. Dry-run unless --apply.
#       Needed because most platform secrets are created after gke/init has
#       applied, so OpenTofu cannot grant them -- see the note in
#       opentofu/gcp/gke/init/iam.tf.
#
#   seed --cloud aws|gcp [--apply]
#       Create the few secrets this platform GENERATES rather than obtains, if
#       they are missing. Dry-run unless --apply. Never overwrites an existing
#       secret, so it is safe to re-run and safe on a cluster whose secrets were
#       written by hand. Most of the store is not seedable -- see GENERATABLE.
#
#   migrate-aws [--apply]
#       Copy AWS Secrets Manager entries from the old slash-separated names to
#       the portable dash-separated ones. Dry-run unless --apply. Additive: it
#       never deletes or overwrites, so it is safe to re-run and the old names
#       stay put until someone removes them deliberately.
#
#       Needed because a GCP secret ID matches [A-Za-z0-9_-]+, so the AWS-style
#       `harbor/admin/password` cannot exist on gcp-0 at all. The shared bases
#       now use the dash form; aws-0's store predates it.

set -o errexit
set -o nounset
set -o pipefail

CLOUD=""
CONTEXT=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
PROJECT=""
APPLY="false"
COMMAND="${1:-}"
[ $# -gt 0 ] && shift

while [ $# -gt 0 ]; do
    case "$1" in
        --cloud)   CLOUD="$2"; shift 2 ;;
        --context) CONTEXT="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

kctl() {
    if [ -n "$CONTEXT" ]; then kubectl --context "$CONTEXT" "$@"; else kubectl "$@"; fi
}

aws_sm() {
    if [ -n "$REGION" ]; then aws secretsmanager --region "$REGION" "$@"; else aws secretsmanager "$@"; fi
}

gcp_sm() {
    if [ -n "$PROJECT" ]; then gcloud secrets --project "$PROJECT" "$@"; else gcloud secrets "$@"; fi
}

# Does one key exist in the store?
#
# Returns 0 present, 1 genuinely absent. Anything else -- no region, no
# credentials, no permission -- EXITS, because reporting an API failure as
# "absent" is worse than not running at all: it reads as a clean, actionable
# list of secrets to create, and acting on it would overwrite nothing while
# hiding that the store was never actually consulted.
store_has() {
    local out rc
    case "$CLOUD" in
        aws)
            out=$(aws_sm describe-secret --secret-id "$1" 2>&1) && return 0 || rc=$?
            case "$out" in
                *ResourceNotFoundException*) return 1 ;;
            esac
            ;;
        gcp)
            out=$(gcp_sm describe "$1" 2>&1) && return 0 || rc=$?
            case "$out" in
                *NOT_FOUND*) return 1 ;;
            esac
            ;;
        *) echo "--cloud must be aws or gcp" >&2; exit 2 ;;
    esac
    echo >&2
    echo "ERROR: could not query the ${CLOUD} secret store for '$1' (exit ${rc})." >&2
    echo "${out}" | head -3 >&2
    echo >&2
    echo "Refusing to continue: an unreachable store is not an empty one." >&2
    [ "$CLOUD" = "aws" ] && echo "Hint: pass --region (aws configure get region is empty here)." >&2
    [ "$CLOUD" = "gcp" ] && echo "Hint: pass --project, or set one with gcloud config set project." >&2
    exit 1
}

cmd_check() {
    [ -n "$CLOUD" ] || { echo "--cloud is required" >&2; exit 2; }

    # Every remoteRef key, plus dataFrom.extract keys, across all namespaces.
    local keys
    keys=$(kctl get externalsecrets.external-secrets.io -A -o json \
        | jq -r '.items[]
                 | . as $es
                 | ((.spec.data // [])[]?.remoteRef.key,
                    (.spec.dataFrom // [])[]?.extract.key)
                 | select(. != null)
                 | "\($es.metadata.namespace)/\($es.metadata.name)\t\(.)"' \
        | sort -u)

    if [ -z "$keys" ]; then
        echo "no ExternalSecrets found (is the cluster reachable, and External Secrets installed?)"
        return 0
    fi

    local missing=0 total=0
    printf '%-52s %-58s %s\n' "EXTERNALSECRET" "STORE KEY" "STATUS"
    while IFS=$'\t' read -r es key; do
        [ -z "$key" ] && continue
        total=$((total + 1))
        if store_has "$key"; then
            printf '%-52s %-58s %s\n' "$es" "$key" "ok"
        else
            printf '%-52s %-58s %s\n' "$es" "$key" "MISSING"
            missing=$((missing + 1))
        fi
    done <<< "$keys"

    echo
    if [ "$missing" -gt 0 ]; then
        echo "${missing}/${total} key(s) missing from the ${CLOUD} store."
        echo "Every workload consuming one of them will hang its HelmRelease until it exists."
        return 1
    fi
    echo "all ${total} key(s) present in the ${CLOUD} store."
}

# Old AWS name -> portable name. Derived from the repo's own ExternalSecrets:
# every key that contained a slash before the rename.
OLD_NAMES=(
    "apps/openwebui/oauth-zitadel"
    "github/gha-runner-scale-set/default"
    "harbor/admin/password"
    "harbor/valkey/password"
    "headlamp/envvars"
    "observability/grafana/oncall-admin"
    "observability/grafana/oncall-rabbitmq"
    "observability/grafana/oncall-slackapp"
    "observability/grafana/oncall-valkey"
    # These two live under flux/, not */base, so the original sweep for the
    # rename never saw them -- it scanned the five */base directories only.
    # Both work on aws-0 (Secrets Manager takes the slashes) and neither can
    # exist on gcp-0, which is precisely the flux-ui-oidc ValuesError seen
    # there.
    "observability/flux/slack-app"
    "security/flux/ui-oidc"
    # These two are named in an App CLAIM's `secrets[].remoteRef`, not in a
    # `kind: ExternalSecret` document -- the Composition renders the
    # ExternalSecret from the claim. Both sweeps for the rename grepped for
    # ExternalSecret manifests, so both missed them.
    "apps/app-wizard/oauth"
    "apps/app-wizard/llm"
    "observability/victoria-metrics-k8s-stack/alertmanager-slack-app"
    "observability/victoria-metrics-k8s-stack/grafana-envvars"
    "openbao/cloud-native-ref/approles/cert-manager"
    "platform/llm/api-keys"
    "runlore/credentials"
    "runlore/slack-app"
    "runlore/webhook"
    "tailscale/k8s-operator/oauth-client"
    "zitadel/envvars"
)

cmd_migrate_aws() {
    CLOUD="aws"   # store_has dispatches on it; migrate-aws is AWS-only by definition
    local copied=0 skipped=0 absent=0
    for old in "${OLD_NAMES[@]}"; do
        local new="${old//\//-}"

        if ! store_has "$old"; then
            echo "[absent ] $old -- nothing to copy"
            absent=$((absent + 1))
            continue
        fi
        if store_has "$new"; then
            echo "[skip   ] $new -- already exists, left untouched"
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] $old -> $new"
            copied=$((copied + 1))
            continue
        fi

        # The value never leaves JSON and never touches disk.
        #
        # It is tempting to write this as --secret-string "$(… --output text)",
        # and the first version did. Command substitution strips trailing
        # newlines, so a secret whose value ends in one is copied a byte short --
        # which is exactly what happened to zitadel/envvars, and to nothing else,
        # because it was the only value with a trailing newline. A silent
        # one-byte corruption in 1 of 16 secrets is the kind of thing that
        # surfaces months later as an unexplained parse failure.
        #
        # The payload goes through a private temp file, not a pipe: the AWS CLI
        # cannot read --cli-input-json from file:///dev/stdin (it needs a
        # seekable file) and fails with "Invalid JSON received". Piping it looks
        # cleaner and does not work.
        #
        # umask 077 before mktemp so the file is never group- or world-readable,
        # and it is shredded on every exit path including a failure.
        local payload
        payload=$(umask 077 && mktemp -t secret-store-payload.XXXXXX)
        # shellcheck disable=SC2064  # expand $payload now, not at trap time
        trap "shred -u '${payload}' 2>/dev/null || rm -f '${payload}'" RETURN

        aws_sm get-secret-value --secret-id "$old" --output json \
            | jq --arg name "$new" \
                 --arg desc "Portable name for ${old}. Copied by scripts/secret-store.sh." \
                 '{Name: $name, Description: $desc, SecretString: .SecretString}' \
            > "$payload"

        aws_sm create-secret --cli-input-json "file://${payload}" >/dev/null
        echo "[copied ] $old -> $new"
        copied=$((copied + 1))
    done

    echo
    echo "copied: ${copied}, skipped (already present): ${skipped}, absent upstream: ${absent}"
    if [ "$APPLY" != "true" ]; then
        echo
        echo "This was a DRY RUN. Nothing was written. Re-run with --apply to perform the copy."
        echo "The old names are never deleted; remove them by hand once aws-0 is verified."
    fi
}

# Secrets whose contents this platform generates rather than obtains.
#
# Deliberately short. Most entries in the store are NOT here, because they are
# credentials some other system issues -- an OIDC client ZITADEL registered, a
# Slack app, a GitHub App key, a vendor API token. Generating a placeholder for
# those would produce a secret that exists, syncs, and fails at the point of use,
# which is strictly worse than one that is visibly missing.
#
# Two entries are partially generatable and appear here for the generatable half
# only:
#   grafana-envvars also carries GF_AUTH_GENERIC_OAUTH_CLIENT_{ID,SECRET}. Those
#   come from a ZITADEL client registration and are added by hand. Grafana boots
#   without them -- the SSO button fails, the pod does not -- so seeding the
#   admin pair alone is what unblocks the HelmRelease, and the four
#   Kustomizations behind it.
#
# Not seeded, though it is pure generation: observability-grafana-oncall-*.
# grafana-oncall is built under observability/base but wired into no
# Kustomization, so it runs nowhere on either cluster.
GENERATABLE=(
    "harbor-admin-password"
    "harbor-valkey-password"
    "observability-victoria-metrics-k8s-stack-grafana-envvars"
)

# 32 bytes of urandom, base64, punctuation removed so no consumer has to worry
# about quoting it in a connection string or an env file.
# No trailing `head` in the pipeline. `tr` reading /dev/urandom never ends on
# its own, so `head -c 32` closing the pipe kills it with SIGPIPE -- and under
# `set -o pipefail` that fails the whole script with exit 141.
#
# The old form worked only by timing: tr usually wrote its 32 bytes and exited
# before the signal landed. A sibling script using the identical idiom failed on
# its first run, which is what surfaced it here. Truncating with parameter
# expansion keeps every stage terminating normally.
# Accumulate until there is genuinely enough, rather than assuming one read
# yields 32 usable characters. Only 62 of 256 byte values are alphanumeric, so
# a fixed 128-byte read averages ~31 and silently produced SHORT passwords --
# 28 and 31 characters were both observed. A password quietly shorter than
# intended is the kind of defect that never announces itself.
gen_password() {
    local s=""
    while [ "${#s}" -lt 32 ]; do
        s+=$(head -c 256 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9')
    done
    printf '%s' "${s:0:32}"
}

# The JSON body for one generatable secret, on stdout.
seed_body() {
    case "$1" in
        harbor-admin-password)
            jq -n --arg p "$(gen_password)" '{password: $p}' ;;
        harbor-valkey-password)
            jq -n --arg p "$(gen_password)" '{REDIS_PASSWORD: $p}' ;;
        observability-victoria-metrics-k8s-stack-grafana-envvars)
            jq -n --arg p "$(gen_password)" \
                '{GF_SECURITY_ADMIN_USER: "admin", GF_SECURITY_ADMIN_PASSWORD: $p}' ;;
        *)
            echo "no generator for $1" >&2; return 1 ;;
    esac
}

# Create one secret from a JSON body on stdin. Never overwrites: callers check
# first, and both APIs below are create-only.
store_create() {
    case "$CLOUD" in
        aws)
            jq --arg name "$1" \
               --arg desc "Generated by scripts/secret-store.sh seed." \
               '{Name: $name, Description: $desc, SecretString: (. | tostring)}' \
                | aws_sm create-secret --cli-input-json file:///dev/stdin >/dev/null
            ;;
        gcp)
            gcp_sm create "$1" --replication-policy=automatic \
                --labels=managed-by=secret-store-sh >/dev/null
            gcp_sm versions add "$1" --data-file=- >/dev/null
            ;;
    esac
}

cmd_seed() {
    [ -n "$CLOUD" ] || { echo "--cloud is required" >&2; exit 2; }

    local created=0 skipped=0
    for name in "${GENERATABLE[@]}"; do
        if store_has "$name"; then
            echo "[skip   ] $name -- already exists, left untouched"
            skipped=$((skipped + 1))
            continue
        fi
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] $name -- would create with a generated value"
            created=$((created + 1))
            continue
        fi
        seed_body "$name" | store_create "$name"
        echo "[created] $name"
        created=$((created + 1))
    done

    echo
    echo "created: ${created}, skipped (already present): ${skipped}"
    echo
    echo "Generated secrets only. Everything else the cluster needs is issued by"
    echo "another system -- run 'check' to see what is still missing."
    if [ "$APPLY" != "true" ]; then
        echo
        echo "This was a DRY RUN. Re-run with --apply to create them."
    fi
}

# Grant External Secrets read access to every key the cluster actually asks for.
#
# GCP only, and per-secret by design: roles/secretmanager.secretAccessor at the
# PROJECT level would also hand ESO openbao-priv-gcp-root-token, the recovery
# keys and the intermediate CA's private key.
#
# This exists because the grant cannot live entirely in OpenTofu. A
# google_secret_manager_secret_iam_member needs its secret to exist, and most of
# the platform's secrets are created after the cluster is up -- the OIDC clients
# only after ZITADEL is running inside it. gke/init therefore grants the
# bootstrap prerequisites, and this grants the rest.
#
# Skipping it is not a subtle failure but not an obvious one either: every
# ExternalSecret reports SecretSyncedError, each waiting workload sits in
# CreateContainerConfigError, and the first thing anyone sees is a HelmRelease
# timing out ten minutes later naming only itself.
cmd_grant() {
    [ "$CLOUD" = "gcp" ] || { echo "grant is GCP-only (AWS uses Pod Identity)" >&2; exit 2; }
    [ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }

    local number
    number=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null)
    [ -n "$number" ] || { echo "could not read the project number for ${PROJECT}" >&2; exit 1; }

    local principal="principal://iam.googleapis.com/projects/${number}/locations/global/workloadIdentityPools/${PROJECT}.svc.id.goog/subject/ns/security/sa/external-secrets"

    local keys
    keys=$(kctl get externalsecrets.external-secrets.io -A -o json 2>/dev/null \
        | jq -r '[.items[] | ((.spec.data // [])[]?.remoteRef.key, (.spec.dataFrom // [])[]?.extract.key)]
                 | map(select(. != null)) | unique | .[]')
    [ -n "$keys" ] || { echo "no ExternalSecrets found — is the cluster reachable?"; return 0; }

    local granted=0 absent=0 failed=0
    while read -r key; do
        [ -z "$key" ] && continue
        if ! gcloud secrets describe "$key" --project "$PROJECT" >/dev/null 2>&1; then
            # Not an error here: `check` is what reports missing secrets. A key
            # containing "/" cannot exist in GCP at all -- see ADR-0023.
            echo "[absent ] ${key}"
            absent=$((absent + 1))
            continue
        fi
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] ${key}"
            granted=$((granted + 1))
            continue
        fi
        if gcloud secrets add-iam-policy-binding "$key" --project "$PROJECT" \
             --member "$principal" --role roles/secretmanager.secretAccessor >/dev/null 2>&1; then
            echo "[granted] ${key}"
            granted=$((granted + 1))
        else
            echo "[FAILED ] ${key}"
            failed=$((failed + 1))
        fi
    done <<< "$keys"

    echo
    echo "granted: ${granted}, absent: ${absent}, failed: ${failed}"
    [ "$APPLY" = "true" ] || echo $'\nThis was a DRY RUN. Re-run with --apply.'
    [ "$failed" -eq 0 ]
}

case "$COMMAND" in
    check)       cmd_check ;;
    seed)        cmd_seed ;;
    grant)       cmd_grant ;;
    migrate-aws) cmd_migrate_aws ;;
    *)
        sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
