#!/usr/bin/env bash
# Repo-wide guard against the argv-leak class fixed in zitadel-idp.sh,
# zitadel-oidc-clients.sh, secret-store.sh and openbao-config.sh (also fixed,
# at the time, in harbor-oidc.sh -- since removed in favour of a declarative
# CONFIG_OVERWRITE_JSON, ADR-0028): a secret handed to jq via
# --arg/--argjson, or to curl via -H/--header or -u/--user, lands on that
# process's argv, readable by any process on the box via /proc/<pid>/cmdline
# for as long as it runs.
#
# EXTENDED to also scan curl -H/--header and -u/--user after
# zitadel-oidc-clients.sh's and zitadel-idp.sh's api() were both found
# passing the ZITADEL admin PAT as `-H "Authorization: Bearer ${PAT}"` --
# this guard existed at the time and only ever looked at jq, so it caught
# nothing. Both now use a `-K` config file instead (see api() in either
# script); the config-file path itself never touches argv, so it needs no
# entry here.
#
# EXTENDED AGAIN, to the CLOUD CLIs' value flags (see $VALUE_FLAGS below),
# after openbao-config.sh's secret_write was found handing the OpenBao root
# token and the recovery keys to `aws secretsmanager` on argv. Same class,
# third shape: this guard was already in place and matched only jq and curl,
# so it saw nothing. secret_write now delegates to
# scripts/lib/cloud-secret-store.sh's store_write, which takes the value on
# stdin.
#
# There is no gcloud counterpart to grep for on the secret-store path: the
# `gcloud secrets` commands take their value ONLY via --data-file, so the GCP
# half of that same function never leaked. --password is in the list as the
# gcloud-side shape that does exist (`gcloud sql users set-password
# --password=`), and --value as the same mistake one AWS service over (`aws
# ssm put-parameter --value`).
#
# NOT in the list: curl's -d/--data POST body. The long forms would be
# harmless, but the single-letter `-d` collides with ordinary shell (`[ -d
# "$SECRET_DIR" ]`, `mktemp -d "$TOKEN_DIR"`) and would flag both as leaks,
# and a guard with false positives is one people learn to ignore. The two
# scripts that POST credentials do it through a `-K` config file, which never
# touches argv at all.
#
# Each fixed site also has its own file-scoped assertion (grepping for the
# EXACT flag/variable name that leaked, in test-zitadel-idp-convergence.sh
# and test-zitadel-oidc-clients-secrets.sh) -- necessary because a
# functional round-trip test cannot tell "went in via stdin" from "went in
# via --arg" apart; both produce byte-identical JSON. Those are file-scoped
# by construction, and that is exactly how zitadel-oidc-clients.sh's three
# leaks went unnoticed while the other two scripts were being fixed: the
# guard only ever looked at the file someone had already opened.
#
# This is the pattern-level guard instead: it scans every scripts/*.sh for a
# jq --arg/--argjson, a curl -H/-u, or a cloud-CLI value flag whose VALUE is a
# variable with a credential-shaped NAME, so a script making the same mistake
# with a differently-named variable is still caught -- not just a
# byte-for-byte repeat of a site already found.
#
# KNOWN GAP, not silently: this only recognises a plain `"$var"`/"${var}"`
# value. `--arg p "$(gen_password)"` and `-H "Authorization: Bearer $(get_pat)"`
# -- both real shapes, the first found and fixed by hand in this same session
# (secret-store.sh's seed_body, openbao-config.sh's root token/recovery
# keys) -- bind no named variable at all, so there is no name here to judge.
# Flagging every `$(...)` was tried and rejected: most of them are ordinary
# (a timestamp, a resolved id) and the false-positive rate would make the
# guard noise people learn to ignore. This catches the named-variable shape
# reliably; it is not a proof that no argv leak exists.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# Case-insensitive, whole underscore-separated token: a name matches if ANY
# part of it (split on "_") equals one of these words. "key"/"keys" is broad
# -- generic enough that a future script naming an ordinary map key
# `--arg key ...` would trip it -- but it is what caught OpenBao's
# recovery_keys (Shamir key material, not a password or a token) during this
# guard's own development, with zero false positives anywhere else in the
# repo at the time it was added. Loosen it if that changes.
CRED_TOKENS="secret|password|passwd|token|credential|cookie|pat|apikey|privatekey|key|keys"

# Flags that put their VALUE on a cloud CLI's argv. Long forms only, and both
# `--flag value` and `--flag=value` are matched -- the AWS CLI accepts either
# and gcloud is written the second way by convention.
VALUE_FLAGS="--secret-string|--secret-binary|--value|--password"

is_cred_shaped() { # $1: variable name
    local part
    IFS='_' read -ra parts <<< "${1,,}"
    for part in "${parts[@]}"; do
        [[ "$part" =~ ^(${CRED_TOKENS})$ ]] && return 0
    done
    return 1
}

# The identifier following the LAST `$`/`${` in a grep hit -- e.g. `client`
# out of `--arg sec "$client_secret"`... no, `client_secret` out of that
# (the capture is greedy up to the last `$`, so it grabs the full name after
# it, not the jq arg name before it).
extract_hit_varname() {
    sed -E 's/.*\$\{?([A-Za-z_][A-Za-z0-9_]*).*/\1/' <<< "$1"
}

# Scan one directory tree (its *.sh, non-recursive, plus its lib/*.sh --
# the same shape scripts/ itself has) for a credential-shaped variable
# reaching jq's, curl's or a cloud CLI's argv. Prints one "FAIL file:line:
# ..." line per hit to stdout; returns 1 if it found anything, 0 if clean.
#
# Used for BOTH the real scan (against $HERE, i.e. scripts/) and the
# self-test below (against a throwaway fixture) -- the self-test is only
# proof of anything because it exercises this exact function, not a
# reimplementation of its logic.
scan_dir_for_argv_leaks() {
    local dir="$1" label="$2" found=0 file rel lineno line hit varname

    while IFS= read -r -d '' file; do
        rel="${label}/${file#"$dir"/}"

        while IFS=: read -r lineno line; do
            [ -z "${lineno:-}" ] && continue
            # Skip comment lines -- a fix's own explanation quoting the old,
            # now-removed pattern verbatim as documentation is not a leak
            # (same convention this repo's other file-scoped argv-leak
            # assertions use, e.g. test-zitadel-oidc-clients-secrets.sh's
            # code_grep).
            [[ "$line" =~ ^[[:space:]]*# ]] && continue

            # A source line can carry more than one --arg/--argjson (e.g.
            # `--arg id "$a" --arg sec "$b"` on the same line), so extract
            # every occurrence rather than just the first.
            while IFS= read -r hit; do
                [ -z "$hit" ] && continue
                varname="$(extract_hit_varname "$hit")"
                if is_cred_shaped "$varname"; then
                    printf '  FAIL %s:%s: jq --arg/--argjson exposes credential-shaped $%s on argv\n' \
                        "$rel" "$lineno" "$varname"
                    found=1
                fi
            done < <(grep -oE -- \
                '--arg(json)?[[:space:]]+[A-Za-z0-9_]+[[:space:]]+"\$\{?[A-Za-z_][A-Za-z0-9_]*[^"]*"' \
                <<< "$line")
        done < <(grep -nE -- '--arg(json)?[[:space:]]' "$file")

        while IFS=: read -r lineno line; do
            [ -z "${lineno:-}" ] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue

            while IFS= read -r hit; do
                [ -z "$hit" ] && continue
                varname="$(extract_hit_varname "$hit")"
                if is_cred_shaped "$varname"; then
                    printf '  FAIL %s:%s: curl -H/--header exposes credential-shaped $%s on argv\n' \
                        "$rel" "$lineno" "$varname"
                    found=1
                fi
            done < <(grep -oE -- \
                '(-H|--header)[[:space:]]+"[^"]*\$\{?[A-Za-z_][A-Za-z0-9_]*[^"]*"' \
                <<< "$line")

            while IFS= read -r hit; do
                [ -z "$hit" ] && continue
                varname="$(extract_hit_varname "$hit")"
                if is_cred_shaped "$varname"; then
                    printf '  FAIL %s:%s: curl -u/--user exposes credential-shaped $%s on argv\n' \
                        "$rel" "$lineno" "$varname"
                    found=1
                fi
            done < <(grep -oE -- \
                '(-u|--user)[[:space:]]+"[^"]*\$\{?[A-Za-z_][A-Za-z0-9_]*[^"]*"' \
                <<< "$line")
        done < <(grep -nE -- '(-H|--header|-u|--user)[[:space:]]' "$file")

        # Cloud-CLI value flags. Unlike the two above, the value may be
        # UNQUOTED (`--password=$pw`) as well as quoted, and may follow either
        # a space or an `=`, so the quote is optional on both sides here.
        while IFS=: read -r lineno line; do
            [ -z "${lineno:-}" ] && continue
            [[ "$line" =~ ^[[:space:]]*# ]] && continue

            while IFS= read -r hit; do
                [ -z "$hit" ] && continue
                varname="$(extract_hit_varname "$hit")"
                if is_cred_shaped "$varname"; then
                    printf '  FAIL %s:%s: cloud CLI value flag exposes credential-shaped $%s on argv\n' \
                        "$rel" "$lineno" "$varname"
                    found=1
                fi
            done < <(grep -oE -- \
                "(${VALUE_FLAGS})(=|[[:space:]]+)\"?\\\$\\{?[A-Za-z_][A-Za-z0-9_]*" \
                <<< "$line")
        done < <(grep -nE -- "(${VALUE_FLAGS})(=|[[:space:]])" "$file")
    done < <(find "$dir" -maxdepth 1 -name '*.sh' -print0 2>/dev/null; find "$dir/lib" -maxdepth 1 -name '*.sh' -print0 2>/dev/null)

    return "$found"
}

fail=0

# ── self-test: prove the scanner actually catches a leak ───────────────────
#
# Not a proof about the real repo (that is the scan below) -- proof that the
# DETECTOR ITSELF still works, against a fixture assembled here every run.
# Runs the exact same scan_dir_for_argv_leaks() the real scan uses, so a
# change that silently breaks detection (a regex typo, an accidentally
# narrowed pattern) fails HERE instead of quietly turning into a false
# "repo is clean".
FIXTURE_DIR="$(mktemp -d -t no-secret-argv-fixture.XXXXXX)"
trap 'rm -rf "$FIXTURE_DIR"' EXIT
FIXTURE_FILE="$FIXTURE_DIR/planted-leak.sh"
{
    echo '#!/usr/bin/env bash'
    # Three clean lines -- must NOT be flagged. Assembled the same fragmented
    # way as the leaks below (see the comment there for why): symmetry, not
    # necessity -- none of these is credential-shaped either way.
    printf 'curl -fsS -H "Content-Type: application/json" "$%s"\n' "URL"
    printf 'curl -fsS -K "$%s" "$%s"\n' "API_CURL_CONFIG" "URL"
    # A real value-flag shape with an ordinary variable name: the flag alone
    # must not be enough to fail, or the guard becomes noise. This is also the
    # KNOWN GAP made concrete -- rename it and the same line goes unflagged.
    printf 'aws ssm put-parameter --%s "$%s"\n' "value" "release_channel"
    # The five planted leaks -- MUST be flagged. Each is assembled from
    # fragments via printf rather than written as one literal line: this
    # FILE lives under scripts/ too, so the real scan below reads its own
    # source, and a leak shape written out whole here would flag ITSELF as
    # a repo finding. Splitting the flag/value apart with %s defeats the
    # very regex this line exists to exercise -- which is the point.
    printf 'curl -H "Authorization: Bearer ${%s}" "$%s"\n' "PAT" "URL"
    printf 'curl -u "admin:${%s}" "$%s"\n' "HARBOR_PASSWORD" "URL"
    printf "jq -n --arg id \"\$id\" --arg %s \"\$%s\" '{}'\\n" "sec" "client_secret"
    # The openbao-config.sh shape, both spellings: space-separated and quoted
    # (the aws CLI), then `=`-joined and bare (the gcloud convention).
    printf 'aws secretsmanager create-secret --name x --%s "$%s"\n' "secret-string" "root_token"
    printf 'gcloud sql users set-password u --%s=$%s\n' "password" "db_password"
} > "$FIXTURE_FILE"

fixture_output="$(scan_dir_for_argv_leaks "$FIXTURE_DIR" "planted-leak")"
fixture_rc=$?
fixture_count="$(grep -c '^  FAIL' <<< "$fixture_output")"
if [ "$fixture_rc" -eq 0 ]; then
    echo "  FAIL self-test: a planted -H/-u/--arg/value-flag leak went undetected -- the scanner itself is broken" >&2
    fail=1
else
    echo "  ok   self-test: scanner's exit code flags a planted leak"
fi
for want in \
    'curl -H/--header exposes credential-shaped $PAT' \
    'curl -u/--user exposes credential-shaped $HARBOR_PASSWORD' \
    'jq --arg/--argjson exposes credential-shaped $client_secret' \
    'cloud CLI value flag exposes credential-shaped $root_token' \
    'cloud CLI value flag exposes credential-shaped $db_password'
do
    if grep -qF -- "$want" <<< "$fixture_output"; then
        echo "  ok   self-test: caught \"${want}\""
    else
        echo "  FAIL self-test: did not catch \"${want}\"" >&2
        fail=1
    fi
done
# Exactly 5 findings -- not more. The three clean lines (an ordinary header, a
# non-secret config PATH variable, a value flag carrying a non-secret) must not
# also be flagged: a scanner that flags everything is as useless as one that
# flags nothing.
if [ "$fixture_count" != "5" ]; then
    echo "  FAIL self-test: expected exactly 5 findings on the fixture, got ${fixture_count}" >&2
    echo "$fixture_output" >&2
    fail=1
else
    echo "  ok   self-test: exactly the 5 planted leaks were flagged, no false positive on the clean lines"
fi

rm -rf "$FIXTURE_DIR"
trap - EXIT

# ── the real scan ────────────────────────────────────────────────────────
real_output="$(scan_dir_for_argv_leaks "$HERE" "scripts")"
real_rc=$?
if [ "$real_rc" -ne 0 ]; then
    echo "$real_output"
    fail=1
else
    echo "  ok   no scripts/*.sh passes a credential-shaped variable to jq --arg/--argjson, curl -H/--header, curl -u/--user, or a cloud CLI value flag"
fi

exit "$fail"
