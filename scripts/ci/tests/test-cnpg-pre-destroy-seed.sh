#!/usr/bin/env bash
# Contract test for cnpg-pre-destroy-seed.sh against a stub kubectl and a stub
# cnpg-promote-seed.sh -- no cloud call, no live cluster.
#
# The hook runs inside both clouds' teardowns, where its one job beyond
# seeding is never to block them, and to say so loudly when it could not
# seed. Each case below is a way that contract breaks silently:
#   - a failed promotion must warn and exit 0, not stop the destroy;
#   - CNPG_SKIP_PRE_DESTROY_SEED=true must skip before touching the cluster;
#   - an unreachable cluster must warn about the data loss -- it used to print
#     "SQLInstance CRD not available", which reads as "nothing to seed";
#   - discovery must pick claims by spec.backup and strip `xplane-` from the
#     seed and alias names (the bucket lifecycle rule expires `xplane-*`);
#   - --cloud must reach the promote script unchanged.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/../../ops/k8s/cnpg-pre-destroy-seed.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}
check_contains() { # label needle haystack
    if printf '%s' "$3" | grep -qF -- "$2"; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: %q not found in output:\n%s\n' "$1" "$2" "$3"; fail=1; fi
}
check_absent() { # label needle haystack
    if printf '%s' "$3" | grep -qF -- "$2"; then printf '  FAIL %s: %q found in output:\n%s\n' "$1" "$2" "$3"; fail=1
    else printf '  ok   %s\n' "$1"; fi
}

# The hook calls "$(dirname "$0")/cnpg-promote-seed.sh", so it runs from a copy
# with the stub beside it.
mkdir -p "$WORK/k8s" "$WORK/bin"
cp "$SRC" "$WORK/k8s/cnpg-pre-destroy-seed.sh"
HOOK="$WORK/k8s/cnpg-pre-destroy-seed.sh"

cat > "$WORK/k8s/cnpg-promote-seed.sh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$PROMOTE_LOG"
case "$*" in *xplane-harbor*) exit 1 ;; esac
exit 0
EOF

# MODE: ok | nocrd | unreach. Every call is logged so the test can assert that
# each one is time-bounded.
cat > "$WORK/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$KUBECTL_LOG"
[ "$MODE" = unreach ] && { echo "Unable to connect to the server: dial tcp 10.0.0.2:443: i/o timeout" >&2; exit 1; }
args=()
for a in "$@"; do case "$a" in --request-timeout*) ;; *) args+=("$a") ;; esac; done
case "${args[0]}" in
  get)
    case "${args[1]}" in
      ns) echo "namespace/default" ;;
      sqlinstance) cat <<'J'
{"items":[
 {"metadata":{"namespace":"security","name":"xplane-zitadel"},"spec":{"backup":{"schedule":"0 2 * * *"}}},
 {"metadata":{"namespace":"tooling","name":"xplane-harbor"},"spec":{"backup":{"schedule":"0 2 * * *"}}},
 {"metadata":{"namespace":"apps","name":"xplane-nobackup"},"spec":{}}]}
J
      ;;
    esac ;;
  api-resources)
    echo "NAME           SHORTNAMES   APIVERSION                 NAMESPACED   KIND"
    [ "$MODE" = nocrd ] || echo "sqlinstances                cloud.ogenki.io/v1alpha1   true         SQLInstance" ;;
esac
EOF

printf '#!/bin/sh\necho 20261006\n' > "$WORK/bin/date"
chmod +x "$WORK/k8s/"*.sh "$WORK/bin/"*

export PROMOTE_LOG="$WORK/promote.log" KUBECTL_LOG="$WORK/kubectl.log"
run() { # env assignments... -- hook args...
    : > "$PROMOTE_LOG"; : > "$KUBECTL_LOG"
    local envs=()
    while [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    out="$(env "${envs[@]}" PATH="$WORK/bin:$PATH" bash "$HOOK" "$@" 2>&1)"; rc=$?
}

echo "case: two backed-up claims, harbor's promotion fails (gcp)"
run MODE=ok -- --cloud gcp --bucket proj-ogenki-cnpg-backups
check "exits 0 although a promotion failed" 0 "$rc"
check_contains "zitadel promoted, xplane- stripped, --cloud gcp passed through" \
  "--cloud gcp --bucket proj-ogenki-cnpg-backups --cluster xplane-zitadel --namespace security --apply --seed zitadel-20261006 --rotate-alias zitadel-pre-destroy" \
  "$(cat "$PROMOTE_LOG")"
check_contains "harbor promoted" "--cluster xplane-harbor --namespace tooling" "$(cat "$PROMOTE_LOG")"
check_contains "failed promotion warns" "[warn] seed for xplane-harbor failed" "$out"
check "a claim without spec.backup is not promoted" 2 "$(wc -l < "$PROMOTE_LOG" | tr -d ' ')"
check "every kubectl call carries --request-timeout" "" "$(grep -v -- '--request-timeout' "$KUBECTL_LOG")"

echo "case: --cloud aws passthrough"
run MODE=ok -- --cloud aws --bucket eu-west-3-ogenki-cnpg-backups
check "exits 0" 0 "$rc"
check_contains "--cloud aws reaches the promote script" "--cloud aws --bucket eu-west-3-ogenki-cnpg-backups --cluster xplane-zitadel" "$(cat "$PROMOTE_LOG")"

echo "case: CNPG_SKIP_PRE_DESTROY_SEED=true"
run MODE=ok CNPG_SKIP_PRE_DESTROY_SEED=true -- --cloud gcp --bucket b
check "exits 0" 0 "$rc"
check_contains "says it skipped" "[skip] CNPG_SKIP_PRE_DESTROY_SEED=true" "$out"
check "never touches the cluster" "" "$(cat "$KUBECTL_LOG")"
check "promotes nothing" "" "$(cat "$PROMOTE_LOG")"

echo "case: cluster unreachable"
run MODE=unreach -- --cloud gcp --bucket b
check "exits 0" 0 "$rc"
check_contains "warns that the cluster is unreachable" "[warn] cluster unreachable" "$out"
check_contains "names the data loss" "loses everything since" "$out"
check_absent "does not claim the CRD is missing" "SQLInstance CRD not available" "$out"
check "promotes nothing" "" "$(cat "$PROMOTE_LOG")"

echo "case: reachable, SQLInstance CRD absent"
run MODE=nocrd -- --cloud gcp --bucket b
check "exits 0" 0 "$rc"
check_contains "says the CRD is not available" "SQLInstance CRD not available" "$out"
check "promotes nothing" "" "$(cat "$PROMOTE_LOG")"

echo "case: argument errors"
run MODE=ok -- --cloud gcp
check "missing --bucket exits 2" 2 "$rc"
run MODE=ok -- --cloud azure --bucket b
check "unknown --cloud exits 2" 2 "$rc"

exit "$fail"
