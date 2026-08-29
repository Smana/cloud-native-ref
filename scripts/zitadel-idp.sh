#!/usr/bin/env bash
#
# Register the Google Workspace identity provider and the groups Action in
# ZITADEL, from configuration this repository owns.
#
# WHY THIS EXISTS
#
# Both of these were configured by hand in a console, on aws-0, and lived
# nowhere else. On 2026-08-28 gcp-0 came up with its own fresh ZITADEL and had
# neither, and the credentials could not be recovered from either secret store
# because they had never been put in one -- 68 secrets in AWS Secrets Manager,
# not a Google key among them.
#
# That is worse than it sounds. aws-0's SQLInstance restores from the frozen
# `zitadel-20260719` prefix on EVERY rebuild, so anything configured in ZITADEL
# after that snapshot is discarded the next time the cluster is rebuilt. The
# Google IdP was one rebuild away from being lost on AWS too.
#
# So: the credentials go in the secret store, the Action goes in git, and this
# script applies both. Same shape as zitadel-oidc-clients.sh, deliberately --
# read that one first if this is unfamiliar.
#
# WHAT IT DOES
#
#   1. Reads the ZITADEL admin PAT from the cluster.
#   2. Reads the Google OAuth client from the secret store (`zitadel-google-idp`).
#   3. Creates the Google IdP if missing, INSTANCE-level, and leaves an existing
#      one alone -- recreating rotates nothing but does orphan user links.
#   4. Uploads scripts/zitadel-actions/groups-from-roles.js as a v1 Action.
#   5. Wires that Action into flow 2 (CustomiseToken) on BOTH triggers.
#
# Usage:
#   zitadel-idp.sh sync --cluster gcp-0 --cloud gcp [--project ID] [--apply]
#   zitadel-idp.sh sync --cluster aws-0 --cloud aws [--region R]  [--apply]
#
# Dry-run unless --apply. The client secret is never printed.
#
# THE ONE THING TO DO BY HAND, ONCE PER CLUSTER
#
# Google OAuth clients accept MANY authorized redirect URIs -- unlike a GitHub
# OAuth app, which accepts exactly one and is why app-wizard needs a separate
# app per cluster. So one Google client serves every cluster, provided each
# cluster's callback is listed on it:
#
#   https://auth.<public_domain_name>/ui/login/login/externalidp/callback
#
# That path is ZITADEL's, verified against a live instance rather than
# constructed: it answers 200 while a nonsense path under the same prefix 404s.
# This script CANNOT add it for you -- it is a Google-side setting -- so it
# prints the URI and checks nothing about it. A missing entry fails at Google
# with redirect_uri_mismatch, naming neither ZITADEL nor the cluster.

set -o errexit
set -o nounset
set -o pipefail

# gcloud must run as the identity OpenTofu uses, not the CLI account.
# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/lib/gcloud-adc.sh"
# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$(dirname "$0")/lib/cloud-secret-store.sh"
# shellcheck source=scripts/lib/zitadel-pat.sh
. "$(dirname "$0")/lib/zitadel-pat.sh"

COMMAND="${1:-}"
[ $# -gt 0 ] && shift

CLUSTER=""
CLOUD=""
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
GCP_PROJECT=""
APPLY="false"

IDP_NAME="Google Workspace"
IDP_SECRET_KEY="zitadel-google-idp" # pragma: allowlist secret
# THE ACTION NAME IS NOT A LABEL. ZITADEL v1 looks up a function in the script
# BY THIS NAME and runs it, so it must be a valid JS identifier and must match
# the function in ACTION_FILE exactly.
#
# It was "groups-from-roles" for one day. Hyphens cannot appear in a JS
# identifier, so no function could ever carry that name, and ZITADEL logged
#     action run failed: function not found
# on every token request. With allowedToFail=false that FAILS TOKEN ISSUANCE --
# which surfaces in Grafana as "Failed to get token from provider" and in the
# ZITADEL UI as nothing at all. Nothing in the API rejects the mismatched name;
# it is accepted, stored, and only ever fails at runtime.
#
# assert_action_name_matches_function() below makes that unrepeatable.
ACTION_NAME="groupsFromRoles"
ACTION_FILE="$(cd "$(dirname "$0")" && pwd)/zitadel-actions/groups-from-roles.js"

while [ $# -gt 0 ]; do
    case "$1" in
        --cluster) CLUSTER="$2"; shift 2 ;;
        --cloud)   CLOUD="$2"; shift 2 ;;
        --region)  REGION="$2"; shift 2 ;;
        --project) GCP_PROJECT="$2"; shift 2 ;;
        --apply)   APPLY="true"; shift ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ "$COMMAND" = "sync" ] || { sed -n '2,60p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ -n "$CLUSTER" ] || { echo "--cluster is required" >&2; exit 2; }
case "$CLOUD" in aws|gcp) ;; *) echo "--cloud must be aws or gcp" >&2; exit 2 ;; esac
[ -r "$ACTION_FILE" ] || { echo "cannot read ${ACTION_FILE}" >&2; exit 1; }

# ── zitadel api ───────────────────────────────────────────────────────────────

PAT="$(resolve_zitadel_pat)" || exit 1

: "${IDP_URL:?set IDP_URL to the ZITADEL base URL, e.g. https://auth.gcp.cloud.ogenki.io}"

# Same split-DNS escape hatch as zitadel-oidc-clients.sh: pins the host for curl
# only, keeping SNI and certificate verification intact.
CURL_RESOLVE=()
[ -n "${IDP_RESOLVE:-}" ] && CURL_RESOLVE=(--resolve "$IDP_RESOLVE")

api() {
    local method="$1" path="$2"
    shift 2
    curl -fsS -X "$method" "${IDP_URL}${path}" \
        ${CURL_RESOLVE[@]+"${CURL_RESOLVE[@]}"} \
        -H "Authorization: Bearer ${PAT}" \
        -H "Content-Type: application/json" \
        "$@"
}

# ── the identity provider ─────────────────────────────────────────────────────
#
# INSTANCE-level (/admin/v1), not org-level (/management/v1). Both answer on
# this instance and both would work; instance scope means every org inherits the
# provider, which is what a single-tenant platform wants. Org scope would tie it
# to the `platform` org that zitadel-oidc-clients.sh creates, and a second org
# would silently have no Google login.
# TEMPLATES, not /admin/v1/idps/_search.
#
# ZITADEL carries two generations of IdP API on the same prefix. The legacy
# /admin/v1/idps/_search covers hand-rolled OIDC/JWT providers; the typed
# providers created by POST /admin/v1/idps/google are "templates" and are
# invisible to it. Both return 200, and the legacy one answers a search for a
# template-created provider with `{"details":{...}}` and no result array at all
# -- indistinguishable from "nothing exists".
#
# That is not cosmetic: this function decides whether to create. Pointed at the
# legacy endpoint it reported the freshly created Google provider as absent, so
# a second --apply would have added a DUPLICATE IdP, which is precisely what the
# skip below exists to prevent. Caught by re-running the dry run after an apply.
idp_id_by_name() {
    api POST /admin/v1/idps/templates/_search -d '{"queries":[]}' 2>/dev/null \
        | jq -r --arg n "$IDP_NAME" '.result[]? | select(.name == $n) | .id' | head -1
}

ensure_idp() {
    local existing
    existing="$(idp_id_by_name || true)"
    if [ -n "$existing" ]; then
        echo "[skip   ] IdP '${IDP_NAME}' already exists (${existing}); leaving it alone"
        echo "           recreating would orphan every existing user link to it"
        return 0
    fi

    local blob client_id client_secret
    blob="$(store_read "$IDP_SECRET_KEY")"
    if [ -z "$blob" ]; then
        echo "[FAILED ] ${IDP_SECRET_KEY} not found in the ${CLOUD} store." >&2
        echo "           Create it from the Google OAuth client's JSON:" >&2
        echo '           jq -c "{client_id: .web.client_id, client_secret: .web.client_secret}"' >&2
        return 1
    fi
    client_id="$(jq -r '.client_id // empty' <<< "$blob")"
    client_secret="$(jq -r '.client_secret // empty' <<< "$blob")"
    if [ -z "$client_id" ] || [ -z "$client_secret" ]; then
        echo "[FAILED ] ${IDP_SECRET_KEY} has no client_id/client_secret" >&2
        return 1
    fi

    if [ "$APPLY" != "true" ]; then
        echo "[dry-run] would create IdP '${IDP_NAME}' (client ${client_id})"
        return 0
    fi

    # isAutoCreation/isAutoUpdate: a Workspace user logging in for the first time
    # gets a ZITADEL user created from their Google profile, and later profile
    # changes follow. Without them the login succeeds and then dead-ends on "user
    # not found", which is the least helpful possible outcome.
    #
    # isLinkingAllowed lets an existing local user attach Google rather than
    # ending up with two accounts for one human.
    local resp id
    resp="$(jq -n --arg n "$IDP_NAME" --arg ci "$client_id" --arg cs "$client_secret" \
        '{name: $n, clientId: $ci, clientSecret: $cs,
          scopes: ["openid","profile","email"],
          providerOptions: {isLinkingAllowed: true, isCreationAllowed: true,
                            isAutoCreation: true, isAutoUpdate: true}}' \
        | api POST /admin/v1/idps/google -d @-)"
    id="$(jq -r '.id // empty' <<< "$resp")"
    if [ -z "$id" ]; then
        echo "[FAILED ] IdP creation returned no id: $(jq -c '.' <<< "$resp" | head -c 200)" >&2
        return 1
    fi
    echo "[created] IdP '${IDP_NAME}' (${id}, client ${client_id})"
}

# The check that would have caught the day-long outage described at ACTION_NAME:
# a mismatch is invisible until a real user tries to log in, so it is worth
# failing the script over rather than discovering it in a browser.
assert_action_name_matches_function() {
    if ! grep -qE "^[[:space:]]*function[[:space:]]+${ACTION_NAME}[[:space:]]*\\(" "$ACTION_FILE"; then
        echo "[FAILED ] ${ACTION_FILE##*/} defines no 'function ${ACTION_NAME}('." >&2
        echo "           ZITADEL calls the function NAMED AFTER THE ACTION. If they" >&2
        echo "           disagree it stores fine and then fails every token request" >&2
        echo "           with 'action run failed: function not found'." >&2
        echo "           Found instead:" >&2
        grep -nE "^[[:space:]]*function[[:space:]]+[A-Za-z_$][A-Za-z0-9_$]*" "$ACTION_FILE" >&2 || true
        return 1
    fi
}

# -- the login policy ---------------------------------------------------------
#
# CREATING AN IDP DOES NOT ENABLE IT. This is the step whose absence produced
# "User not found" on gcp-0 while every field of the provider read correct.
#
# In ZITADEL an IdP template and the login policy are separate objects. The
# template says how to talk to Google; the LOGIN POLICY says which providers the
# login UI may offer. With the template present and the policy empty, ZITADEL
# renders no Google button, so an email typed at the login screen is resolved as
# a LOCAL username -- and on a fresh instance no such user exists. The error is
# therefore literally true and points at entirely the wrong thing: the IdP is
# fine, autoCreation is on, and the user cannot reach any of it.
#
# Nothing warns about this. `allowExternalIdp: true` is the instance default and
# stays true with zero providers attached, so the policy reads "external login
# allowed" while allowing none.
#
# INSTANCE policy (/admin/v1), matching the IdP's own scope. An org whose policy
# is still the default inherits this; an org that has overridden its login
# policy does not, and that case is reported below rather than silently assumed.
login_policy_has_idp() {
    local idp_id="$1"
    api GET /admin/v1/policies/login 2>/dev/null \
        | jq -e --arg id "$idp_id" '.policy.idps[]? | select(.idpId == $id)' >/dev/null 2>&1
}

ensure_login_policy_idp() {
    local idp_id="$1"

    if [ -z "$idp_id" ]; then
        echo "[dry-run] would add the IdP to the instance login policy"
        return 0
    fi

    if login_policy_has_idp "$idp_id"; then
        echo "[skip   ] IdP already on the instance login policy"
    elif [ "$APPLY" != "true" ]; then
        echo "[dry-run] would add IdP ${idp_id} to the instance login policy"
        return 0
    else
        jq -n --arg id "$idp_id" \
            '{idpId: $id, ownerType: "IDP_OWNER_TYPE_SYSTEM"}' \
            | api POST /admin/v1/policies/login/idps -d @- >/dev/null
        echo "[added  ] IdP ${idp_id} to the instance login policy"
    fi

    # An org that has customised its login policy does NOT inherit the instance
    # one. Report rather than guess: silently writing an org policy would create
    # the override this platform does not want.
    local is_default
    is_default="$(api GET /management/v1/policies/login 2>/dev/null | jq -r '.policy.isDefault // "unknown"')"
    if [ "$is_default" != "true" ]; then
        echo "[WARN   ] the org login policy is NOT the instance default (isDefault=${is_default})." >&2
        echo "           It will not inherit the provider added above; add it there too via" >&2
        echo "           POST /management/v1/policies/login/idps with idpId ${idp_id}" >&2
    fi
}

# ── the groups action ─────────────────────────────────────────────────────────
#
# v1 Actions are ORG-level, with no instance-level equivalent -- so unlike the
# IdP above this cannot follow the same scope. That asymmetry is ZITADEL's, not
# a choice made here.
action_id_by_name() {
    api POST /management/v1/actions/_search -d '{"query":{}}' 2>/dev/null \
        | jq -r --arg n "$ACTION_NAME" '.result[]? | select(.name == $n) | .id' | head -1
}

ensure_action() {
    local script existing payload
    script="$(cat "$ACTION_FILE")"
    existing="$(action_id_by_name || true)"

    # Everything human-readable goes to stderr, because this function's STDOUT is
    # the action id and the caller reads it through command substitution. The
    # first version printed these to stdout and they vanished into $(...) --
    # a dry run that silently reported nothing about the action at all.
    if [ "$APPLY" != "true" ]; then
        if [ -n "$existing" ]; then
            echo "[dry-run] would UPDATE action '${ACTION_NAME}' (${existing}) from ${ACTION_FILE##*/}" >&2
        else
            echo "[dry-run] would create action '${ACTION_NAME}' from ${ACTION_FILE##*/}" >&2
        fi
        # A placeholder rather than the empty string, so the caller still walks
        # the flow-binding branch and a dry run shows the whole plan.
        echo "${existing:-DRYRUN-ACTION}"
        return 0
    fi

    # allowedToFail: false. A failing Action here breaks token issuance, which
    # sounds harsh but is correct: silently issuing tokens with no groups claim
    # would authorise people at the WRONG level rather than not at all.
    payload="$(jq -n --arg n "$ACTION_NAME" --arg s "$script" \
        '{name: $n, script: $s, timeout: "10s", allowedToFail: false}')"

    local id
    if [ -n "$existing" ]; then
        jq -n --argjson b "$payload" '$b' | api PUT "/management/v1/actions/${existing}" -d @- >/dev/null
        id="$existing"
        echo "[updated] action '${ACTION_NAME}' (${id})" >&2
    else
        id="$(jq -n --argjson b "$payload" '$b' | api POST /management/v1/actions -d @- | jq -r '.id // empty')"
        [ -n "$id" ] || { echo "[FAILED ] action creation returned no id" >&2; return 1; }
        echo "[created] action '${ACTION_NAME}' (${id})" >&2
    fi
    echo "$id"
}

# Flow 2 is CustomiseToken; 4 and 5 are PreUserinfoCreation and
# PreAccessTokenCreation. Verified against a live instance rather than taken
# from documentation: GET /management/v1/flows/2 reports
# Action.Flow.Type.CustomiseToken.
#
# BOTH triggers, because they are not interchangeable. Grafana reads the
# /userinfo response; a consumer validating the JWT itself reads the access
# token. Wiring one leaves the other silently groupless -- which presents as
# "SSO works but nobody has permissions", for only some of the tools.
ensure_flow() {
    local action_id="$1" trigger
    for trigger in 4 5; do
        if [ "$APPLY" != "true" ]; then
            echo "[dry-run] would bind action to flow 2 trigger ${trigger}"
            continue
        fi
        jq -n --arg a "$action_id" '{actionIds: [$a]}' \
            | api POST "/management/v1/flows/2/trigger/${trigger}" -d @- >/dev/null
        echo "[bound  ] flow 2 (CustomiseToken) trigger ${trigger}"
    done
}

# ── main ──────────────────────────────────────────────────────────────────────

echo "cluster:  ${CLUSTER} (${CLOUD})"
echo "idp:      ${IDP_URL}"
echo "scope:    instance (/admin/v1) for the IdP, org (/management/v1) for the action"
echo

ensure_idp

# Re-read rather than threading a return value out of ensure_idp: that function
# has three exit paths (skip / dry-run / create) and only one of them knows an
# id. Looking it up once here is the same answer in every case.
ensure_login_policy_idp "$(idp_id_by_name || true)"

# Fails the run if the action name and the JS function disagree -- see ACTION_NAME.
assert_action_name_matches_function

ACTION_ID="$(ensure_action | tail -1)"
if [ -n "$ACTION_ID" ]; then
    ensure_flow "$ACTION_ID"
elif [ "$APPLY" = "true" ]; then
    echo "[FAILED ] no action id; flow not wired" >&2
    exit 1
fi

echo
echo "Google-side, once per cluster -- this script cannot do it:"
echo "  add this to the OAuth client's Authorized redirect URIs"
echo "    ${IDP_URL}/ui/login/login/externalidp/callback"
echo
if [ "$APPLY" != "true" ]; then
    echo "This was a DRY RUN. Re-run with --apply."
fi
