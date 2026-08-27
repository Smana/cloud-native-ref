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

        # Read and write in one expansion so the value is never written to disk.
        aws_sm create-secret \
            --name "$new" \
            --description "Portable name for ${old}. Copied by scripts/secret-store.sh." \
            --secret-string "$(aws_sm get-secret-value \
                --secret-id "$old" --query SecretString --output text)" >/dev/null
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

case "$COMMAND" in
    check)       cmd_check ;;
    migrate-aws) cmd_migrate_aws ;;
    *)
        sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
