#!/usr/bin/env bash
#
# Register this cluster's OIDC clients in ZITADEL, and store the credentials.
#
# WHY THIS EXISTS
#
# Every SSO consumer on the platform -- Grafana, Headlamp, the Flux UI -- needs
# an OIDC client whose redirect URI names THAT cluster's hostnames. The clients
# are therefore per-cluster, and since ADR-0024 made the identity provider
# deployable on either cloud, there can be two sets of them.
#
# Creating two sets by hand in a console is how they drift, and a drifted
# redirect URI fails at login with an error that names neither the cluster nor
# the client. It is also a bootstrap blocker rather than a nicety: Headlamp's
# chart mounts `headlamp-envvars` and the pod sits in CreateContainerConfigError
# until that secret exists, so a cluster with no registered clients has a
# permanently unready Kustomization.
#
# WHAT IT DOES
#
#   1. Reads the ZITADEL admin PAT from the cluster's own secret store.
#   2. Ensures a project exists to hold the apps.
#   3. For each consumer, creates the OIDC app if it is missing (never
#      recreates one that exists -- recreating rotates the secret and breaks a
#      running cluster).
#   4. Writes the client id and secret into the store under the key the
#      consumer's ExternalSecret reads.
#   5. Points OpenBao's own auth/oidc at the client id ZITADEL just issued for
#      it (--openbao-url and friends; #2045). A rebuild restores ZITADEL from
#      a seed that predates the app, so its id is new every time and
#      Terraform, which created the mount, ignores this field afterwards.
#      No-op when --openbao-url is empty, which is every consumer call.
#   6. Restarts the Deployments that read a REPLACED client id from env, once
#      their Secret carries the new one (restart_rotated_consumers).
#
# Step 4 MERGES rather than overwrites where a secret holds more than OIDC:
# grafana-envvars also carries the generated admin credentials, and clobbering
# them would lock the operator out of Grafana.
#
# Usage:
#   # a cluster that HOSTS its own identity provider
#   zitadel-oidc-clients.sh sync --cluster gcp-0 --cloud gcp [--project ID] [--apply]
#     [--openbao-url U --openbao-root-token-secret S --openbao-ca-file F [--mirror-openbao]]
#     [--grant-admin EMAIL] [--grant ROLE=EMAIL ...]
#   zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws [--region R]  [--apply]
#
#   # a SECONDARY cluster consuming the primary cloud's identity provider:
#   # admin PAT read from AWS's store (never kubectl), client secrets into GCP,
#   # kubectl pointed at gcp-0 for its vars ConfigMap's audience scope.
#   IDP_URL=https://auth.cloud.ogenki.io PRIVATE_DOMAIN=priv.gcp.ogenki.io \
#     zitadel-oidc-clients.sh sync --cluster gcp-0 \
#       --cloud gcp --project ID --idp-cloud aws --region eu-west-3 --apply
#
# On the HOSTING cloud the PAT is resolved from kubectl's cluster and overwrites
# the stored one (GP-20), so kubectl must point at the hosting cluster: a
# leftover security/iam-admin-pat anywhere else would replace that cloud's PAT.
#
# Dry-run unless --apply. Client secrets are never printed: ZITADEL returns a
# client secret exactly once, at creation, so it goes straight from the API
# response into the secret store.

set -o errexit
set -o nounset
set -o pipefail

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/../lib/gcloud-adc.sh"
# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "$0")/../lib/cloud-secret-store.sh"
# shellcheck source=scripts/lib/zitadel-pat.sh
. "$(dirname "$0")/../lib/zitadel-pat.sh"
# shellcheck source=scripts/lib/openbao-api.sh
. "$(dirname "$0")/../lib/openbao-api.sh"
# shellcheck source=scripts/lib/bao-map.sh
. "$(dirname "$0")/../lib/bao-map.sh"

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

CLUSTER=""
CLOUD=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GCP_PROJECT=""
APPLY="false"
# Empty means "this platform has no workforce pool" -- the reconciliation below
# is then skipped entirely, which is the correct behaviour on AWS-only setups.
WORKFORCE_POOL=""
ZITADEL_PROJECT_NAME="platform"

# The project roles the platform's OWN RBAC already refers to. These are not a
# guess: each name is read back out of a manifest in this repo, through the
# groups/roles claim that zitadel-actions/groups-from-roles.js builds.
#
#   admin      security/base/rbac/admin.yaml   Group admin    -> cluster-admin
#              flux-ui ClusterRoleBinding       Group admin    -> cluster-admin
#              Grafana role_attribute_path      'admin'        -> Admin
#   backend    flux-ui ClusterRoleBinding       Group backend  -> edit
#              Grafana role_attribute_path      'backend'      -> Editor
#   data       flux-ui ClusterRoleBinding       Group data     -> edit
#              Grafana role_attribute_path      'data'         -> Editor
#   frontend   Grafana role_attribute_path      'frontend'     -> Editor
#
# `agents-admin` is owner and approver in every room; `agents-member` watches
# every room (SP2 §1 Groups).
#
# Without them the whole chain is inert: ZITADEL has no role to grant, so the
# Action emits no claim, so every binding above matches nobody and Grafana falls
# through to Viewer. gcp-0 came up on 2026-08-28 with zero roles on the project
# and nothing anywhere said so -- login worked, authorisation silently did not.
ZITADEL_PROJECT_ROLES=(admin backend frontend data agents-admin agents-member)

# --grant-admin <email>: give an EXISTING user the `admin` project role.
#
# Separate from role creation because the two cannot happen at the same time. A
# human user does not exist in ZITADEL until their FIRST LOGIN -- the Google IdP
# auto-creates them -- so there is nobody to grant to at bootstrap. The sequence
# is unavoidably: register clients -> configure the IdP -> log in once -> grant.
#
# It is here rather than in a console because a role granted by hand is a role
# nobody can reproduce, which is how gcp-0 ended up with no groups claim at all.
GRANT_ADMIN=""
# --grant <role>=<email>, repeatable: any project role, same constraint. gcp-0
# mints a fresh ZITADEL every build, so its grants are re-run after each one.
GRANTS=()

# Empty means reconcile_openbao_oidc is a no-op: the consumer call on a
# secondary cluster. A cluster hosting its own directory (aws-0's stage 4,
# gcp-0's hosting stage 3) passes all three.
OPENBAO_URL=""
OPENBAO_ROOT_TOKEN_SECRET=""
OPENBAO_CA_FILE=""
# --mirror-openbao: also write each consumer secret to the OpenBao path its
# ExternalSecret reads. Only gcp-0's own sync sets it (GCP parity GP-5): a fresh
# directory re-registers every client on every build, and gcp-0 reads OpenBao.
MIRROR_OPENBAO="false"

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --cloud)   CLOUD="$2"; shift 2 ;;
        --idp-cloud) IDP_CLOUD="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        --grant-admin) GRANT_ADMIN="$2"; shift 2 ;;
        --grant) GRANTS+=("$2"); shift 2 ;;
        --workforce-pool) WORKFORCE_POOL="$2"; shift 2 ;;
        --openbao-url) OPENBAO_URL="$2"; shift 2 ;;
        --openbao-root-token-secret) OPENBAO_ROOT_TOKEN_SECRET="$2"; shift 2 ;;
        --openbao-ca-file) OPENBAO_CA_FILE="$2"; shift 2 ;;
        --mirror-openbao) MIRROR_OPENBAO="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$CLUSTER" ] || { echo "--cluster is required" >&2; exit 2; }
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac

# A URL with no way to verify OpenBao's certificate or read its root token is
# a wiring bug, not something to fall back from quietly -- TLS is never
# skipped (openbao-api.sh), so an unreadable/missing CA file is refused here
# rather than surfacing later as every reconcile_openbao_oidc call failing.
if [ -n "$OPENBAO_URL" ]; then
    [ -n "$OPENBAO_ROOT_TOKEN_SECRET" ] || { echo "--openbao-url requires --openbao-root-token-secret" >&2; exit 2; }
    [ -n "$OPENBAO_CA_FILE" ] || { echo "--openbao-url requires --openbao-ca-file" >&2; exit 2; }
    [ -f "$OPENBAO_CA_FILE" ] || { echo "--openbao-ca-file ${OPENBAO_CA_FILE} not found" >&2; exit 2; }
fi
if [ "$MIRROR_OPENBAO" = "true" ] && [ -z "$OPENBAO_URL" ]; then
    echo "--mirror-openbao requires --openbao-url" >&2; exit 2
fi
# Refused here, before the PAT resolve can write: a typo'd role would otherwise
# surface only as a ZITADEL 400 after the project was touched.
for g in "${GRANTS[@]+"${GRANTS[@]}"}"; do
    case "$g" in
        ?*=?*) printf '%s\n' "${ZITADEL_PROJECT_ROLES[@]}" | grep -qxF -- "${g%%=*}" \
                   || { echo "--grant takes <role>=<email> with one of: ${ZITADEL_PROJECT_ROLES[*]}; got '${g}'" >&2; exit 2; } ;;
        *) echo "--grant takes <role>=<email>; got '${g}'" >&2; exit 2 ;;
    esac
done

# Which cloud's secret store holds the ZITADEL ADMIN PAT, as opposed to which
# one receives the client secrets this script writes. They are the same cloud
# whenever a cluster hosts its own identity provider, so this defaults to
# --cloud and every existing invocation is unchanged.
#
# They differ in exactly one case, and it is the one ADR-0027 makes normal:
# a SECONDARY cluster consuming the primary cloud's ZITADEL. Registering
# gcp-0's clients into aws-0's directory needs the admin PAT from AWS and the
# resulting client secrets in GCP, because that is where gcp-0's
# ExternalSecrets read. One flag could not express that, which is why nothing
# registered a consuming cluster's clients and its oauth2-proxy came up with
# no secret at all.
IDP_CLOUD="${IDP_CLOUD:-$CLOUD}"
case "$IDP_CLOUD" in aws|gcp) ;; *) echo "--idp-cloud must be aws or gcp" >&2; exit 2 ;; esac

# App names are per-CONSUMER (`harbor`, `grafana`, ...), which is unambiguous
# only while one directory serves one cluster. It no longer does: ADR-0027 makes
# a secondary cluster CONSUMING the primary's directory the normal arrangement,
# and then two clusters want an app called `harbor` in the same project.
#
# Caught by a dry run on 2026-09-02, before anything was written:
#
#   [STALE  ] harbor  has:  https://harbor.priv.aws.ogenki.io/c/oidc/callback
#                     want: https://harbor.priv.gcp.ogenki.io/c/oidc/callback
#   created: 0, updated: 5
#
# Registering gcp-0 would not have created gcp-0's clients -- it would have
# rewritten aws-0's redirect URIs to gcp-0's hostnames and broken SSO on the
# cluster that hosts the directory.
#
# So a CONSUMING cluster's apps are suffixed with its cluster name. The hosting
# cluster's are not, deliberately: its apps already exist under bare names, they
# are carried in the database restore seed, and renaming them would orphan the
# originals on every restore while rotating secrets on a running cluster.
# Asymmetric, and the asymmetry is the point -- the host owns the plain names.
if [ "$IDP_CLOUD" != "$CLOUD" ]; then
    APP_SUFFIX="-${CLUSTER}"
else
    APP_SUFFIX=""
fi

# Provenance for secrets this script writes, read by cloud-secret-store.sh's
# store_write. Preserves what this script wrote before the store/PAT logic
# moved into shared libraries.
STORE_WRITE_DESCRIPTION="OIDC client for ${CLUSTER}. Written by zitadel-oidc-clients.sh."
STORE_WRITE_LABEL="zitadel-oidc-clients"

# ── zitadel api ───────────────────────────────────────────────────────────────

# zitadel-pat.sh's OWN dry-run signal, set before calling it rather than
# trusting it to read this script's $APPLY by accidental name-matching.
# resolve_zitadel_pat persists a freshly-read PAT into the cloud secret store
# the first time it sees one -- a WRITE, which breaks this script's own header
# promise ("Dry-run unless --apply.") on a plain sync. Confirmed live: a sync
# with no --apply created zitadel/iam-admin-pat in Secrets Manager anyway.
ZITADEL_PAT_DRY_RUN="true"
[ "$APPLY" = "true" ] && ZITADEL_PAT_DRY_RUN="false"

# zitadel-pat.sh and cloud-secret-store.sh both dispatch on the GLOBAL $CLOUD,
# so the PAT is read with $CLOUD temporarily pointed at the IdP's cloud and the
# value restored immediately afterwards -- every write below then lands in the
# target cluster's store, which is the whole point of the split. $REGION and
# $GCP_PROJECT need no swap: each is only read by its own cloud's branch, so
# both can be supplied at once.
#
# A hosting sync reads the PAT from its own cluster's chart Secret first (GP-20).
# A consuming one (--idp-cloud differs) reads only the IdP cloud's store: its
# kube context is its own cluster, not the one that runs ZITADEL.
#
# The IdP base URL. Derived the same way the platform derives it, so a mismatch
# here is a mismatch everywhere. Checked before the PAT resolve, which can write.
: "${IDP_URL:?set IDP_URL to the ZITADEL base URL, e.g. https://auth.gcp.cloud.ogenki.io}"
: "${PRIVATE_DOMAIN:?set PRIVATE_DOMAIN, e.g. priv.gcp.ogenki.io}"

_pat_role="hosting"
[ "$IDP_CLOUD" = "$CLOUD" ] || _pat_role="consuming"
_target_cloud="$CLOUD"
CLOUD="$IDP_CLOUD"
PAT="$(resolve_zitadel_pat "$_pat_role")" || exit 1
CLOUD="$_target_cloud"

# Optional escape hatch for split-DNS workstations. The IdP hostname is public,
# but a machine on the tailnet may resolve *.ogenki.io through a resolver that
# has not picked up a freshly created record -- 8.8.8.8 answers while the system
# resolver still returns NXDOMAIN from its negative cache. Setting
# IDP_RESOLVE=host:443:<ip> pins it for curl only, keeping SNI and certificate
# verification intact (unlike hitting the IP with a Host header).
#
#   IDP_RESOLVE=auth.gcp.cloud.ogenki.io:443:34.158.159.130
CURL_RESOLVE=()
[ -n "${IDP_RESOLVE:-}" ] && CURL_RESOLVE=(--resolve "$IDP_RESOLVE")

# The admin PAT never touches argv. `-H "Authorization: Bearer ${PAT}"` would
# put the live token in `ps`/`/proc/<pid>/cmdline` for as long as every curl
# process runs -- the same vulnerability class this repo already closed for
# jq --arg/--argjson (test-no-secret-argv.sh). curl has no stdin form for a
# header, so it goes into a `-K` config file instead, created once for this
# run:
#
#   * `umask 077 && mktemp` sets the mode AT CREATION -- creating the file and
#     chmod-ing it afterward leaves a window where it is world-readable.
#   * the path is baked into the trap STRING at trap-SET time
#     (`trap "rm -f '$path'" EXIT`), not left to expand when the trap fires.
#     Under `nounset`, a trap that expands the variable at fire time dies on
#     "unbound variable" if the variable is ever unset before it fires, and
#     cleans up nothing -- the exact bug just fixed in cloud-secret-store.sh's
#     store_write; same fix, same reasoning, applied here to the config file
#     itself rather than to a value merely passing through it.
#   * `"` and `\` in the token are escaped for curl's config-file syntax,
#     where both are otherwise significant.
API_CURL_CONFIG="$(umask 077 && mktemp -t zitadel-api-curl.XXXXXX)"
# shellcheck disable=SC2064
trap "rm -f '$API_CURL_CONFIG'" EXIT
pat_escaped="${PAT//\\/\\\\}"
pat_escaped="${pat_escaped//\"/\\\"}"
printf 'header = "Authorization: Bearer %s"\n' "$pat_escaped" > "$API_CURL_CONFIG"
unset pat_escaped

api() {
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" "${IDP_URL}${path}" \
        -K "$API_CURL_CONFIG" \
        ${CURL_RESOLVE[@]+"${CURL_RESOLVE[@]}"} \
        -H "Content-Type: application/json" \
        "$@"
}

# Wrap a READ-only api() call: on failure, print a diagnostic and return 1
# instead of letting the caller treat curl's empty stdout as "nothing found".
#
# THE DEFECT THIS CLOSES: ensure_project's id lookup used to be
# `id=$(api ... | jq ... | head -1)`. When the API call failed (403/404/
# network), the pipeline's non-zero exit did NOT stop the script: `head -1`
# absorbs pipefail's view of curl's exit code, and even without it, errexit
# does not reliably fire on a failing assignment buried two command-
# substitution levels deep -- which this one was, since ensure_project itself
# is called as `project_id="$(ensure_project)"`. `id` ended up empty either
# way, indistinguishable from "the project genuinely does not exist", and
# ensure_project fell through to its DRYRUN-PROJECT sentinel -- printing a
# clean plan while a 404 sat in the terminal right above it. Observed live:
#   curl: (22) The requested URL returned error: 404
#   created: 5, updated: 0, unchanged: 0
#
# Every _search/GET call in this script goes through this rather than the
# `2>/dev/null`/`|| true` each used to swallow the same class of failure.
# Testing the exit code explicitly works regardless of how many command
# substitutions deep the call sits, which is what makes it reliable where
# errexit alone was not.
api_or_fail() {
    local resp
    if ! resp="$(api "$@" 2>&1)"; then
        echo "[FAILED ] ZITADEL API call failed: ${1:-} ${2:-}" >&2
        echo "           ${resp}" >&2
        echo "           Likely cause: the iam-admin machine user lacks ORG_OWNER" >&2
        echo "           on this org (IAM_OWNER for an /admin/v1 call), or IDP_URL" >&2
        echo "           / the admin PAT is stale -- NOT the same thing as the" >&2
        echo "           object being searched for not existing yet." >&2
        return 1
    fi
    printf '%s' "$resp"
}

# ── the consumers ─────────────────────────────────────────────────────────────
#
# name | redirect URI | secret key it lands in | [type: jwt, native, else bearer]
#
# native: a public client (no secret) on the device flow, with JWT access tokens.
#
# Redirect paths are each framework's own callback and are not interchangeable:
#   Grafana   /login/generic_oauth   (grafana.ini auth.generic_oauth)
#   Headlamp  /oidc-callback         (headlamp chart)
#   Flux UI   /oauth2/callback       (flux-operator web.config.authentication)
# ${APP_SUFFIX} is empty for the cluster that HOSTS this directory and
# "-<cluster>" for one consuming it, so two clusters never contend for the same
# app name. The secret KEYS are deliberately not suffixed: they are per-cluster
# already, living in that cluster's own secret store.
CONSUMERS=(
  "grafana|https://grafana.${PRIVATE_DOMAIN}/login/generic_oauth|observability-victoria-metrics-k8s-stack-grafana-envvars"
  "headlamp|https://headlamp.${PRIVATE_DOMAIN}/oidc-callback|headlamp-envvars"
  "flux-ui|https://flux-ui-${CLUSTER}.${PRIVATE_DOMAIN}/oauth2/callback|security-flux-ui-oidc"
  # gcp-0 only in practice, and harmless on aws-0 where nothing consumes it.
  # GKE cannot be told to trust ZITADEL, so Headlamp there sits behind
  # oauth2-proxy and the PROXY holds the OIDC client -- a second client for the
  # same hostname, on the proxy's own callback path. ADR-0026.
  "headlamp-proxy|https://headlamp.${PRIVATE_DOMAIN}/oauth2/callback|headlamp-oauth2-proxy"
  # Harbor's callback is /c/oidc/callback -- Harbor's own path, not guessable
  # from the others. No second imperative step applies it: Harbor stores
  # auth config in its DATABASE rather than in the chart, but the chart's
  # core.configureUserSettings renders CONFIG_OVERWRITE_JSON, which Harbor
  # writes to that database itself at startup and then locks read-only. The
  # client id/secret this script writes to the "harbor-oidc" store key reach
  # the HelmRelease via an ExternalSecret + valuesFrom, same as every other
  # consumer here. See ADR-0028.
  "harbor|https://harbor.${PRIVATE_DOMAIN}/c/oidc/callback|harbor-oidc"
  # OpenBao is the only TWO-callback consumer here, and both are required
  # (ADR-0034). The UI path embeds the auth method's MOUNT PATH twice --
  # /ui/vault/auth/<mount>/oidc/callback -- so mounting the method anywhere but
  # `oidc` silently invalidates this URI; auth.tf pins that mount and says so.
  # The loopback is what the CLI's `bao login -method=oidc` sends the browser
  # back to; port 8250 is the OpenBao default and is not configurable per-role.
  #
  # `bao.` rather than `openbao.`: operators reach it over the tailnet at the
  # NLB's DNS name, which is what the server certificate carries.
  "openbao|https://bao.${PRIVATE_DOMAIN}:8200/ui/vault/auth/oidc/oidc/callback,http://localhost:8250/oidc/callback|openbao-oidc"
  # SP2: the room broker's oauth2-proxy. JWT access tokens, so the broker and
  # SP3's factory validate them offline (C4). agent-system reads only OpenBao's
  # agents mount (C1, P38): --mirror-openbao copies the key there through
  # bao-map.sh (ruling AU). No ExternalSecret reads the store's copy.
  "rooms-proxy|https://rooms.${PRIVATE_DOMAIN}/oauth2/callback|agents-rooms-proxy|jwt"
  # SP2 phase 6: roomctl, a developer's CLI. Device flow, so no secret exists to
  # leak and no redirect reaches the laptop (the loopback URI is ZITADEL's
  # required one, never used). Its id is not a credential, but the broker,
  # oauth2-proxy and SP3's factory all need it (ruling P12).
  "roomctl|http://localhost:8765/callback|agents-roomctl|native"
)

# The one non-secret OIDC field known to have drifted in practice: headlamp
# needs `groups` in scope to get a groups claim at all, without which it can
# authorize nobody. A single named source of truth for both merge_secret
# (new app) and converge_secret (existing app, below) -- defect 4 was two
# independent copies of this exact literal, one corrected by hand on
# 2026-08-29 and the other never reached because nothing wrote to an existing
# app's stored secret at all.
HEADLAMP_OIDC_SCOPES="profile,email,groups"

# Roles are additive and idempotent: ZITADEL rejects a duplicate roleKey, so an
# existing role is left alone rather than rewritten. Granting a role to a USER is
# deliberately NOT done here -- a user exists only after their first login, and
# guessing who should be admin is not this script's business.
ensure_project_roles() {
    local project_id="$1" role existing
    [ -n "$project_id" ] || return 0

    if [ "$project_id" = "DRYRUN-PROJECT" ]; then
        echo "[dry-run] would ensure roles: ${ZITADEL_PROJECT_ROLES[*]}"
        return 0
    fi

    local resp
    resp="$(api_or_fail POST "/management/v1/projects/${project_id}/roles/_search" -d '{"query":{"limit":100}}')" || return 1
    existing="$(jq -r '.result[]?.key' <<< "$resp")"

    for role in "${ZITADEL_PROJECT_ROLES[@]}"; do
        if grep -qx "$role" <<< "$existing"; then
            echo "[skip   ] role '${role}' already exists"
            continue
        fi
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] would create role '${role}'"
            continue
        fi
        jq -n --arg k "$role" --arg d "$role" '{roleKey: $k, displayName: $d}' \
            | api POST "/management/v1/projects/${project_id}/roles" -d @- >/dev/null
        echo "[created] role '${role}'"
    done
}

ensure_project() {
    local id resp
    resp="$(api_or_fail POST /management/v1/projects/_search -d '{"queries":[]}')" || return 1
    id=$(jq -r --arg n "$ZITADEL_PROJECT_NAME" \
             '.result[]? | select(.name == $n) | .id' <<< "$resp" | head -1)
    if [ -n "$id" ]; then
        echo "$id"
        return 0
    fi
    if [ "$APPLY" != "true" ]; then
        echo "DRYRUN-PROJECT"
        return 0
    fi
    resp="$(api_or_fail POST /management/v1/projects -d "$(jq -n --arg n "$ZITADEL_PROJECT_NAME" \
        '{name:$n, projectRoleAssertion:true}')")" || return 1
    id="$(jq -r '.id // empty' <<< "$resp")"
    if [ -z "$id" ]; then
        echo "[FAILED ] project creation returned no id: $(jq -c '.' <<< "$resp" | head -c 200)" >&2
        return 1
    fi
    echo "$id"
}

# Every page of a v1 _search, as one {result: [...]}. ZITADEL returns at most
# `limit` per call: a user or grant past the first page would be unseen, and a
# second POST for an existing grant is refused. Bounded, so a server that ignores
# the offset fails loudly instead of paging forever.
search_all() {
    local path="$1" offset=0 pages=0 page n all='[]'
    while :; do
        page="$(api_or_fail POST "$path" -d "{\"query\":{\"offset\":\"${offset}\",\"limit\":200,\"asc\":true}}")" || return 1
        n="$(jq '.result // [] | length' <<< "$page")" || return 1
        all="$(printf '%s\n%s\n' "$all" "$page" | jq -cs '.[0] + (.[1].result // [])')" || return 1
        [ "$n" -lt 200 ] && break
        offset=$((offset + n)); pages=$((pages + 1))
        if [ "$pages" -ge 50 ]; then
            echo "[FAILED ] ZITADEL listing ${path} did not end after ${pages} pages" >&2; return 1
        fi
    done
    jq -c '{result: .}' <<< "$all"
}

# Give an EXISTING user a project role. A user already holding a grant on this
# project gets the role ADDED to it: ZITADEL refuses a second grant for the same
# user and project, so POSTing again would fail for anyone who already has one.
# cmd_sync calls this under `||`, which turns errexit off in here: every call
# whose failure matters is checked explicitly.
grant_role() {
    local role="$1" email="$2" project_id="$3" user_id resp grant
    [ -n "$email" ] && [ -n "$project_id" ] || return 0
    if [ "$project_id" = "DRYRUN-PROJECT" ]; then
        echo "[dry-run] would grant '${role}' to ${email}"; return 0
    fi
    resp="$(search_all /management/v1/users/_search)" || return 1
    user_id="$(jq -r --arg e "$email" '.result[]? | select((.userName == $e) or (.human.email.email == $e)) | .id' <<< "$resp" | head -1)" || return 1
    if [ -z "$user_id" ]; then
        echo "[FAILED ] no ZITADEL user for ${email}: they must log in once first" >&2; return 1
    fi
    resp="$(search_all /management/v1/users/grants/_search)" || return 1
    grant="$(jq -c --arg u "$user_id" --arg p "$project_id" '[.result[]? | select(.userId == $u and .projectId == $p)][0] // empty' <<< "$resp")" || return 1
    if [ -n "$grant" ] && jq -e --arg r "$role" '.roleKeys | index($r)' <<< "$grant" >/dev/null; then
        echo "[skip   ] ${email} already holds '${role}'"; return 0
    fi
    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would grant '${role}' to ${email}"; return 0
    fi
    if [ -n "$grant" ]; then
        jq -c --arg r "$role" '{roleKeys: ((.roleKeys // []) + [$r] | unique)}' <<< "$grant" \
            | api PUT "/management/v1/users/${user_id}/grants/$(jq -r .id <<< "$grant")" -d @- >/dev/null \
            || { echo "[FAILED ] could not add '${role}' to ${email}'s grant" >&2; return 1; }
    else
        jq -n --arg p "$project_id" --arg r "$role" '{projectId: $p, roleKeys: [$r]}' \
            | api POST "/management/v1/users/${user_id}/grants" -d @- >/dev/null \
            || { echo "[FAILED ] could not grant '${role}' to ${email}" >&2; return 1; }
    fi
    echo "[granted] '${role}' to ${email}"
}

# "Assert Roles on Authentication", and it is the flag every SSO consumer on this
# platform silently depends on.
#
# ZITADEL defaults it to FALSE. With it off, project roles are attached to NO
# token -- and the damage is not limited to the standard roles claim:
# `ctx.v1.user.grants` is EMPTY inside a token action, so
# zitadel-actions/groups-from-roles.js takes its no-grants early return and never
# sets `groups` or `roles` at all. The action still logs "action run succeeded".
#
# On 2026-08-28 that one flag produced three unrelated-looking failures:
#
#   Flux UI   failed to evaluate the CEL expression 'claims.groups':
#             no such key: groups
#   Headlamp  [AuthFailure] Invalid authentication via OAuth2: unauthorized
#             (oauth2-proxy's --allowed-group=admin matching nothing)
#   Grafana   every user silently landing on the Viewer fallback
#
# Every other setting looked right: the user held an ACTIVE admin grant on this
# project, the project was in the token's `aud`, and all five apps had
# idTokenUserinfoAssertion and idTokenRoleAssertion true. None of that matters
# while the project itself refuses to assert roles.
#
# Set on an EXISTING project too, not only at creation -- gcp-0's was created
# before this was understood, and a project that predates this function must be
# repaired rather than left to a manual console click nobody remembers.
ensure_project_role_assertion() {
    local project_id="$1" current resp
    [ -n "$project_id" ] || return 0
    [ "$project_id" = "DRYRUN-PROJECT" ] && { echo "[dry-run] would ensure projectRoleAssertion=true"; return 0; }

    resp="$(api_or_fail GET "/management/v1/projects/${project_id}")" || return 1
    current="$(jq -r '.project.projectRoleAssertion // false' <<< "$resp")"
    if [ "$current" = "true" ]; then
        echo "[skip   ] projectRoleAssertion already true"
        return 0
    fi
    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would set projectRoleAssertion=true (currently ${current})"
        return 0
    fi

    # The PUT is a full replace: omitting a field resets it to its zero value, so
    # the other three are restated at their current defaults rather than dropped.
    jq -n --arg n "$ZITADEL_PROJECT_NAME" \
        '{name:$n, projectRoleAssertion:true, projectRoleCheck:false,
          hasProjectCheck:false,
          privateLabelingSetting:"PRIVATE_LABELING_SETTING_UNSPECIFIED"}' \
        | api PUT "/management/v1/projects/${project_id}" -d @- >/dev/null
    echo "[updated] projectRoleAssertion=true"
}

app_id_by_name() {
    local resp
    resp="$(api_or_fail POST "/management/v1/projects/$1/apps/_search" -d '{"queries":[]}')" || return 1
    jq -r --arg n "$2" '.result[]? | select(.name == $n) | .id' <<< "$resp" | head -1
}

# The whole app entry, once -- redirectUris for the staleness check below and
# (defect 4) clientId for converging an existing app's secret payload. One
# call rather than two separate reads of the same object.
app_get() {
    api_or_fail GET "/management/v1/projects/$1/apps/$2"
}

# Every field of an app's OIDC config, as ZITADEL wants it. ONE definition,
# used by both the create POST and the update PUT below, and that is the point:
# the update REPLACES the config rather than patching it, so every field the
# create sets has to be sent again -- omitting one silently reverts it to
# ZITADEL's default, and `accessTokenRoleAssertion`/`idTokenRoleAssertion`
# reverting to false is the same class of failure as projectRoleAssertion being
# off: authentication keeps working and every consumer loses its groups. Two
# copies of this list is exactly how a field reaches one call and not the other.
#
# $1 is a COMMA-SEPARATED list of redirect URIs, not a single URI. Every consumer
# here but one has exactly one callback, so it reads as one for them; OpenBao
# needs two, because its CLI completes the flow on a loopback listener the
# browser is sent back to (`http://localhost:8250/oidc/callback`) while the UI
# uses its own in-app path. Registering only one of the pair breaks that half of
# the login with ZITADEL's "The requested redirect_uri is missing in the client
# configuration" -- and only for whoever happens to use that entry point.
#
# Split on comma rather than taking an array: CONSUMERS is a flat `|`-delimited
# table and keeping it that way is worth more than the alternative of a parallel
# array indexed by consumer name.
#
# $2 is the app NAME, and only the create call passes it -- the oidc_config
# endpoint the update uses has no such field. $3 is the type: `jwt`, `native`
# (a public device-flow client, also JWT) or empty (bearer); both calls pass it,
# since the update replaces it too.
oidc_config_payload() {
    jq -n --arg r "$1" --arg n "${2:-}" --arg t "${3:-}" '
        (if $n == "" then {} else {name: $n} end) + {
          redirectUris: ($r | split(",")),
          responseTypes: ["OIDC_RESPONSE_TYPE_CODE"],
          grantTypes: (if $t == "native" then ["OIDC_GRANT_TYPE_DEVICE_CODE","OIDC_GRANT_TYPE_REFRESH_TOKEN"]
                       else ["OIDC_GRANT_TYPE_AUTHORIZATION_CODE","OIDC_GRANT_TYPE_REFRESH_TOKEN"] end),
          appType: (if $t == "native" then "OIDC_APP_TYPE_NATIVE" else "OIDC_APP_TYPE_WEB" end),
          authMethodType: (if $t == "native" then "OIDC_AUTH_METHOD_TYPE_NONE" else "OIDC_AUTH_METHOD_TYPE_BASIC" end),
          accessTokenType: (if $t == "jwt" or $t == "native" then "OIDC_TOKEN_TYPE_JWT" else "OIDC_TOKEN_TYPE_BEARER" end),
          accessTokenRoleAssertion: true,
          idTokenRoleAssertion: true,
          idTokenUserinfoAssertion: true,
          devMode: false
        }'
}

# Point an existing app at the redirect URIs it is supposed to have.
#
# This updates the OIDC CONFIG, not the app: ZITADEL rotates a client secret only
# through the separate `_secret` endpoint, so the running consumer keeps working
# and nothing has to be rewritten into the secret store.
app_set_redirect() {
    local project_id="$1" app_id="$2" redirect="$3" token="${4:-}"
    api PUT "/management/v1/projects/${project_id}/apps/${app_id}/oidc_config" \
        -d "$(oidc_config_payload "$redirect" "" "$token")" >/dev/null
}

# Merge OIDC fields into a secret without dropping what else is in it.
#
# $existing, $client_secret and (for headlamp-proxy) the cookie secret all
# travel into jq on STDIN, never as --arg/--argjson -- either would put the
# value on jq's argv, readable by any process via /proc/<pid>/cmdline for as
# long as jq runs. That matters for more than the client secret: $existing is
# the CURRENT full contents of the target secret, and for grafana that blob
# also carries the generated Grafana admin credentials, so --argjson base
# would leak those too. Only client_id and the issuer URL, neither secret, go
# in as --arg. Three concatenated JSON documents on one stream, pulled out in
# order with `input` -- the same trick jq's own manual gives for slurping more
# than one value without `--slurp` swallowing the whole stream into an array.
merge_secret() {
    local key="$1" name="$2" client_id="$3" client_secret="$4" project_id="${5:-}"
    local existing='{}' cookie_secret=''
    store_exists "$key" && existing="$(store_read "$key")"
    [ -z "$existing" ] && existing='{}'

    if [ "$name" = headlamp-proxy ] || [ "$name" = rooms-proxy ]; then
        # Hyphenated keys, deliberately: the oauth2-proxy chart's
        # `config.existingSecret` reads exactly client-id / client-secret /
        # cookie-secret, so the blob is shaped to be consumed by a whole-blob
        # ExternalSecret extract with no remapping.
        #
        # PRESERVED across runs -- regenerating on every sync would silently
        # log every user out and look like a broken login.
        #
        # EXACTLY 32 CHARACTERS. `openssl rand -base64 32` alone emits 44,
        # and oauth2-proxy refuses to start on it:
        #   cookie_secret must be 16, 24, or 32 bytes to create an AES
        #   cipher, but is 44 bytes
        # It measures the STRING, not the decoded bytes, so the base64 has to
        # be truncated to the cipher length rather than sized to decode into
        # it. `head -c 32` is the recipe the chart's own values.yaml gives.
        # `|| return 1` on both: cmd_sync calls this in $( ), where errexit is
        # not inherited, and an empty cookie secret would be written as is.
        cookie_secret="$(jq -r '."cookie-secret" // empty' <<< "$existing")" || return 1
        [ -n "$cookie_secret" ] || cookie_secret="$(openssl rand -base64 32 | head -c 32)" || return 1
    fi

    {
        printf '%s\n' "$existing"
        printf '%s' "$client_secret" | jq -Rs .
        printf '%s' "$cookie_secret" | jq -Rs .
    } | jq -n --arg id "$client_id" --arg iss "$IDP_URL" --arg name "$name" --arg scopes "$HEADLAMP_OIDC_SCOPES" --arg proj "$project_id" '
        input as $base | input as $sec | input as $ck |
        if $name == "grafana" then
            $base + {GF_AUTH_GENERIC_OAUTH_CLIENT_ID: $id, GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET: $sec}
        elif $name == "headlamp" then
            $base + {OIDC_CLIENT_ID: $id, OIDC_CLIENT_SECRET: $sec, OIDC_ISSUER_URL: $iss,
                     OIDC_SCOPES: $scopes,
                     OIDC_VALIDATOR_CLIENT_ID: $id, OIDC_VALIDATOR_ISSUER_URL: $iss}
        elif $name == "flux-ui" then
            $base + {clientID: $id, clientSecret: $sec}
        elif $name == "harbor" then
            $base + {client_id: $id, client_secret: $sec, endpoint: $iss}
        elif $name == "openbao" then
            $base + {client_id: $id, client_secret: $sec, endpoint: $iss}
        elif $name == "headlamp-proxy" then
            $base + {"client-id": $id, "client-secret": $sec, "cookie-secret": $ck}
        elif $name == "rooms-proxy" then
            $base + {"client-id": $id, "client-secret": $sec, "cookie-secret": $ck, "project-id": $proj}
        elif $name == "roomctl" then
            $base + {"client-id": $id}
        else
            empty
        end
    '
}

# DEFECT 4: converge the NON-SECRET fields of an EXISTING app's stored
# payload. merge_secret above only ever ran when an app was CREATED --
# cmd_sync's existing-app branch checked the redirect URI against ZITADEL and
# stopped there, never looking at what $key currently held. So a field this
# script's own literal changed after an app already existed never reached
# it: OIDC_SCOPES gaining `groups` on 2026-08-29 is why this exists. Every
# run against an already-registered headlamp printed
#   [ok     ] headlamp -- app exists (...), redirect correct
# and converge_secret was never even called -- the store kept the old value
# forever.
#
# What is converged, and why each one is safe to overwrite: client id and the
# issuer URL are read back FROM ZITADEL itself, not guessed, so they can only
# ever correct drift; the scopes string is this script's own literal, and
# stale copies of it are exactly the bug being closed. NEVER converged: the
# client secret (ZITADEL returns it exactly once, at creation, so this path
# has no correct value to put there even if it wanted to) and, for
# headlamp-proxy, the cookie secret (regenerating it on a routine sync would
# silently log out every user). Both are simply absent from every branch's
# overlay object below, so jq's `+` leaves whatever $existing already had.
#
# $existing travels in on stdin, not --argjson, for the same reason
# merge_secret keeps it off jq's argv: it can carry fields this script does
# not own (grafana's admin credentials), and putting the whole blob on argv
# would expose those too, not just the OIDC fields being converged here.
#
# rooms-proxy also carries the project id (S2): oauth2-proxy's audience scope and
# the broker's aud check need it on both clouds, aws-0's vars have no such key,
# and a fresh directory (gcp-0, every build) mints a new one with the client.
converge_secret() {
    local name="$1" client_id="$2" existing="$3" project_id="${4:-}"
    jq -n --arg id "$client_id" --arg iss "$IDP_URL" --arg name "$name" --arg scopes "$HEADLAMP_OIDC_SCOPES" --arg proj "$project_id" '
        input as $base |
        if $name == "grafana" then
            $base + {GF_AUTH_GENERIC_OAUTH_CLIENT_ID: $id}
        elif $name == "headlamp" then
            $base + {OIDC_CLIENT_ID: $id, OIDC_ISSUER_URL: $iss, OIDC_SCOPES: $scopes,
                     OIDC_VALIDATOR_CLIENT_ID: $id, OIDC_VALIDATOR_ISSUER_URL: $iss}
        elif $name == "flux-ui" then
            $base + {clientID: $id}
        elif $name == "harbor" then
            $base + {client_id: $id, endpoint: $iss}
        elif $name == "openbao" then
            $base + {client_id: $id, endpoint: $iss}
        elif $name == "headlamp-proxy" then
            $base + {"client-id": $id}
        elif $name == "rooms-proxy" then
            $base + {"client-id": $id, "project-id": $proj}
        elif $name == "roomctl" then
            $base + {"client-id": $id}
        else
            empty
        end
    ' <<< "$existing"
}

# THE OTHER END OF THE SAME CONTRACT.
#
# reconcile_workforce_audience above fixes what the POOL expects. This fixes
# what oauth2-proxy REQUESTS -- ZITADEL only stamps a project id into a token's
# `aud` when the token was asked for with that project's audience scope, and
# that scope is rendered from ${zitadel_project_id} in the cluster vars
# ConfigMap.
#
# Fixing only one end is worse than fixing neither: the pool then expects an
# audience no token will ever carry, and every exchange fails `invalid_grant`
# while oauth2-proxy, the exchange proxy, Headlamp and every Flux resource all
# report healthy.
#
# The ConfigMap is written by tofu but carries reconcile.fluxcd.io/watch, so a
# patch here makes Flux re-render the consumers by itself. tofu will rewrite the
# committed value on its next apply -- harmless, because this script runs after
# gke/configure in the deploy flow and simply corrects it again.
reconcile_consumer_audience() {
    local project_id="$1" cm current
    cm="$(kubectl get cm -n flux-system -o name 2>/dev/null | grep -E 'vars$' | head -1)"
    if [ -z "$cm" ]; then
        echo "consumer: no cluster vars ConfigMap reachable from this context, skipping" >&2
        return 0
    fi

    current="$(kubectl get "$cm" -n flux-system -o jsonpath='{.data.zitadel_project_id}' 2>/dev/null)"
    if [ -z "$current" ]; then
        echo "consumer: ${cm} defines no zitadel_project_id, skipping" >&2
        return 0
    fi
    if [ "$current" = "$project_id" ]; then
        echo "consumer: audience scope already ${project_id}"
        return 0
    fi

    echo "consumer: audience scope ${current} -> ${project_id}"
    if kubectl patch "$cm" -n flux-system --type=merge \
         -p "{\"data\":{\"zitadel_project_id\":\"${project_id}\"}}" >/dev/null 2>&1; then
        echo "consumer: patched; Flux will re-render the consumers"
    else
        echo "consumer: FAILED to patch ${cm}. oauth2-proxy will keep requesting" >&2
        echo "          the wrong audience and every exchange will 400." >&2
    fi
}

# THE WORKFORCE PROVIDER'S AUDIENCE IS AN OIDC CLIENT ID, NOT THE PROJECT ID.
#
# This used to pin the provider's client_id to the ZITADEL project id, reasoning
# that ZITADEL stamps the project id into the `aud` of every token the project
# issues -- so any client would be accepted and the pool could exist before a
# single OIDC app did. The `aud` part of that was measured correctly.
#
# What it missed is `azp`. Requesting the project audience scope makes `aud`
# MULTI-VALUED (on gcp-0: six app client ids plus the project id), and for a
# multi-audience token OIDC Core 3.1.3.7 requires `azp` to be present and to
# equal the relying party's client id. Google STS enforces exactly that. `azp` is
# always the client the token was ISSUED TO -- headlamp-proxy -- and never the
# project, so a project-pinned client_id could not match it and every exchange
# failed:
#
#   token exchange 400: invalid_grant
#   (azp=388283282036425069 aud=[<six client ids>, 388252679236747629])
#
# Measured on gcp-0 2026-09-12: the exchange had never once succeeded since it
# was deployed, while oauth2-proxy, the exchange proxy, Headlamp and every Flux
# resource reported healthy -- the same silent failure the old comment warned
# about, arriving through the very mechanism it recommended.
#
# So the provider's client_id must be the client id of the app whose token is
# presented. That is knowable only after the app exists, which is why this runs
# AFTER the consumer loop rather than before it, and why the tofu resource keeps
# `lifecycle.ignore_changes` on the field.
#
# The consumer end is unchanged and still keyed on the PROJECT id: that scope is
# what puts a shared audience in the token at all, and with `azp` now matching
# the provider, a multi-valued `aud` is accepted.
reconcile_workforce_audience() {
    local project_id="$1" current app_name app_id app_json client_id
    [ -n "$WORKFORCE_POOL" ] || return 0
    [ "$project_id" != "DRYRUN-PROJECT" ] || return 0

    if ! command -v gcloud >/dev/null 2>&1; then
        echo "workforce: gcloud not available, skipping audience reconciliation" >&2
        return 0
    fi

    # The app name is spelled out here rather than held in a module-level
    # constant on purpose: test-zitadel-workforce-audience.sh LIFTS this function
    # body out with sed and eval's it, so anything it reads from the enclosing
    # file is an unbound variable under `set -u` in the harness.
    #
    # Suffixed exactly as the consumer loop builds it. A cluster that only
    # CONSUMES this directory names the app "headlamp-proxy-<cluster>", so
    # looking up the bare name there would find nothing and silently leave the
    # provider pinned to whatever it already had.
    app_name="headlamp-proxy${APP_SUFFIX:-}"
    app_id="$(app_id_by_name "$project_id" "$app_name")" || return 0
    if [ -z "$app_id" ]; then
        echo "workforce: ${app_name} does not exist yet, skipping audience reconciliation" >&2
        return 0
    fi

    app_json="$(app_get "$project_id" "$app_id")" || return 0
    client_id="$(jq -r '.app.oidcConfig.clientId // empty' <<< "$app_json")"
    if [ -z "$client_id" ]; then
        echo "workforce: ${app_name} has no oidcConfig.clientId, skipping" >&2
        return 0
    fi

    current="$(gcloud iam workforce-pools providers describe zitadel \
                 --workforce-pool="$WORKFORCE_POOL" --location=global \
                 --format='value(oidc.clientId)' 2>/dev/null)" || true

    if [ -z "$current" ]; then
        echo "workforce: pool '${WORKFORCE_POOL}' has no zitadel provider yet, skipping" >&2
        return 0
    fi

    if [ "$current" = "$client_id" ]; then
        echo "workforce: audience already ${client_id} (${app_name})"
        # Still check the other end. Reconciling the consumer only after an
        # update meant a correct provider left the ConfigMap unexamined, which
        # is precisely the half-fixed state the comment above warns is worse
        # than fixing neither end.
        reconcile_consumer_audience "$project_id"
        return 0
    fi

    echo "workforce: audience ${current} -> ${client_id} (${app_name})"
    if [ "$APPLY" != "true" ]; then
        echo "workforce: (dry-run, not applied)"
        return 0
    fi

    if gcloud iam workforce-pools providers update-oidc zitadel \
         --workforce-pool="$WORKFORCE_POOL" --location=global \
         --client-id="$client_id" >/dev/null 2>&1; then
        echo "workforce: audience updated"
        reconcile_consumer_audience "$project_id"
    else
        # Not fatal: every OTHER consumer this script configures is unaffected,
        # and failing here would leave the OIDC clients half-written. The
        # symptom is contained to the dashboard's token exchange.
        echo "workforce: FAILED to update the provider audience -- per-user RBAC" >&2
        echo "           will fail with invalid_grant until this is corrected." >&2
    fi
}

# OpenBao's auth/oidc config as it must be written: the current one minus
# `status`, plus the client ZITADEL issued.
#
# A read-modify-write, because a config write REPLACES the whole config: a field
# the POST omits is reset, not kept (design fact 6). stdin is two JSON
# documents, the `.data` of GET auth/oidc/config and then the store payload
# {client_id, client_secret, endpoint}, so the secret never reaches jq's argv.
#
# Refuses a non-empty provider_config, because the read strips its sensitive
# keys and writing it back would blank them. Refuses an empty id or secret,
# which would write a config that authenticates nobody.
openbao_oidc_config_payload() {
    jq -n '
        input as $cfg | input as $s |
        if (($cfg.provider_config // {}) | length) > 0 then
            "[FAILED ] openbao -- auth/oidc/config has a provider_config, whose sensitive keys a read strips; not writing it back\n" | halt_error(1)
        elif ($s.client_id // "") == "" or ($s.client_secret // "") == "" then
            "[FAILED ] openbao -- the store payload has no client_id or client_secret\n" | halt_error(1)
        else
            ($cfg | del(.status)) + {oidc_client_id: $s.client_id, oidc_client_secret: $s.client_secret}
        end' || return 1
}

# The fields this script owns in a consumer secret: every key merge_secret and
# converge_secret write. Onto an EXISTING OpenBao value the mirror copies only
# these. The rest of a blob belongs to another writer -- seed's
# GF_SECURITY_ADMIN_PASSWORD in grafana-envvars -- and OpenBao's copy of it may
# be newer than the store's (a rotation made in OpenBao), so the mirror never
# overwrites it. An ABSENT path gets the whole payload: `migrate` skips a path
# that exists, so nothing else would ever fill in the rest.
# test-zitadel-oidc-clients-mirror.sh fails when merge_secret writes a key
# missing here.
MIRRORED_FIELDS=(
    GF_AUTH_GENERIC_OAUTH_CLIENT_ID GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET
    OIDC_CLIENT_ID OIDC_CLIENT_SECRET OIDC_ISSUER_URL OIDC_SCOPES
    OIDC_VALIDATOR_CLIENT_ID OIDC_VALIDATOR_ISSUER_URL
    clientID clientSecret
    client_id client_secret endpoint
    client-id client-secret cookie-secret project-id
)

# Mirror one consumer secret into the OpenBao path its ExternalSecret reads
# (--mirror-openbao): MIRRORED_FIELDS from the store's blob, onto what OpenBao
# holds, or the whole blob when OpenBao holds nothing. Writes only when that
# changes OpenBao's value, so a re-run adds no KV version. Unmapped keys
# (openbao-oidc, headlamp-oauth2-proxy) are read from the managed store; they
# are skipped, and said so. A subshell, like
# reconcile_openbao_oidc, so its temp files and trap stay local. Secrets move
# through stdin and 0700-directory files, never argv.
mirror_to_openbao() (
    # xtrace would print the payload, and the client secret with it.
    set +x
    key="$1"
    [ "${MIRROR_OPENBAO:-false}" = "true" ] || exit 0
    if ! target="$(bao_target_for "$key")"; then
        echo "[skip   ] ${key}: no OpenBao path in scripts/lib/bao-map.sh" >&2
        exit 0
    fi
    mount="${target%%/*}"
    path="${target#*/}"
    # One directory, trapped the moment it exists, so no second mktemp can
    # fail and strand the first. The path is baked in at trap-set time.
    tmp="$(umask 077 && mktemp -d -t openbao-mirror.XXXXXX)" || exit 1
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    cat > "$tmp/payload" || exit 1
    OPENBAO_TOKEN_CONFIG="$tmp/token"
    if ! openbao_token_config_write "$OPENBAO_TOKEN_CONFIG" "${OPENBAO_ROOT_TOKEN_SECRET:-}"; then
        echo "[FAILED ] ${key} -- no OpenBao root token readable from ${OPENBAO_ROOT_TOKEN_SECRET:-<unset>}" >&2
        exit 1
    fi
    # Only a 404 means "nothing there yet". Any other answer (403, a TLS or CA
    # error, a timeout) must not become an empty merge base. curl's stderr is
    # shown for those: it holds curl's own error line only -- the token is in a
    # -K file and a body goes to -o -- and a 404's "(22)" line is expected.
    absent=false
    code="$(openbao_req GET "${mount}/data/${path}" -o "$tmp/read" -w '%{http_code}' 2>"$tmp/err")" || true
    case "$code" in
        200) jq -ce '.data.data // {} | objects' "$tmp/read" > "$tmp/current" \
                 || { echo "[FAILED ] ${key} -- ${target} is not readable JSON; not overwriting it" >&2; exit 1; } ;;
        404) printf '{}' > "$tmp/current"; absent=true ;;
        *)   echo "[FAILED ] ${key} -- reading ${target} returned HTTP ${code:-none}; not overwriting it" >&2
             cat "$tmp/err" >&2
             exit 1 ;;
    esac
    # Field NAMES go in as --args (none is secret); both values on stdin.
    if ! cat "$tmp/current" "$tmp/payload" | jq -cn --argjson absent "$absent" '
            input as $cur | input as $p |
            (if $absent then $p
             else $cur + ($p | with_entries(select(.key | IN($ARGS.positional[])))) end) as $new |
            if $new == $cur then empty else {data: $new} end' \
            --args "${MIRRORED_FIELDS[@]}" > "$tmp/write"; then
        echo "[FAILED ] ${key} -- could not merge into ${target}; not overwriting it" >&2
        exit 1
    fi
    if [ ! -s "$tmp/write" ]; then
        echo "[ok     ] ${key} -- ${target} already holds these fields"
        exit 0
    fi
    if ! openbao_req POST "${mount}/data/${path}" --data-binary @- < "$tmp/write" >/dev/null; then
        echo "[FAILED ] ${key} -- not mirrored to ${target}" >&2
        exit 1
    fi
    echo "[mirrored] ${key} -> ${target}"
)

# The managed store first, then the mirror, with one payload. Returns 1 when
# the store write fails and 2 when only the mirror does: cmd_sync stops on the
# first and carries on past the second (failed_mirrors there).
store_write_and_mirror() {
    # The payload sits in a variable here, so xtrace would print it.
    local -
    set +x
    local key="$1" payload
    payload="$(cat)"
    printf '%s' "$payload" | store_write "$key" || return 1
    printf '%s' "$payload" | mirror_to_openbao "$key" || return 2
}

# Force-sync every ExternalSecret that reads a mirrored path. Left alone, each
# waits out its refreshInterval (up to 1h) serving the dead directory's client.
# Matched on store (openbao-<mount>, or agent-system's agents-secrets for the
# agents mount) and key. Warn-only: the mirror already
# converged OpenBao, and the next refresh picks it up regardless.
force_sync_mirrored() {
    [ "$APPLY" = "true" ] && [ "${MIRROR_OPENBAO:-false}" = "true" ] || return 0
    local key target es_json ns name now targets=()
    for key in "$@"; do
        target="$(bao_target_for "$key")" && targets+=("$target")
    done
    [ "${#targets[@]}" -gt 0 ] || return 0
    if ! es_json="$(kubectl get externalsecrets -A -o json 2>/dev/null)"; then
        echo "WARN: could not list ExternalSecrets; mirrored ones refresh on their own interval" >&2
        return 0
    fi
    now="$(date +%s)"
    jq -r '.items[]
        | (.spec.secretStoreRef.name // "") as $store
        | ($store | if . == "agents-secrets" then "agents"
                    elif startswith("openbao-") then ltrimstr("openbao-")
                    else empty end) as $mount
        | select([(.spec.data // [])[].remoteRef.key?, (.spec.dataFrom // [])[].extract.key?]
                 | map(select(. != null) | $mount + "/" + .)
                 | any(IN($ARGS.positional[])))
        | "\(.metadata.namespace) \(.metadata.name)"' --args "${targets[@]}" <<< "$es_json" \
    | while read -r ns name; do
        if kubectl annotate externalsecret "$name" -n "$ns" force-sync="$now" --overwrite >/dev/null; then
            echo "[synced ] externalsecret ${ns}/${name}"
        else
            echo "WARN: could not force-sync externalsecret ${ns}/${name}" >&2
        fi
    done || echo "WARN: could not match ExternalSecrets to the mirrored paths" >&2
}

# The client id a stored consumer payload carries, whichever field its consumer
# names it by (merge_secret). The payload arrives on stdin: it holds the secret.
stored_client_id() {
    jq -r 'first(.GF_AUTH_GENERIC_OAUTH_CLIENT_ID, .OIDC_CLIENT_ID, .clientID,
                 .client_id, ."client-id" | strings) // empty' 2>/dev/null || true
}

# The payload OpenBao holds at $1's mapped path, on stdout; nothing when unmapped,
# absent or unreadable. A subshell, like mirror_to_openbao, so its temp files and
# trap stay local; the payload holds the secret, so it only ever feeds a pipe.
mirror_read() (
    set +x
    key="$1"
    target="$(bao_target_for "$key")" || exit 0
    tmp="$(umask 077 && mktemp -d -t openbao-read.XXXXXX)" || exit 0
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" EXIT
    OPENBAO_TOKEN_CONFIG="$tmp/token"
    openbao_token_config_write "$OPENBAO_TOKEN_CONFIG" "${OPENBAO_ROOT_TOKEN_SECRET:-}" 2>/dev/null || exit 0
    openbao_req GET "${target%%/*}/data/${target#*/}" -o "$tmp/read" 2>/dev/null || exit 0
    jq -c '.data.data // empty' "$tmp/read" 2>/dev/null || true
)

# The client id $1's consumers run with today: the managed store's, else -- on a
# mirrored key -- OpenBao's, which is what their ExternalSecret reads. A lineage
# whose OpenBao was restored while the store was not holds the old client only
# there (aws-0, 2026-10-06: rooms-proxy). Empty means a first bootstrap.
previous_client_id() {
    local key="$1" id=""
    if store_exists "$key"; then
        id="$(store_read "$key" | stored_client_id)" || id=""
    fi
    if [ -z "$id" ] && [ "${MIRROR_OPENBAO:-false}" = "true" ]; then
        id="$(mirror_read "$key" | stored_client_id)" || id=""
    fi
    printf '%s' "$id"
}

# Restart the Deployments that read a ROTATED client from env. They resolve it
# once, at start, so a refreshed Secret is not enough: after an OpenBao rebuild
# headlamp-oauth2-proxy kept the dead directory's client id and answered "App
# not found" until restarted by hand, while every resource reported healthy.
#
# Arguments are `<store key>=<new client id>`, only for keys whose stored client
# id this run changed, so a re-run with nothing rotated restarts nothing. Warn-only
# like force_sync_mirrored: the clients are already written.
#
# kubectl must point at $CLUSTER. aws/eks/init's consuming sync for gcp-0 runs
# with kubectl on aws-0, and restarting there would restart the wrong cluster.
#
# The Secret has to carry the new id before the restart, or the new pods read
# the old one again: force-sync each ExternalSecret reading the key, then wait
# (one deadline for all of them) until its Secret does.
restart_rotated_consumers() {
    [ "$APPLY" = "true" ] && [ $# -gt 0 ] || return 0
    local pair store_name id target es_json ns es obj deploys d deadline now
    local matches=() restarted=()
    if ! kubectl get configmap -n flux-system -o name 2>/dev/null | grep -Eq -- "-${CLUSTER}-vars\$"; then
        echo "WARN: kubectl does not point at ${CLUSTER}. Rotated: ${*%%=*}." >&2
        echo "      Restart the Deployments reading those keys there, once their Secrets refresh." >&2
        return 0
    fi
    if ! es_json="$(kubectl get externalsecrets -A -o json 2>/dev/null)"; then
        echo "WARN: could not list ExternalSecrets; restart the consumers of ${*%%=*} by hand" >&2
        return 0
    fi
    now="$(date +%s)"
    for pair in "$@"; do
        store_name="${pair%%=*}"; id="${pair#*=}"
        target="$(bao_target_for "$store_name")" || target=""
        # Read from OpenBao at the key's mapped path, or from the managed store
        # under the key itself (unmapped keys such as headlamp-oauth2-proxy).
        while read -r ns es obj; do
            [ -n "$obj" ] || continue
            kubectl annotate externalsecret "$es" -n "$ns" force-sync="$now" --overwrite >/dev/null 2>&1 \
                || echo "WARN: could not force-sync externalsecret ${ns}/${es}" >&2
            matches+=("${ns} ${obj} ${id}")
        done < <(jq -r --arg name "$store_name" --arg target "$target" '.items[]
            | (.spec.secretStoreRef.name // "") as $store
            | ([(.spec.data // [])[].remoteRef.key?, (.spec.dataFrom // [])[].extract.key?]
               | map(select(. != null))) as $keys
            | select((($store | startswith("openbao-")) and $target != ""
                       and ($keys | map(($store | ltrimstr("openbao-")) + "/" + .) | index($target)) != null)
                     or ($store == "clustersecretstore" and ($keys | index($name)) != null))
            | "\(.metadata.namespace) \(.metadata.name) \(.spec.target.name // .metadata.name)"' <<< "$es_json")
    done
    [ "${#matches[@]}" -gt 0 ] || { echo "[ok     ] no ExternalSecret reads a rotated key; nothing to restart"; return 0; }

    deadline=$(( $(date +%s) + ${OIDC_CONSUMER_WAIT_SECONDS:-180} ))
    for pair in "${matches[@]}"; do
        read -r ns obj id <<< "$pair"
        until kubectl get secret "$obj" -n "$ns" -o json 2>/dev/null \
                | jq -e --arg id "$id" '.data // {} | any(.[]; @base64d == $id)' >/dev/null 2>&1; do
            if [ "$(date +%s)" -ge "$deadline" ]; then
                echo "WARN: ${ns}/${obj} does not carry client ${id} yet; its consumers keep the old one." >&2
                echo "      Once it does: kubectl rollout restart deployment -n ${ns} <each Deployment reading it>" >&2
                continue 2
            fi
            sleep "${OIDC_CONSUMER_POLL_SECONDS:-5}"
        done
        if ! deploys="$(kubectl get deployments -n "$ns" -o json 2>/dev/null | jq -r --arg s "$obj" '.items[]
                | select([.spec.template.spec | (.containers // []) + (.initContainers // []) | .[]
                          | (.envFrom // [])[].secretRef.name?, (.env // [])[].valueFrom.secretKeyRef.name?]
                         | index($s) != null)
                | .metadata.name')"; then
            echo "WARN: could not list Deployments in ${ns}; restart the readers of ${obj} by hand" >&2
            continue
        fi
        for d in $deploys; do
            [[ " ${restarted[*]} " == *" ${ns}/${d} "* ]] && continue
            if kubectl rollout restart deployment "$d" -n "$ns" >/dev/null 2>&1; then
                echo "[restart] deployment ${ns}/${d} -- ${obj} carries rotated client ${id}"
                restarted+=("${ns}/${d}")
            else
                echo "WARN: could not restart deployment ${ns}/${d}; it keeps the old client id" >&2
            fi
        done
    done
}

# GCP hosting: publish this directory's project id for gke/configure, which
# reads it at plan time (GCP parity GP-4). A fresh directory gets a new id
# every build, and the committed one would otherwise come back on the next
# configure apply. Written only on a change: one Secret Manager version per
# directory, not per sync. Called under `||`, so every step is checked.
publish_project_id() {
    local project_id="$1" current=""
    if [ "$CLOUD" != "gcp" ] || [ "$IDP_CLOUD" != "$CLOUD" ] || [ "$APPLY" != "true" ] \
       || [ "$project_id" = "DRYRUN-PROJECT" ]; then
        return 0
    fi
    current="$(store_read zitadel-project-id 2>/dev/null | jq -r '.project_id // empty' 2>/dev/null || true)"
    if [ "$current" = "$project_id" ]; then
        echo "project: zitadel-project-id unchanged"
        return 0
    fi
    printf '%s' "$project_id" | jq -Rc '{project_id: .}' | store_write zitadel-project-id || return 1
    echo "project: published to zitadel-project-id"
}

# Point OpenBao's auth/oidc at the client ZITADEL issued. Two resources carry
# it: the config (id and secret) and the default role's bound_audiences. Moving
# only the config leaves every login failing on audience (design fact 5).
#
# Every rebuild restores ZITADEL from a seed older than the `openbao` app, so the
# app, and its id, are new each time. Terraform creates the mount and ignores
# these three fields afterwards; this rotates them, the way
# reconcile_workforce_audience rotates the workforce provider's client id.
#
# The body is a subshell so that its EXIT trap, which removes the root-token
# file, stays private: bash keeps one EXIT trap per shell, and the script's own
# (the PAT file) must survive. The caller tests this with `||`, which turns
# errexit off in here (fact 14), so every call is checked explicitly.
reconcile_openbao_oidc() {
    (
    # xtrace would print the stored payload, and the client secret with it.
    set +x
    local key="${1:-}" want_id="${2:-}" role="default"
    local stored stored_id attempt auth_json mount want_aud
    local cfg_json cfg have_id role_json have_aud need_cfg=false need_role=false
    local payload body out probe=0

    [ -n "${OPENBAO_URL:-}" ] || exit 0
    # A dry run of a create has no client id yet. Under --apply the consumer loop
    # always yields one, so its absence is a wiring bug, not a skip.
    if [ -z "$key" ] || [ -z "$want_id" ]; then
        if [ "${APPLY:-false}" = "true" ]; then
            echo "[FAILED ] openbao -- called without a store key or client id (key '${key}', id '${want_id}')" >&2
            exit 1
        fi
        echo "[skip   ] openbao -- no client id from ZITADEL this run"
        exit 0
    fi
    # A failed read is not "absent" (#2082). Under --apply the loop wrote $key
    # moments ago, so absent there is eventual consistency or a failed write:
    # the read loop below retries it like a stale value, then fails.
    store_probe "$key" || probe=$?
    if [ "$probe" -ge 2 ]; then
        echo "[FAILED ] openbao -- cannot read ${key} from the secret store: ${STORE_PROBE_ERR}" >&2
        exit 1
    fi
    if [ "$probe" -eq 1 ] && [ "${APPLY:-false}" != "true" ]; then
        echo "[skip   ] openbao -- ${key} is not in the secret store"
        exit 0
    fi

    # Secrets Manager is eventually consistent: a read right after this run's own
    # write can still return the previous client. A dry run wrote nothing, so it
    # has nothing to wait for.
    attempt=0
    while :; do
        stored="$(store_read "$key")" || stored=""
        stored_id="$(jq -r '.client_id // empty' <<< "$stored" 2>/dev/null)" || stored_id=""
        [ "$stored_id" = "$want_id" ] && break
        if [ "${APPLY:-false}" != "true" ]; then
            echo "[dry-run] openbao -- ${key} holds client ${stored_id:-<none>}; the sync converges it to ${want_id} first"
            break
        fi
        if [ "$attempt" -ge 6 ]; then
            if [ "$probe" -eq 1 ]; then
                echo "[FAILED ] openbao -- ${key} is still not in the secret store after this run wrote it; ZITADEL issued ${want_id}" >&2
            else
                echo "[FAILED ] openbao -- ${key} still holds client ${stored_id:-<none>}; ZITADEL issued ${want_id}" >&2
            fi
            exit 1
        fi
        attempt=$((attempt + 1))
        sleep "${OPENBAO_RETRY_SLEEP:-5}"
    done

    OPENBAO_TOKEN_CONFIG="$(umask 077 && mktemp -t openbao-oidc-curl.XXXXXX)" || exit 1
    # shellcheck disable=SC2064
    trap "rm -f '$OPENBAO_TOKEN_CONFIG'" EXIT
    if ! openbao_token_config_write "$OPENBAO_TOKEN_CONFIG" "${OPENBAO_ROOT_TOKEN_SECRET:-}"; then
        echo "[FAILED ] openbao -- no root token readable from ${OPENBAO_ROOT_TOKEN_SECRET:-<unset>}" >&2
        exit 1
    fi

    # Only a mount map that lacks oidc/ means "no mount". An error, an empty body,
    # `null` or `{}` says nothing, and skipping on it would pass a stale client
    # off as a first bootstrap.
    if ! auth_json="$(openbao_req GET sys/auth 2>&1)"; then
        echo "[FAILED ] openbao -- cannot list the auth mounts at ${OPENBAO_URL}: ${auth_json}" >&2
        exit 1
    fi
    mount="$(jq -r '.data | objects | has("oidc/")' <<< "$auth_json" 2>/dev/null)" || mount=""
    case "$mount" in
        true) ;;
        false)
            echo "[skip   ] openbao -- no oidc/ auth mount yet. First bootstrap: with ZITADEL up, apply the management stack once:"
            echo "           terramate -C opentofu/aws/openbao/management script run deploy"
            exit 0 ;;
        *)
            echo "[FAILED ] openbao -- no auth mount map from ${OPENBAO_URL}/v1/sys/auth: ${auth_json:-<empty body>}" >&2
            exit 1 ;;
    esac

    want_aud="$(jq -cn --arg id "$want_id" '[$id]')" || exit 1
    # Both reads, for the comparison now and for the read-back after the writes.
    read_oidc() {
        cfg_json="$(openbao_req GET auth/oidc/config)" || return 1
        role_json="$(openbao_req GET "auth/oidc/role/${role}")" || return 1
        cfg="$(jq -ce '.data | objects' <<< "$cfg_json")" || return 1
        have_id="$(jq -r '.oidc_client_id // ""' <<< "$cfg")" || return 1
        have_aud="$(jq -ce '.data.bound_audiences // [] | arrays' <<< "$role_json")" || return 1
    }
    if ! read_oidc; then
        echo "[FAILED ] openbao -- cannot read auth/oidc/config or its ${role} role" >&2
        exit 1
    fi
    [ "$have_id" = "$want_id" ] || need_cfg=true
    [ "$have_aud" = "$want_aud" ] || need_role=true

    if [ "$need_cfg" = false ] && [ "$need_role" = false ]; then
        echo "[ok     ] openbao -- auth/oidc already uses client ${want_id}"
        exit 0
    fi
    if [ "${APPLY:-false}" != "true" ]; then
        [ "$need_cfg" = false ] || echo "[dry-run] openbao -- auth/oidc/config client ${have_id:-<none>} -> ${want_id}, and its secret"
        [ "$need_role" = false ] || echo "[dry-run] openbao -- auth/oidc/role/${role} bound_audiences ${have_aud} -> ${want_aud}"
        exit 0
    fi

    if [ "$need_cfg" = true ]; then
        payload="$(printf '%s\n%s\n' "$cfg" "$stored" | openbao_oidc_config_payload)" || exit 1
        # The write validates the discovery URL, and on a rebuild ZITADEL's
        # public route can lag its pods. A route that drops packets makes that
        # fetch outlast openbao_req's --max-time, so curl's timeout (28) is the
        # same cause. Any other refusal is final. The write is idempotent.
        attempt=0
        until out="$(printf '%s' "$payload" | openbao_req POST auth/oidc/config --data-binary @- 2>&1)"; do
            if { [[ "$out" != *"error checking oidc discovery URL"* ]] && [[ "$out" != *"curl: (28)"* ]]; } \
                || [ "$attempt" -ge 6 ]; then
                echo "[FAILED ] openbao -- auth/oidc/config not written, so the role is left alone: ${out}" >&2
                exit 1
            fi
            attempt=$((attempt + 1))
            sleep "${OPENBAO_DISCOVERY_RETRY_SLEEP:-10}"
        done
        echo "[reconciled] openbao -- auth/oidc/config client ${have_id:-<none>} -> ${want_id}"
    fi

    if [ "$need_role" = true ]; then
        # Partial: a role write merges (fact 7), except for four fields that an
        # omission resets. role_type is sent; oidc.tf leaves bound_claims_type,
        # callback_mode and oidc_disable_confirmation at those same defaults.
        body="$(jq -cn --arg id "$want_id" '{role_type: "oidc", bound_audiences: [$id]}')" || exit 1
        if ! out="$(printf '%s' "$body" | openbao_req POST "auth/oidc/role/${role}" --data-binary @- 2>&1)"; then
            echo "[FAILED ] openbao -- auth/oidc/role/${role} not written: ${out}" >&2
            if [ "$need_cfg" = true ]; then
                echo "           The config has already moved to client ${want_id}, so logins fail on" >&2
                echo "           audience until the role follows. Re-running sync --apply finishes it." >&2
            fi
            exit 1
        fi
        echo "[reconciled] openbao -- auth/oidc/role/${role} bound_audiences ${have_aud} -> ${want_aud}"
    fi

    if ! read_oidc; then
        echo "[FAILED ] openbao -- cannot read auth/oidc back after the write" >&2
        exit 1
    fi
    if [ "$have_id" != "$want_id" ] || [ "$have_aud" != "$want_aud" ]; then
        echo "[FAILED ] openbao -- read back client ${have_id:-<none>}, audience ${have_aud}; want ${want_id}" >&2
        exit 1
    fi
    )
}

cmd_sync() {
    echo "cluster:  ${CLUSTER} (${CLOUD})"
    echo "idp:      ${IDP_URL}"
    echo "project:  ${ZITADEL_PROJECT_NAME}"
    echo

    local project_id
    # DEFECT 1: ensure_project used to be captured the same way but with no
    # way to tell "it failed" from "it returned the dry-run sentinel" -- both
    # are non-empty strings, so the `[ -n ... ]` check below let a failed API
    # call straight through. Checking the command substitution's own exit
    # status closes that: ensure_project now returns non-zero on a genuine
    # failure (and has already printed why), so this `if !` catches it before
    # the emptiness check ever runs.
    if ! project_id="$(ensure_project)"; then
        exit 1
    fi
    [ -n "$project_id" ] || { echo "could not resolve or create the ZITADEL project" >&2; exit 1; }

    ensure_project_role_assertion "$project_id"
    # reconcile_workforce_audience runs AFTER the consumer loop below: it needs
    # the headlamp-proxy app's client id, which does not exist on a first sync
    # until that loop creates it.
    ensure_project_roles "$project_id"
    [ -n "$GRANT_ADMIN" ] && GRANTS+=("admin=${GRANT_ADMIN}")
    for g in "${GRANTS[@]+"${GRANTS[@]}"}"; do
        grant_role "${g%%=*}" "${g#*=}" "$project_id" || exit 1
    done

    local created=0 skipped=0 updated=0 converged=0
    # A failed mirror does not stop the loop, like openbao_failed below: the
    # other consumers and both reconciles still run, then the sync exits 1.
    local failed_mirrors="" wrc=0
    # Keys mirrored without error, force-synced after the loop.
    local mirrored_keys=()
    # `<key>=<client id>` for each key whose stored client id this run replaced:
    # the only consumers restart_rotated_consumers restarts.
    local rotated=() prev_id
    # Fed to reconcile_openbao_oidc after the loop -- see the consumer's own
    # branches below for where each is set. Empty stays empty on a dry run
    # (reconcile_openbao_oidc treats that as its own skip) and on any topology
    # missing the "openbao" consumer entirely.
    local openbao_key="" openbao_client_id=""
    for entry in "${CONSUMERS[@]}"; do
        # TWO names, and conflating them is a bug this script has already made.
        #
        #   consumer -- the bare name (grafana, harbor, ...). It is the DISPATCH
        #               KEY for which fields go into which secret, matched
        #               literally inside merge_secret/converge_secret's jq.
        #   name     -- the ZITADEL app name, suffixed for a consuming cluster so
        #               two clusters do not contend for one app.
        #
        # Suffixing the CONSUMERS table itself made $name = "grafana-gcp-0",
        # which matched none of jq's `if $name == "grafana"` branches, fell to
        # the else, and produced an empty payload:
        #   ERROR: (gcloud.secrets.versions.add) INVALID_ARGUMENT:
        #   Secret Payload cannot be empty.
        # -- after the app had already been created in ZITADEL, stranding a
        # client secret that ZITADEL only ever returns once.
        IFS='|' read -r consumer redirect key token <<< "$entry"
        # :- so a harness that lifts this function out of the script (the
        # test-zitadel-* suites do) does not trip over nounset on a global it
        # did not know to declare.
        local name="${consumer}${APP_SUFFIX:-}"

        local existing_id=""
        if [ "$project_id" != "DRYRUN-PROJECT" ]; then
            # NOT `[ ... ] && existing_id=...`: the right-hand side of `&&` is
            # exempt from errexit by design, so a failed lookup there would
            # leave existing_id empty and silently fall through to the
            # create-a-new-app branch below -- recreating an app that
            # actually exists, which rotates its secret and breaks the
            # running consumer. An explicit `|| exit 1` cannot be bypassed
            # that way.
            existing_id="$(app_id_by_name "$project_id" "$name")" || exit 1
        fi

        if [ -n "$existing_id" ]; then
            # Never RECREATE: ZITADEL returns the client secret once, so
            # recreating would rotate it and break the running consumer.
            #
            # But do not leave it alone either. The redirect URI is derived from
            # $PRIVATE_DOMAIN, and a cluster restored from a frozen database
            # comes back with whatever domain was current when the seed was
            # taken. aws-0 restored from a 19 July seed on 2026-08-29 and every
            # client still pointed at priv.cloud.ogenki.io, months after the
            # cloud split moved it to priv.aws.ogenki.io. Every login failed with
            #   "The requested redirect_uri is missing in the client configuration"
            # and re-running this script cheerfully skipped all five.
            local app_json current client_id
            app_json="$(app_get "$project_id" "$existing_id")" || exit 1
            current="$(jq -r '.app.oidcConfig.redirectUris[]? // empty' <<< "$app_json")"
            client_id="$(jq -r '.app.oidcConfig.clientId // empty' <<< "$app_json")"
            if [ -z "$client_id" ]; then
                echo "[FAILED ] ${name}: app ${existing_id} has no oidcConfig.clientId in ZITADEL's response" >&2
                exit 1
            fi
            if [ "$consumer" = "openbao" ]; then
                openbao_key="$key"
                openbao_client_id="$client_id"
            fi

            # EVERY wanted URI must be registered, not just one of them. With a
            # single-URI consumer this is the original check; with OpenBao's
            # pair it is the difference between a working login and one that
            # works in the UI and fails in the CLI (or the reverse), which is a
            # confusing thing to debug because the app plainly exists and one
            # half of it plainly works.
            #
            # EXACT set, in both directions: a URI that is missing is drift, and
            # so is one that is registered and not declared here.
            #
            # This used to check only that the wanted set was present, with a
            # comment promising that "extra URIs already registered are left
            # alone". That promise was not kept, and could not be:
            # app_set_redirect sends the whole list, so the moment any repair
            # fired it replaced the set and dropped those extras anyway. The
            # check and the repair disagreed, and the comment described neither.
            #
            # Converging to the exact set is also the right answer rather than
            # merely the consistent one. A redirect URI is the control that stops
            # an authorization code being delivered somewhere else; one nobody
            # declared is a real surface, not a harmless leftover. This script is
            # the source of truth for these apps, so an undeclared URI is exactly
            # the thing it should be removing -- and now it says so before doing
            # it, instead of removing it as a side effect of an unrelated repair.
            local missing="" extra="" want have
            while IFS= read -r want; do
                [ -z "$want" ] && continue
                grep -Fxq "$want" <<< "$current" || missing="${missing}${missing:+ }${want}"
            done <<< "${redirect//,/$'\n'}"
            while IFS= read -r have; do
                [ -z "$have" ] && continue
                grep -Fxq "$have" <<< "${redirect//,/$'\n'}" || extra="${extra}${extra:+ }${have}"
            done <<< "$current"

            # The token type drifts independently (an app created as bearer before
            # rooms-proxy moved to JWT): the same PUT repairs it. ZITADEL omits
            # the enum's zero value, bearer.
            local want_type have_type
            want_type=OIDC_TOKEN_TYPE_BEARER
            case "$token" in jwt | native) want_type=OIDC_TOKEN_TYPE_JWT ;; esac
            have_type="$(jq -r '.app.oidcConfig.accessTokenType // "OIDC_TOKEN_TYPE_BEARER"' <<< "$app_json")"
            if [ -z "$missing" ] && [ -z "$extra" ] && [ "$have_type" = "$want_type" ]; then
                echo "[ok     ] ${name} -- app exists (${existing_id}), redirect correct"
                skipped=$((skipped + 1))
            else
                echo "[STALE  ] ${name} (${existing_id})"
                echo "           has:     ${current:-<none>}"
                echo "           want:    ${redirect}"
                # Both reported, and separately: they mean different things. A
                # missing URI breaks a login; an undeclared one is a redirect
                # target nobody asked for, and the operator should see which of
                # the two they are looking at before the repair removes it.
                [ -n "$missing" ] && echo "           missing: ${missing}"
                [ -n "$extra" ]   && echo "           undeclared (will be removed): ${extra}"
                [ "$have_type" = "$want_type" ] || echo "           token type: ${have_type} -> ${want_type}"
                if [ "$APPLY" != "true" ]; then
                    echo "           would update the redirect URI (client secret untouched)"
                else
                    app_set_redirect "$project_id" "$existing_id" "$redirect" "$token"
                    echo "[updated] ${name} -> ${redirect} (client secret untouched)"
                fi
                updated=$((updated + 1))
            fi

            # DEFECT 4: the redirect check above only ever compared ZITADEL's
            # own state -- it never looked at what $key currently holds, so a
            # field this script's own literal changed (OIDC_SCOPES gaining
            # `groups`) never reached a cluster whose app already existed.
            # This runs regardless of whether the redirect was stale, because
            # the two can drift independently.
            #
            # Only a not-found answer earns the advice below (#2082): given
            # on a throttled read, "delete the app" destroys a working one.
            local probe=0
            store_probe "$key" || probe=$?
            if [ "$probe" -ge 2 ]; then
                echo "[FAILED ] ${name}: cannot read ${key} from the secret store: ${STORE_PROBE_ERR}" >&2
                exit 1
            fi
            # A native app has no secret to lose: its id alone is the payload.
            if [ "$probe" -eq 1 ] && [ "$token" != native ]; then
                echo "[FAILED ] ${name}: app ${existing_id} exists in ZITADEL but ${key} holds" >&2
                echo "           no secret. ZITADEL returns a client secret exactly once, at" >&2
                echo "           creation -- it cannot be recovered from here, so writing the" >&2
                echo "           client id alone would leave a half payload, worse than the" >&2
                echo "           missing one. Restore ${key} from a backup, or delete the app" >&2
                echo "           in ZITADEL and re-run so it is created (and its secret" >&2
                echo "           captured) fresh." >&2
                exit 1
            fi

            local existing_secret='{}' desired
            [ "$probe" -eq 1 ] || existing_secret="$(store_read "$key")"
            desired="$(converge_secret "$consumer" "$client_id" "$existing_secret" "$project_id")"
            if [ "$desired" = "$existing_secret" ]; then
                echo "[ok     ] ${name} -- ${key} already converged"
                # A mirror that failed after its store write leaves the store
                # converged, so nothing else here would ever retry it. Never on
                # a dry run; a no-op without --mirror-openbao.
                if [ "$APPLY" = "true" ]; then
                    if printf '%s' "$existing_secret" | mirror_to_openbao "$key"; then
                        mirrored_keys+=("$key")
                    else
                        failed_mirrors="${failed_mirrors}${failed_mirrors:+ }${key}"
                    fi
                fi
            elif [ "$APPLY" != "true" ]; then
                echo "[dry-run] ${name} -- would converge non-secret fields in ${key}"
                converged=$((converged + 1))
            else
                prev_id="$(stored_client_id <<< "$existing_secret")"
                wrc=0
                printf '%s' "$desired" | store_write_and_mirror "$key" || wrc=$?
                case "$wrc" in
                    0) mirrored_keys+=("$key") ;;
                    2) failed_mirrors="${failed_mirrors}${failed_mirrors:+ }${key}" ;;
                    *) exit 1 ;;
                esac
                [ -z "$prev_id" ] || [ "$prev_id" = "$client_id" ] || rotated+=("${key}=${client_id}")
                echo "[converged] ${name} -> ${key} (client id ${client_id}, secret untouched)"
                converged=$((converged + 1))
            fi
            continue
        fi

        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] ${name} -> ${redirect}"
            echo "           would write client id/secret into ${key}"
            created=$((created + 1))
            continue
        fi

        local resp client_id client_secret
        resp="$(api_or_fail POST "/management/v1/projects/${project_id}/apps/oidc" \
            -d "$(oidc_config_payload "$redirect" "$name" "$token")")" || exit 1

        client_id=$(jq -r '.clientId // empty' <<< "$resp")
        client_secret=$(jq -r '.clientSecret // empty' <<< "$resp")
        # A native app is public: ZITADEL returns no secret, and none is needed.
        if [ -z "$client_id" ] || { [ -z "$client_secret" ] && [ "$token" != native ]; }; then
            echo "[FAILED ] ${name}: ZITADEL returned no clientId/clientSecret" >&2
            echo "$resp" | jq -r '.message // .' | head -3 >&2
            exit 1
        fi
        if [ "$consumer" = "openbao" ]; then
            openbao_key="$key"
            openbao_client_id="$client_id"
        fi

        # Built first, so a failed merge stops here instead of feeding the
        # store an empty payload.
        local merged
        merged="$(merge_secret "$key" "$consumer" "$client_id" "$client_secret" "$project_id")" || exit 1
        # A key that held a client before is a rotation (a fresh directory, or a
        # restore older than the app); one that held none is a first bootstrap,
        # whose consumers are still waiting for the Secret and start on their own.
        # Read before the write below replaces it. Never fatal: ZITADEL has issued
        # the secret, and only that write keeps it.
        prev_id="$(previous_client_id "$key")"
        wrc=0
        printf '%s' "$merged" | store_write_and_mirror "$key" || wrc=$?
        case "$wrc" in
            0) mirrored_keys+=("$key") ;;
            2) failed_mirrors="${failed_mirrors}${failed_mirrors:+ }${key}" ;;
            *) exit 1 ;;
        esac
        [ -z "$prev_id" ] || [ "$prev_id" = "$client_id" ] || rotated+=("${key}=${client_id}")
        echo "[created] ${name} -> ${key} (client ${client_id})"
        created=$((created + 1))
    done

    # Only now is headlamp-proxy guaranteed to exist, so only now can the
    # workforce provider be pinned to its client id. Deliberately after the loop
    # and not before it -- see the function's header comment for why the audience
    # is an app client id rather than the project id.
    reconcile_workforce_audience "$project_id"

    # Accumulated like failed_mirrors: the reconcile and the summary still run.
    local publish_failed=0
    publish_project_id "$project_id" || publish_failed=1

    # Same reasoning as the workforce provider above: OpenBao's client id is
    # only known once the "openbao" consumer's app has been found or created.
    # `|| openbao_failed=1` rather than exit here so the summary below still
    # prints -- the operator's dry-run habit is to read that line, and a
    # reconcile failure should not hide it.
    local openbao_failed=0
    reconcile_openbao_oidc "$openbao_key" "$openbao_client_id" || openbao_failed=1
    force_sync_mirrored "${mirrored_keys[@]}"
    restart_rotated_consumers ${rotated[@]+"${rotated[@]}"}

    echo
    echo "created: ${created}, updated: ${updated}, unchanged: ${skipped}, converged: ${converged}"
    if [ "$APPLY" != "true" ]; then
        echo
        echo "This was a DRY RUN. Nothing was created and nothing was written."
    fi
    if [ -n "$failed_mirrors" ]; then
        echo "[FAILED ] not mirrored to OpenBao: ${failed_mirrors} -- the managed store has them; re-run sync --apply" >&2
    fi
    if [ "$publish_failed" -ne 0 ]; then
        echo "[FAILED ] zitadel-project-id not published -- gke/configure keeps publishing the id already there (the previous build's, or the committed one on a first build); re-run sync --apply" >&2
    fi

    [ "$openbao_failed" -eq 0 ] || exit 1
    [ -z "$failed_mirrors" ] || exit 1
    [ "$publish_failed" -eq 0 ] || exit 1
}

case "$COMMAND" in
    sync) cmd_sync ;;
    *)
        sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
