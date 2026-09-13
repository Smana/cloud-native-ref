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
# FLAGS
#
#   --store aws|gcp|openbao
#       Which store to act on. Defaults to the managed store for --cloud, so
#       every invocation that predates this flag behaves exactly as before.
#       `--store openbao` needs VAULT_ADDR, VAULT_CACERT and a token in the
#       environment; it reads no credential from any store.
#
#   lint --cloud aws|gcp [--context CTX]
#       For every key `check` resolves, read the payload and report characters
#       that should not be in a credential -- leading/trailing whitespace and
#       invisibles such as NBSP, zero-width space or a BOM. Read-only, and it
#       never prints a value: only the field name, the character and its offset.
#
#       Needs permission to READ payloads (secretmanager.versions.access /
#       GetSecretValue), which `check` deliberately does not.
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
#   migrate --cloud aws|gcp [--context CTX] [--apply]
#       Copy every mapped key from the cloud managed store into OpenBao, as the
#       store of record (ADR-0033 Stage 2). Dry-run unless --apply. Additive: an
#       existing destination is left alone and the source is never deleted, so
#       it is safe to re-run and safe to stop half-way.
#
#       The key mapping is explicit rather than derived -- see bao_target_for.
#       Anything unmapped is reported and skipped, never guessed: a wrong guess
#       writes a platform secret into an app's prefix, which is a privilege
#       boundary rather than a cosmetic mistake.
#
#       --keys K1,K2,...  walks exactly these managed-store keys instead of the
#       ones the cluster's ExternalSecrets name. Needed once those ExternalSecrets
#       already point at OpenBao: they then name OpenBao paths, which the mapping
#       does not know, and a cluster-derived walk copies nothing. Given with no
#       usable keys (empty, all blank, or an unset variable substituted in),
#       --keys refuses rather than silently falling back to the cluster's
#       ExternalSecrets.
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

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"

CLOUD=""
CONTEXT=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
PROJECT=""
APPLY="false"
KEYS=""          # migrate: explicit managed-store keys; empty = derive from the cluster
KEYS_SET="false" # migrate: was --keys given at all, vs. given but empty
STORE="" # aws|gcp|openbao; defaults to $CLOUD, i.e. that cloud's managed store
COMMAND="${1:-}"
[ $# -gt 0 ] && shift

while [ $# -gt 0 ]; do
    case "$1" in
        --cloud)   CLOUD="$2"; shift 2 ;;
        --context) CONTEXT="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --project) PROJECT="$2"; shift 2 ;;
        --store)   STORE="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        --keys)    KEYS="$2"; KEYS_SET="true"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# The managed store is the default, so every pre-existing invocation of this
# script behaves exactly as it did before `--store` existed.
[ -n "$STORE" ] || STORE="$CLOUD"
case "$STORE" in
    aws | gcp | openbao | "") ;;
    *)
        echo "--store must be aws, gcp or openbao" >&2
        exit 2
        ;;
esac

# kv-v2 reads and writes go through `bao kv`, which takes VAULT_ADDR,
# VAULT_CACERT and a token from the environment -- exactly as the OpenBao
# section of CLAUDE.md documents. This script never reads a token from a store.
bao_kv() {
    bao kv "$@"
}

kctl() {
    if [ -n "$CONTEXT" ]; then kubectl --context "$CONTEXT" "$@"; else kubectl "$@"; fi
}

aws_sm() {
    if [ -n "$REGION" ]; then aws secretsmanager --region "$REGION" "$@"; else aws secretsmanager "$@"; fi
}

gcp_sm() {
    if [ -n "$PROJECT" ]; then gcp_gcloud secrets --project "$PROJECT" "$@"; else gcp_gcloud secrets "$@"; fi
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
    case "$STORE" in
        openbao)
            # kv-v2 metadata is the cheapest existence probe: it answers without
            # reading the value, so this works under a policy that may only list.
            out=$(bao_kv metadata get -format=json "$1" 2>&1) && return 0 || rc=$?
            case "$out" in
                *"No value found"* | *"Code: 404"*) return 1 ;;
            esac
            ;;
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
                # A name GCP cannot even hold -- anything with a "/", which the
                # pre-rename keys in OLD_NAMES all have -- never reaches the
                # Secret Manager API. It fails URL routing first and comes back
                # as an HTML 404, with no NOT_FOUND anywhere in it. That is
                # still absence, not an unreachable store, and treating it as
                # the latter aborted the whole sweep on the first such key.
                *"HTTPError 404"*) return 1 ;;
            esac
            ;;
        *)
            echo "--store must be aws, gcp or openbao" >&2
            exit 2
            ;;
    esac
    echo >&2
    echo "ERROR: could not query the ${STORE} secret store for '$1' (exit ${rc})." >&2
    echo "${out}" | head -3 >&2
    echo >&2
    echo "Refusing to continue: an unreachable store is not an empty one." >&2
    [ "$STORE" = "aws" ] && echo "Hint: pass --region (aws configure get region is empty here)." >&2
    [ "$STORE" = "gcp" ] && echo "Hint: pass --project, or set one with gcp_gcloud config set project." >&2
    [ "$STORE" = "openbao" ] && echo "Hint: VAULT_ADDR, VAULT_CACERT and a token must be in the environment." >&2
    exit 1
}

# Read one key's payload, for `lint`. Same discipline as store_has: an API
# error EXITS rather than being reported as a value.
store_value() {
    local out rc
    case "$STORE" in
        openbao)
            # kv-v2 nests the payload under .data.data; re-emit it as the same
            # flat JSON object the managed stores return, so every caller and
            # `lint` see one shape regardless of store.
            out=$(bao_kv get -format=json "$1" 2>&1) &&
                {
                    printf '%s' "$out" | jq -r '.data.data | tojson'
                    return 0
                } || rc=$?
            ;;
        aws)
            out=$(aws_sm get-secret-value --secret-id "$1" --query SecretString --output text 2>&1) \
                && { printf '%s' "$out"; return 0; } || rc=$?
            ;;
        gcp)
            out=$(gcp_sm versions access latest --secret "$1" 2>&1) \
                && { printf '%s' "$out"; return 0; } || rc=$?
            ;;
        *)
            echo "--store must be aws, gcp or openbao" >&2
            exit 2
            ;;
    esac
    echo >&2
    echo "ERROR: could not read the payload of '$1' from the ${STORE} store (exit ${rc})." >&2
    echo "${out}" | head -3 >&2
    echo >&2
    echo "Refusing to continue: unreadable is not clean." >&2
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

# Report credential material that is shaped wrong, without ever printing it.
#
# WHY THIS EXISTS
#
# app-wizard's GitHub login failed on gcp-0 with nothing to go on: the pod
# logged "oauth exchange failed" and GitHub answered
# incorrect_client_credentials. The client secret in the store was correct --
# except that it began with U+00A0, a non-breaking space picked up pasting it
# out of a browser. 41 characters where GitHub issues 40, and every layer
# between the paste and the failure treats it as an ordinary character:
# Secret Manager stores it, jq round-trips it, base64 hides it, and `kubectl
# get secret -o yaml` renders it as a space.
#
# `check` cannot catch this. A key with a bad value exists, so it reports ok.
#
# The lint never prints a value. It prints the field, the character it found
# and the offset, which is enough to fix a paste and useless to an onlooker.
#
# ONE KNOWN BLIND SPOT: a payload that is a bare string rather than a JSON
# object is read through the cloud CLI, which appends its own newline, so a
# genuine trailing newline in such a value is indistinguishable from the
# CLI's and is not reported. Fields inside a JSON payload -- which is what
# almost every entry in this store is -- are exact.
LINT_JQ='
  def marks: {
    "0":"NUL","9":"TAB","10":"LF","11":"VTAB","12":"FF","13":"CR","32":"SPACE",
    "160":"NBSP U+00A0","173":"SOFT HYPHEN U+00AD","8194":"EN SPACE","8195":"EM SPACE",
    "8199":"FIGURE SPACE","8200":"PUNCTUATION SPACE","8201":"THIN SPACE","8202":"HAIR SPACE",
    "8203":"ZERO-WIDTH SPACE U+200B","8204":"ZWNJ U+200C","8205":"ZWJ U+200D",
    "8232":"LINE SEPARATOR","8233":"PARAGRAPH SEPARATOR","8239":"NARROW NBSP U+202F",
    "8287":"MEDIUM MATH SPACE","8288":"WORD JOINER U+2060","65279":"BOM U+FEFF"
  };
  def probe($name; $v):
    ($v | explode) as $c
    | ($c | length) as $n
    | ([$c[] | select(. == 10)] | length) as $lfs
    | if $n == 0 then ["FAIL\t\($name)\tEMPTY value"]
      else
        [ range(0; $n) as $i
          | {i: $i, code: $c[$i]}
          | select(marks[(.code | tostring)] != null or .code < 32 or .code > 126)
          # A plain space is only a defect at the edges; inside a passphrase it is fine.
          | select(.code != 32 or .i == 0 or .i == ($n - 1))
          # Newlines are the line structure of a multi-line value -- a PEM chain,
          # an RSA private key -- and reporting each one buries the single real
          # finding under fifty. Below two they are still the classic paste
          # defect, and a LEADING one is wrong in any value.
          | select(.code != 10 or $lfs < 2 or .i == 0)
          | (marks[(.code | tostring)] // "control char \(.code)") as $label
          | (if .i == 0 then "LEADING " elif .i == ($n - 1) then "TRAILING " else "" end) as $where
          | if marks[(.code | tostring)] != null or .code < 32
            then {sev: "FAIL", label: $label, msg: "FAIL\t\($name)\t\($where)\($label) at offset \(.i) of \($n)"}
            else {sev: "WARN", label: "non-ASCII", msg: "WARN\t\($name)\tnon-ASCII codepoint \(.code) at offset \(.i) of \($n)"}
            end
        ]
        # One field repeating one defect is one thing to fix, not twenty lines.
        | group_by(.label)
        | map(([.[0:3][].msg]) + (if length > 3 then ["\(.[0].sev)\t\($name)\t... and \(length - 3) more \(.[0].label)"] else [] end))
        | flatten
      end;
  (. | rtrimstr("\n")) as $raw
  | (($raw | fromjson?) // null) as $obj
  | if ($obj | type) == "object"
    then ($obj | to_entries | map(probe(.key; (.value | tostring))) | flatten | .[])
    else (probe("<whole value>"; $raw) | .[])
    end
'

cmd_lint() {
    [ -n "$CLOUD" ] || { echo "--cloud is required" >&2; exit 2; }

    local keys
    keys=$(kctl get externalsecrets.external-secrets.io -A -o json \
        | jq -r '[.items[] | ((.spec.data // [])[]?.remoteRef.key,
                              (.spec.dataFrom // [])[]?.extract.key)]
                 | map(select(. != null)) | unique | .[]')

    if [ -z "$keys" ]; then
        echo "no ExternalSecrets found (is the cluster reachable, and External Secrets installed?)"
        return 0
    fi

    local total=0 absent=0 fails=0 warns=0 report payload
    while read -r key; do
        [ -z "$key" ] && continue
        if ! store_has "$key"; then
            # `check` is what reports missing keys; here it is simply nothing to read.
            absent=$((absent + 1))
            continue
        fi
        total=$((total + 1))
        payload=$(store_value "$key")
        report=$(printf '%s' "$payload" | jq -Rrs "$LINT_JQ")
        [ -z "$report" ] && continue
        while IFS=$'\t' read -r sev field msg; do
            [ -z "$sev" ] && continue
            printf '[%-4s] %-42s %-24s %s\n' "$sev" "$key" "$field" "$msg"
            case "$sev" in
                FAIL) fails=$((fails + 1)) ;;
                WARN) warns=$((warns + 1)) ;;
            esac
        done <<< "$report"
    done <<< "$keys"

    echo
    echo "read ${total} key(s) from the ${CLOUD} store (${absent} absent, not read)."
    if [ "$fails" -gt 0 ]; then
        echo "${fails} field(s) carry a character a credential should not contain, and ${warns} warning(s)."
        echo "Re-copy the value at its source; the surrounding layers will not tell you it is wrong."
        return 1
    fi
    [ "$warns" -gt 0 ] && echo "${warns} warning(s); no failures."
    [ "$warns" -eq 0 ] && echo "no shape problems found."
    return 0
}

# Old AWS name -> portable name. Derived from the repo's own ExternalSecrets:
# every key that contained a slash before the rename.
OLD_NAMES=(
    "apps/openwebui/oauth-zitadel"
    "github/gha-runner-scale-set/default"
    "harbor/admin/password"
    "harbor/valkey/password"
    "headlamp/envvars"
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
    "platform/llm/api-keys"
    "runlore/credentials"
    "runlore/slack-app"
    "runlore/webhook"
    "tailscale/k8s-operator/oauth-client"
    "zitadel/envvars"
)

# Managed-store key -> OpenBao path, for `migrate`.
#
# Explicit rather than derived, because the managed store's names are not
# uniform: ADR-0023 introduced the dash form, slash-form names predate it, and
# the cnpg/* ones are generated by `seed` below rather than curated by a human.
#
# Anything not listed is SKIPPED and reported, never guessed. A wrong guess here
# writes a platform secret into an app's prefix, which is a privilege boundary
# rather than a cosmetic mistake.
#
# Four keys are deliberately absent and must stay so:
#   certificates/*/ca-chain        bootstrap tier -- read before OpenBao is up,
#                                  and the OpenBao-backed store needs the Secret
#                                  it produces, so repointing it is circular
#   cnpg/*  (three of them)        the SQLInstance composition hardcodes
#                                  `secretStoreRef.name: clustersecretstore` and
#                                  its XRD exposes no store field, so the claim
#                                  cannot be repointed -- the same blocker App
#                                  had before crossplane-configuration v0.6.1.
#                                  NOT because a machine writes them: `seed`
#                                  below creates them (they are in GENERATABLE)
#                                  and it is operator-run. Nothing in the
#                                  cluster writes to any secret store.
bao_target_for() {
    case "$1" in
        harbor-admin-password) printf 'platform/harbor/admin-password' ;;
        harbor-oidc) printf 'platform/harbor/oidc' ;;
        harbor-valkey-password) printf 'platform/harbor/valkey-password' ;;
        headlamp-envvars) printf 'platform/headlamp/envvars' ;;
        zitadel-envvars) printf 'platform/zitadel/envvars' ;;
        runlore-credentials) printf 'platform/runlore/credentials' ;;
        runlore-slack-app) printf 'platform/runlore/slack-app' ;;
        runlore-webhook) printf 'platform/runlore/webhook' ;;
        security-flux-ui-oidc) printf 'platform/flux/ui-oidc' ;;
        observability-flux-slack-app) printf 'platform/flux/slack-app' ;;
        observability-victoria-metrics-k8s-stack-grafana-envvars) printf 'platform/victoria-metrics/grafana-envvars' ;;
        observability-victoria-metrics-k8s-stack-alertmanager-slack-app) printf 'platform/victoria-metrics/alertmanager-slack-app' ;;
        tailscale-k8s-operator-oauth-client) printf 'platform/tailscale/operator-oauth-client' ;;
        apps-app-wizard-llm) printf 'apps/app-wizard/llm' ;;
        apps-app-wizard-oauth) printf 'apps/app-wizard/oauth' ;;
        apps/image-gallery/config) printf 'apps/image-gallery/config' ;;
        *) return 1 ;;
    esac
}

# The keys to consider: every key the cluster's ExternalSecrets ask for. Same
# resolution `check` uses, so the two commands can never disagree about what
# the cluster actually consumes.
migrate_source_keys() {
    kctl get externalsecrets -A -o json |
        jq -r '.items[]
                 | ((.spec.data // [])[]?.remoteRef.key,
                    (.spec.dataFrom // [])[]?.extract.key)
                 | select(. != null)' |
        sort -u
}

# The source keys `migrate` walks: an explicit --keys list when given, else the
# keys this cluster's ExternalSecrets ask for. Commas or whitespace separate the
# list; blanks and duplicates are dropped.
#
# --keys given but resolving to zero keys (empty, all blank, or an unset
# variable substituted in) is refused, not silently treated as "no --keys" --
# see the header comment for why.
migrate_keys() {
    if [ "$KEYS_SET" = "true" ]; then
        local keys
        keys="$(printf '%s\n' "$KEYS" | tr ', ' '\n\n' | { grep -v '^$' || true; } | sort -u)"
        if [ -z "$keys" ]; then
            echo "--keys was given but names no key -- refusing rather than falling back to the cluster's ExternalSecrets" >&2
            return 2
        fi
        printf '%s\n' "$keys"
    else
        migrate_source_keys
    fi
}

# Copy every mapped key from the cloud managed store into OpenBao.
#
# Additive and idempotent: a destination that already exists is left alone and
# reported, and the source is never deleted. Removing the migrated managed-store
# entries is a deliberate, separate, manual act with a recovery window.
cmd_migrate() {
    [ -n "$CLOUD" ] || {
        echo "--cloud is required" >&2
        exit 2
    }
    local copied=0 exists=0 skipped=0 absent=0 key target payload
    local keys
    keys="$(migrate_keys)" || exit 2

    printf '%-58s %-46s %s\n' "SOURCE KEY" "OPENBAO PATH" "ACTION"
    while IFS= read -r key; do
        [ -z "$key" ] && continue

        if ! target=$(bao_target_for "$key"); then
            printf '%-58s %-46s %s\n' "$key" "-" "skipped (unmapped)"
            skipped=$((skipped + 1))
            continue
        fi

        STORE="$CLOUD"
        if ! store_has "$key"; then
            printf '%-58s %-46s %s\n' "$key" "$target" "absent at source"
            absent=$((absent + 1))
            continue
        fi
        payload=$(store_value "$key")

        STORE="openbao"
        if store_has "$target"; then
            printf '%-58s %-46s %s\n' "$key" "$target" "exists (left alone)"
            exists=$((exists + 1))
            continue
        fi

        if [ "$APPLY" = "true" ]; then
            # store_create reads the body on stdin; it takes no payload argument.
            printf '%s' "$payload" | store_create "$target"
            printf '%-58s %-46s %s\n' "$key" "$target" "copied"
        else
            printf '%-58s %-46s %s\n' "$key" "$target" "would copy"
        fi
        copied=$((copied + 1))
    done <<<"$keys"

    echo
    echo "copied: ${copied}, exists: ${exists}, absent: ${absent}, skipped: ${skipped}"
    [ "$APPLY" = "true" ] || echo $'\nThis was a DRY RUN. Nothing was written. Re-run with --apply.'
}

cmd_migrate_aws() {
    # migrate-aws is AWS-only by definition. STORE is what store_has and
    # store_create dispatch on; CLOUD stays set because the hint text and the
    # gcp/aws helpers still read it.
    CLOUD="aws"
    STORE="aws"
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
# The two cnpg entries are database credentials the SQLInstance Composition asks
# for, and their separator is cloud-specific for the same reason it is in the
# Composition itself: a GCP Secret Manager ID must match [A-Za-z0-9_-]+, so the
# AWS spelling `cnpg/<instance>/roles/<owner>` names a secret that CANNOT exist
# on GCP. That mismatch shipped, and the symptom named neither the key nor the
# cloud: External Secrets said `could not get secret data from provider` while
# harbor-core sat in CreateContainerConfigError naming a Kubernetes Secret.
# Fixed in crossplane-configuration v0.4.2; seeded here so a rebuild does not
# depend on someone remembering.
_cnpg_sep=$([ "$CLOUD" = "gcp" ] && printf -- "-" || printf -- "/")

GENERATABLE=(
    "harbor-admin-password"
    "harbor-valkey-password"
    "observability-victoria-metrics-k8s-stack-grafana-envvars"
    "cnpg${_cnpg_sep}xplane-harbor${_cnpg_sep}roles${_cnpg_sep}harbor"
    "cnpg${_cnpg_sep}xplane-zitadel${_cnpg_sep}superuser"
    "cnpg${_cnpg_sep}xplane-image-gallery${_cnpg_sep}roles${_cnpg_sep}image-gallery-app"
)

# image-gallery's role credential is listed above unconditionally, like the two
# cnpg entries beside it and for the reason the comment above GENERATABLE gives:
# they are "seeded here so a rebuild does not depend on someone remembering".
#
# It used to be appended under `if [ "$CLOUD" = "aws" ]`, and that was correct
# when written: apps/platform/image-gallery was absent from apps/gcp-0/kustomization.yaml,
# the application reached S3 with the bucket hardcoded in its container
# environment, and so gcp-0 had no image-gallery, no SQLInstance for it and no
# ExternalSecret reading this key. Seeding it there would have created a paid,
# permanently-unread entry.
#
# image-gallery v2 (#2022) made every clause of that false. apps/gcp-0 now
# includes ../platform, the app selects its backend with
# STORAGE_PROVIDER=gcs against a real GCS bucket, and gcp-0 does have both the
# SQLInstance and the ExternalSecret. The stale gate then produced precisely the
# failure the GENERATABLE comment warns about, observed on gcp-0 2026-09-13:
# External Secrets could not read
# `cnpg-xplane-image-gallery-roles-image-gallery-app` while both app replicas
# AND the CNPG initdb pod sat in CreateContainerConfigError naming a Kubernetes
# Secret.
#
# initdb needing it is what makes this a deadlock rather than an ordering
# problem, and the distinction is worth keeping: CNPG cannot seed a credential
# it requires in order to start, so nothing converges on its own.
#
# `seed_body` needed no change -- its case pattern is
# `cnpg?xplane-image-gallery?roles?image-gallery-app`, where `?` matches either
# separator, so the generator half was cloud-agnostic all along. Only this list
# excluded GCP. Note the ORDER MATTERS warning in that arm: CNPG fixes the role
# password when it CREATES the cluster, so seed before the claim reconciles.

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
#
# Every generated/derived password goes into jq on STDIN via `-Rs`, never as
# --arg -- --arg puts it on jq's argv, readable by any process on the box via
# /proc/<pid>/cmdline for as long as jq runs. Same class of leak closed in
# zitadel-idp.sh and zitadel-oidc-clients.sh; this is the same fix applied to
# every password this function seeds.
seed_body() {
    case "$1" in
        harbor-admin-password)
            printf '%s' "$(gen_password)" | jq -Rs '{password: .}' ;;
        harbor-valkey-password)
            printf '%s' "$(gen_password)" | jq -Rs '{REDIS_PASSWORD: .}' ;;
        observability-victoria-metrics-k8s-stack-grafana-envvars)
            printf '%s' "$(gen_password)" | jq -Rs \
                '{GF_SECURITY_ADMIN_USER: "admin", GF_SECURITY_ADMIN_PASSWORD: .}' ;;
        # Globs, so one arm serves both spellings: `cnpg/...` on AWS and
        # `cnpg-...` on GCP. The username is not decoration -- the ExternalSecret
        # reads `property: username` as well as `password`, so a body carrying
        # only a password syncs a Secret missing a key the workload mounts.
        cnpg?xplane-harbor?roles?harbor)
            # Must match spec.roles[].name on the claim: CNPG creates the role
            # under that name and Harbor connects as it.
            printf '%s' "$(gen_password)" | jq -Rs '{username: "harbor", password: .}' ;;
        cnpg?xplane-image-gallery?roles?image-gallery-app)
            # Same shape as harbor above, and the username is again load-bearing:
            # `image-gallery-app` is spec.sqlInstance.roles[].name in
            # apps/platform/image-gallery/app.yaml, and also the `owner` of the
            # image-gallery database there.
            #
            # GENERATED, not derived -- unlike the zitadel arm below, this
            # credential has exactly one owner. The claim carries `backup` but no
            # `recovery`, so the database is always created fresh and a new
            # password each rebuild is correct rather than merely tolerable.
            # (The zitadel arm's ORDER MATTERS warning still applies: CNPG sets
            # the role password when it CREATES the cluster, so seed before the
            # claim reconciles.)
            printf '%s' "$(gen_password)" | jq -Rs '{username: "image-gallery-app", password: .}' ;;
        cnpg?xplane-zitadel?superuser)
            # DERIVED, not generated -- the one arm here that reads rather than
            # rolls, and the reason is that this credential has two owners.
            #
            # ZITADEL authenticates as `postgres` using
            # ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD out of the zitadel-envvars
            # blob. CNPG sets the `postgres` role's password from THIS secret,
            # because the cluster carries enableSuperuserAccess: true alongside
            # an explicit superuserSecret. Two secrets, one credential. Generate
            # a fresh value here and they disagree by construction, on every
            # cluster, forever -- which is exactly what happened on gcp-0 on
            # 2026-08-28: `zitadel init` failed `password authentication failed
            # for user "postgres"`, waited out its 5m AWAITINITIALCONN, and the
            # Job's 300s activeDeadlineSeconds killed it. On repeat. The symptom
            # is a HelmRelease stuck on a pre-install hook and a Job whose pod is
            # deleted before anyone can read its logs.
            #
            # So zitadel-envvars is the single source and this is a copy of it.
            #
            # ORDER MATTERS, and it is not enforceable from here: CNPG applies
            # this password when it CREATES the cluster and does not rewrite the
            # role afterwards. Seed before the SQLInstance claim reconciles, or
            # the database keeps whatever password it was born with and no amount
            # of fixing the secret afterwards reaches it.
            local _admin
            _admin=$(store_value "zitadel-envvars" 2>/dev/null \
                | jq -r '.ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD // empty')
            if [ -z "$_admin" ]; then
                echo "cannot derive $1: zitadel-envvars is absent or has no" >&2
                echo "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD. Load that blob first --" >&2
                echo "generating a password here would silently disagree with it." >&2
                return 1
            fi
            printf '%s' "$_admin" | jq -Rs '{username: "postgres", password: .}' ;;
        *)
            echo "no generator for $1" >&2; return 1 ;;
    esac
}

# Create one secret from a JSON body on stdin. Never overwrites: callers check
# first, and both APIs below are create-only.
store_create() {
    case "$STORE" in
        openbao)
            # `-` makes `bao kv put` read a JSON object from stdin, which is the
            # same contract the gcp arm's --data-file=- uses. kv-v2 wraps it
            # under data/ on the way in, so store_value's unwrap is the inverse.
            bao_kv put "$1" - >/dev/null
            ;;
        aws)
            # `--cli-input-json file:///dev/stdin` CANNOT work: the AWS CLI opens
            # and seeks the path it is given, and a pipe supports neither. It
            # fails with "Error parsing parameter 'cli-input-json': Invalid JSON
            # received." -- naming the JSON rather than the plumbing, which is
            # why it read as a payload bug. `seed --apply` could therefore never
            # create an AWS secret, and nothing noticed because the two entries
            # that need it are only reached on a from-scratch rebuild.
            #
            # A real temp file instead of the payload on argv: `--secret-string`
            # would put the credential in the process table for every user on
            # the host. mktemp is 0600 by default; the trap covers `set -o
            # errexit` bailing out before the rm.
            local tmp
            tmp=$(mktemp)
            # shellcheck disable=SC2064  # expand tmp now, not at trap time
            trap "rm -f '$tmp'" RETURN
            cat >"$tmp"
            aws_sm create-secret \
                --name "$1" \
                --description "Generated by scripts/secret-store.sh seed." \
                --secret-string "file://$tmp" >/dev/null
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
    number=$(gcp_gcloud projects describe "$PROJECT" --format='value(projectNumber)' 2>/dev/null)
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
        if ! gcp_gcloud secrets describe "$key" --project "$PROJECT" >/dev/null 2>&1; then
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
        if gcp_gcloud secrets add-iam-policy-binding "$key" --project "$PROJECT" \
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
    lint)        cmd_lint ;;
    seed)        cmd_seed ;;
    grant)       cmd_grant ;;
    migrate) cmd_migrate ;;
    migrate-aws) cmd_migrate_aws ;;
    *)
        sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
