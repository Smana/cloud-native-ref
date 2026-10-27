#!/usr/bin/env bash
# The owners list (scripts/provision/zitadel-owners.yaml) for zitadel-oidc-clients.sh
# (grants) and zitadel-idp.sh (GitHub links). Sourced. The caller defines api().
#
# An owner is identified by what nobody else can claim: the Google subject of the
# Google IdP link (providedUserId) and the numeric GitHub id. NEVER by userName or
# email: ZITADEL lets anyone register a local user with an owner's email.

# owners_json FILE prints a compact JSON array of
# {loginName, githubLogin, githubId, googleSubject, roles}.
#   rc 1  an entry is malformed (said on stderr)
#   rc 2  the file cannot be read or parsed: no parser, or unparseable YAML
# Parsers: python3 with PyYAML (preferred, what the repo's CI has), else mikefarah yq.
owners_json() {
    local file="${1:-}" raw
    [ -r "$file" ] || { echo "cannot read the owners file: ${file}" >&2; return 2; }
    if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
        raw="$(python3 -c 'import json,sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(json.dumps(d.get("owners") or [] if isinstance(d, dict) else d))' "$file" 2>/dev/null)" \
            || { echo "cannot parse ${file} (python3 + PyYAML)" >&2; return 2; }
    elif command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q mikefarah; then
        raw="$(yq -o=json '.owners // []' "$file" 2>/dev/null)" || { echo "cannot parse ${file} (yq)" >&2; return 2; }
    else
        echo "reading ${file} needs python3 with PyYAML (preferred) or mikefarah yq; neither is usable here" >&2; return 2
    fi
    jq -ce '
        def ok: (.loginName | type == "string" and length > 0)
            and (.githubLogin | type == "string" and test("^[A-Za-z0-9]([A-Za-z0-9-]{0,38})$"))
            and (.githubId | type == "string" and test("^[0-9]+$"))
            and (.googleSubject | type == "string" and test("^[0-9]+$"))
            and ((.roles // []) | type == "array" and all(.[]; type == "string" and length > 0));
        if type == "array" and all(.[]; type == "object" and ok)
        then map({loginName, githubLogin, githubId, googleSubject, roles: ((.roles // []) | unique)})
        else error("each owner needs a loginName, githubLogin, a numeric githubId and googleSubject (quoted strings) and a list of roles")
        end' <<< "$raw" 2>&1 \
        || { echo "invalid owners file ${file}" >&2; return 1; }
}

# zitadel_idp_id NAME: the id of the instance IdP template NAME; empty when it
# does not exist, rc 1 when the API fails (never "absent" on an error).
zitadel_idp_id() {
    local resp
    resp="$(api POST /admin/v1/idps/templates/_search -d '{"queries":[]}' 2>/dev/null)" || return 1
    jq -r --arg n "$1" 'first(.result[]? | select(.name == $n) | .id) // empty' <<< "$resp"
}

# resolve_owner_user_id GOOGLE_IDP_ID SUBJECT: the ZITADEL user whose Google IdP
# link has providedUserId SUBJECT, through the v2 links, by nothing else.
#   rc 0 exactly one, its id on stdout    rc 3 none    rc 4 several (nothing resolved)
#   rc 1 an API error (said on stderr)
resolve_owner_user_id() {
    local idp="$1" subject="$2" offset=0 page ids id resp found=() n
    while :; do
        page="$(api POST /v2/users -d "$(jq -cn --argjson o "$offset" '{query: {offset: $o, limit: 100}}')")" \
            || { echo "[FAILED ] cannot list ZITADEL users" >&2; return 1; }
        ids="$(jq -r '.result[]? | select(.machine == null) | .userId' <<< "$page")" || return 1
        for id in $ids; do
            resp="$(api POST "/v2/users/${id}/links/_search" -d '{}')" \
                || { echo "[FAILED ] cannot list the IdP links of ${id}" >&2; return 1; }
            if jq -e --arg i "$idp" --arg s "$subject" '.result[]? | select(.idpId == $i and .userId == $s)' <<< "$resp" >/dev/null; then
                found+=("$id")
            fi
        done
        n="$(jq -r '[.result[]?] | length' <<< "$page")"
        [ "$n" -ge 100 ] || break
        offset=$((offset + 100))
        [ "$offset" -lt 5000 ] || { echo "[FAILED ] more than 5000 users: not scanned" >&2; return 1; }
    done
    case "${#found[@]}" in
        0) return 3 ;;
        1) printf '%s\n' "${found[0]}" ;;
        *) return 4 ;;
    esac
}
