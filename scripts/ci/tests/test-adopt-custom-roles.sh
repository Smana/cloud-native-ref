#!/usr/bin/env bash
#
# adopt-custom-roles.sh (GCP parity GP-15) with gcloud and tofu stubbed on PATH:
# a live role missing from state is imported, one in state is left alone, an
# absent one is left to the apply, and a soft-deleted one is reported, never imported.
# A describe that fails for any reason other than NOT_FOUND (expired credentials)
# must stop the deploy, not be read as "absent".
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"auth application-default print-access-token"*) echo fake-token ;;
  *"roles describe xplane_dns_editor_v3 "*)
    if [ -n "${STUB_AUTH_FAIL:-}" ]; then
      echo "ERROR: (gcloud.iam.roles.describe) There was a problem refreshing your current auth tokens: invalid_rapt" >&2
      exit 1
    fi
    echo "" ;;
  *"roles describe xplane_storage_admin_v3 "*) echo "True" ;;
  *"roles describe xplane_role_reader_v3 "*)
    echo "ERROR: (gcloud.iam.roles.describe) NOT_FOUND: The role named projects/ogenki-435905/roles/xplane_role_reader_v3 was not found." >&2
    exit 1 ;;
  *) exit 1 ;;
esac
EOF
cat >"$T/bin/tofu" <<EOF
#!/usr/bin/env bash
case "\$1" in
  state) printf '%s\n' module.gke.google_container_cluster.primary ;;
  import) echo "\$*" >>"$T/imports" ;;
esac
EOF
chmod +x "$T/bin/gcloud" "$T/bin/tofu"
adopt() { PATH="$T/bin:$PATH" bash "$ROOT/scripts/ops/gcp/adopt-custom-roles.sh" --project ogenki-435905 --suffix _v3 --apply; }

# out, rc and the auth_* values are read inside check's eval strings, where the
# linter cannot see them.
# shellcheck disable=SC2034
out="$(adopt 2>&1)"
# shellcheck disable=SC2034
rc=$?
# shellcheck disable=SC2034
auth_out="$(STUB_AUTH_FAIL=1 adopt 2>"$T/auth_err")"
# shellcheck disable=SC2034
auth_rc=$?
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }
check "exit 0" '[ "$rc" -eq 0 ]'
check "the live dns role is imported" 'grep -q "import -var-file=variables.tfvars google_project_iam_custom_role.crossplane_dns projects/ogenki-435905/roles/xplane_dns_editor_v3" "$T/imports"'
check "exactly one import" '[ "$(wc -l <"$T/imports")" -eq 1 ]'
check "the soft-deleted storage role is reported" 'grep -q "\[deleted\].*xplane_storage_admin_v3" <<<"$out"'
check "the absent reader role is left to the apply" 'grep -q "\[absent \].*xplane_role_reader_v3" <<<"$out"'
check "the absent line names the burned-ID fix" 'grep "\[absent \]" <<<"$out" | grep -q "bump custom_role_suffix"'
check "a non-NOT_FOUND describe failure exits non-zero" '[ "$auth_rc" -ne 0 ]'
check "  ...naming the role and the credentials" 'grep -q "xplane_dns_editor_v3" "$T/auth_err" && grep -qi "credentials" "$T/auth_err"'
check "  ...not reported as absent" '! grep -q "\[absent \].*xplane_dns_editor_v3" <<<"$auth_out$(cat "$T/auth_err")"'
check "  ...importing nothing more" '[ "$(wc -l <"$T/imports")" -eq 1 ]'
check "no token is ever printed" '! grep -q fake-token <<<"$out$auth_out$(cat "$T/auth_err")"'
[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
