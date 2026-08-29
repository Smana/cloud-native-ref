# ZITADEL Bootstrap and Reconciliation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make ZITADEL's admin credential survive a database restore, so the setup scripts can reconcile configuration on any cluster, however old its seed.

**Architecture:** The admin PAT is persisted to the hosting cloud's secret store the first time it exists, and read from there afterwards. Two new sourced libraries carry the logic once instead of per script: `cloud-secret-store.sh` (the store I/O three scripts already duplicate) and `zitadel-pat.sh` (the resolve-or-seed rule). The four setup scripts then become reconcilers that converge configuration rather than skipping what already exists.

**Tech Stack:** Bash 5, AWS CLI v2, gcloud, kubectl, jq, ZITADEL management API v1.

**Spec:** [`docs/superpowers/specs/2026-08-29-zitadel-bootstrap-and-reconciliation-design.md`](../specs/2026-08-29-zitadel-bootstrap-and-reconciliation-design.md)

## Global Constraints

- **Shell**: `set -o errexit -o nounset -o pipefail` in every script; `shellcheck -S warning` must pass clean.
- **Never print a credential.** Tokens and client secrets go from source to sink without passing through stdout. Log statuses and lengths, never values.
- **Log to stderr inside any function whose stdout is captured as data.** `log` to stdout from a function used in `$(...)` puts the log line inside the value — this already put a timestamped line inside `.tls/ca.pem`.
- **Secret naming is per cloud**: AWS uses `/` (`zitadel/iam-admin-pat`), GCP forbids it and uses `-` (`zitadel-iam-admin-pat`).
- **Idempotent**: re-running any script changes nothing the second time and exits 0.
- **Dry-run by default**; writes happen only under `--apply`.
- **Never rotate a client secret to fix a non-secret field.** ZITADEL returns a client secret exactly once.
- **gcloud goes through `gcp_gcloud`** from `scripts/lib/gcloud-adc.sh` — never bare `gcloud`.

## Prerequisite

**PR #1921 must be merged before Task 1 starts.** It adds
`scripts/lib/gcloud-adc.sh`, which Task 1's library sources, and it establishes
the `scripts/lib/` directory this plan puts two more files into. Without it,
Task 1 Step 4 fails on a missing source file.

Check with:

```bash
test -f scripts/lib/gcloud-adc.sh && echo ready || echo "merge #1921 first"
```

Every `gcloud` call written in this plan goes through `gcp_gcloud` from that
library. Calling `gcloud` directly reintroduces the bug #1921 fixed: gcloud uses
the CLI account while everything else on GCP uses Application Default
Credentials, and the two can be different identities with different permissions.

## Design refinement adopted here

The spec proposed rehydrating the PAT into the cluster with an ExternalSecret. **That is dropped**, and the spec is corrected in Task 6.

Nothing in the cluster consumes this credential — `grep -rn iam-admin-pat` across `security/ infrastructure/ tooling/ observability/ apps/` returns nothing; only operator scripts read it. An ExternalSecret would therefore add a resource that no workload uses, and it would target the same Secret name the Helm chart creates at FirstInstance, so the two would contend for ownership on a fresh bootstrap.

Reading directly from the cloud secret store is simpler, has no ownership conflict, and works identically on a fresh and a restored cluster.

## File Structure

| File | Responsibility |
|---|---|
| `scripts/lib/cloud-secret-store.sh` | **Create.** `store_exists` / `store_read` / `store_write`, one copy, both clouds. Extracted from three scripts that each carry their own. |
| `scripts/lib/zitadel-pat.sh` | **Create.** `resolve_zitadel_pat` — the store-first, seed-from-cluster-once rule, and the loud failure when neither source has it. |
| `scripts/test-cloud-secret-store.sh` | **Create.** Exercises the store I/O against stub CLIs on `PATH`. |
| `scripts/test-zitadel-pat.sh` | **Create.** Exercises resolution order and the failure path. |
| `scripts/zitadel-oidc-clients.sh` | **Modify.** Source both libs; delete its inline store helpers and PAT block. |
| `scripts/zitadel-idp.sh` | **Modify.** Same, plus make `ensure_*` converge. |
| `scripts/harbor-oidc.sh` | **Modify.** Same, plus reconcile Harbor's stored OIDC endpoint. |
| `scripts/secret-store.sh` | **Modify.** Source the PAT lib only where it needs the token. |
| `website/content/docs/get-started/sso.md` | **Modify.** The PAT is no longer a manual prerequisite. |
| `website/content/docs/guides/migrate-the-identity-provider.md` | **Create.** The GCP-only relocation procedure. |

---

### Task 1: Extract the cloud secret store I/O

Three scripts carry byte-similar copies of `store_read`, `store_write` and `store_exists`. The PAT resolver needs them too, and a fourth copy is how the GCP gate became fifteen.

**Files:**
- Create: `scripts/lib/cloud-secret-store.sh`
- Create: `scripts/test-cloud-secret-store.sh`

**Interfaces:**
- Consumes: `scripts/lib/gcloud-adc.sh` (`gcp_gcloud`)
- Produces: `store_exists <name>` → exit 0/1; `store_read <name>` → value on stdout, exit 1 if absent; `store_write <name>` → reads value on **stdin**, creates or versions. All three read `CLOUD`, `REGION`, `GCP_PROJECT` from the caller's environment.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-cloud-secret-store.sh`:

```bash
#!/usr/bin/env bash
# Store I/O against stub CLIs, so no cloud call is made.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
fail=0
check() { # label expected actual
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}

cat > "$STUB/aws" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "get-secret-value" ] && { echo '{"token":"aws-secret"}'; exit 0; }; done
for a in "$@"; do [ "$a" = "describe-secret" ] && exit 0; done
exit 0
EOF
cat > "$STUB/gcloud" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "access" ] && { echo '{"token":"gcp-secret"}'; exit 0; }; done
exit 0
EOF
chmod +x "$STUB/aws" "$STUB/gcloud"
PATH="$STUB:$PATH"

# shellcheck source=scripts/lib/cloud-secret-store.sh
. "$HERE/lib/cloud-secret-store.sh"

CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
check "aws read"    '{"token":"aws-secret"}' "$(store_read any)"
store_exists any && r=yes || r=no
check "aws exists"  yes "$r"

CLOUD=gcp REGION="" GCP_PROJECT=proj
check "gcp read"    '{"token":"gcp-secret"}' "$(store_read any)"

exit $fail
```

- [ ] **Step 2: Run it and watch it fail**

```bash
chmod +x scripts/test-cloud-secret-store.sh && ./scripts/test-cloud-secret-store.sh
```

Expected: FAIL — `lib/cloud-secret-store.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `scripts/lib/cloud-secret-store.sh`. Copy the three function bodies verbatim from `scripts/zitadel-oidc-clients.sh` (`store_exists`, `store_read`, `store_write`, currently around lines 102–160) so behaviour is unchanged, and route every `gcloud` through `gcp_gcloud`:

```bash
# shellcheck shell=bash
#
# Read and write secrets in the hosting cloud's store. Both clouds, one copy.
#
# Extracted from zitadel-oidc-clients.sh, zitadel-idp.sh and harbor-oidc.sh,
# which each carried their own. A fourth copy was about to be written for the
# PAT resolver, and this repository already knows where that ends -- the GCP
# opt-in gate became fifteen hand-written copies with four scripts missing it.
#
# Reads CLOUD, REGION and GCP_PROJECT from the caller.

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "${BASH_SOURCE[0]}")/gcloud-adc.sh"

store_exists() {
    case "$CLOUD" in
        aws) aws secretsmanager describe-secret ${REGION:+--region "$REGION"} \
                 --secret-id "$1" >/dev/null 2>&1 ;;
        gcp) gcp_gcloud secrets describe "$1" ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                 >/dev/null 2>&1 ;;
    esac
}

store_read() {
    case "$CLOUD" in
        aws) aws secretsmanager get-secret-value \
                 ${REGION:+--region "$REGION"} \
                 --secret-id "$1" --query SecretString --output text 2>/dev/null ;;
        gcp) gcp_gcloud secrets versions access latest \
                 ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                 --secret="$1" 2>/dev/null ;;
    esac
}

# Value arrives on STDIN so it never appears in a process listing.
#
# Copied from zitadel-oidc-clients.sh with the provenance strings parameterised.
# Three properties here are load-bearing and must not be "simplified":
#
#   * `umask 077 && mktemp` sets the mode AT CREATION. Creating then chmod-ing
#     leaves a window in which a file holding a secret is world-readable.
#   * the RETURN trap fires on EVERY exit path, and shred overwrites the bytes.
#     A trailing `rm -f` runs only when nothing failed.
#   * AWS goes through jq into --cli-input-json rather than --secret-string,
#     which is what lets the payload be an arbitrary JSON document.
store_write() {
    local name="$1" payload
    payload=$(umask 077 && mktemp -t cloud-secret.XXXXXX)
    # shellcheck disable=SC2064
    trap "shred -u '${payload}' 2>/dev/null || rm -f '${payload}'" RETURN
    cat > "$payload"

    case "$CLOUD" in
        aws)
            local body
            body=$(umask 077 && mktemp -t cloud-secret-body.XXXXXX)
            if store_exists "$name"; then
                jq --arg id "$name" '{SecretId: $id, SecretString: (. | tostring)}' \
                    < "$payload" > "$body"
                aws secretsmanager put-secret-value ${REGION:+--region "$REGION"} \
                    --cli-input-json "file://${body}" >/dev/null
            else
                jq --arg n "$name" --arg d "${STORE_WRITE_DESCRIPTION:-Written by cloud-secret-store.sh}" \
                   '{Name: $n, Description: $d, SecretString: (. | tostring)}' \
                    < "$payload" > "$body"
                aws secretsmanager create-secret ${REGION:+--region "$REGION"} \
                    --cli-input-json "file://${body}" >/dev/null
            fi
            shred -u "$body" 2>/dev/null || rm -f "$body"
            ;;
        gcp)
            store_exists "$name" || gcp_gcloud secrets create "$name" \
                ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                --replication-policy=automatic \
                --labels=managed-by="${STORE_WRITE_LABEL:-cloud-secret-store}" >/dev/null
            gcp_gcloud secrets versions add "$name" \
                ${GCP_PROJECT:+--project "$GCP_PROJECT"} \
                --data-file="$payload" >/dev/null
            ;;
    esac
}
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
./scripts/test-cloud-secret-store.sh && shellcheck -S warning scripts/lib/cloud-secret-store.sh
```

Expected: three `ok` lines, exit 0, no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/cloud-secret-store.sh scripts/test-cloud-secret-store.sh
git commit -m "refactor(scripts): one copy of the cloud secret store I/O"
```

---

### Task 2: The PAT resolver

**Files:**
- Create: `scripts/lib/zitadel-pat.sh`
- Create: `scripts/test-zitadel-pat.sh`

**Interfaces:**
- Consumes: `store_exists`, `store_read`, `store_write` (Task 1); `CLOUD`, `REGION`, `GCP_PROJECT`
- Produces: `zitadel_pat_secret_name` → the per-cloud name on stdout; `resolve_zitadel_pat` → the token on stdout, exit 1 with a diagnosis on stderr if unavailable

Resolution order, and why: **store first**, because it is the only source that survives a restore. **Cluster second**, because on a fresh bootstrap the chart has just written it there and nowhere else — that read is also the seeding opportunity. Neither: fail loudly.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-zitadel-pat.sh`:

```bash
#!/usr/bin/env bash
# Resolution order and the failure path, with store and kubectl stubbed.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() { if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
          else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi }

# shellcheck source=scripts/lib/zitadel-pat.sh
. "$HERE/lib/zitadel-pat.sh"

CLOUD=aws REGION=eu-west-3 GCP_PROJECT=""
check "aws secret name" "zitadel/iam-admin-pat" "$(zitadel_pat_secret_name)"
CLOUD=gcp
check "gcp secret name" "zitadel-iam-admin-pat" "$(zitadel_pat_secret_name)"

CLOUD=aws
# 1. Store has it -> used, and the cluster is never consulted.
store_exists() { return 0; }
store_read()   { echo "token-from-store"; }
kubectl()      { echo "KUBECTL MUST NOT BE CALLED" >&2; return 1; }
check "store wins" "token-from-store" "$(resolve_zitadel_pat)"

# 2. Store empty, cluster has it -> used AND persisted.
persisted=""
store_exists() { return 1; }
store_read()   { return 1; }
store_write()  { persisted="$(cat)"; }
kubectl()      { printf '%s' "dG9rZW4tZnJvbS1jbHVzdGVy"; }   # base64 of token-from-cluster
check "cluster seeds" "token-from-cluster" "$(resolve_zitadel_pat 2>/dev/null)"
resolve_zitadel_pat >/dev/null 2>&1
check "persisted"     "token-from-cluster" "$persisted"

# 3. Neither -> fail, with a diagnosis, and no token on stdout.
store_exists() { return 1; }
store_read()   { return 1; }
kubectl()      { return 1; }
out="$(resolve_zitadel_pat 2>/dev/null)"; rc=$?
check "fails"         "1"  "$rc"
check "silent stdout" ""   "$out"
err="$(resolve_zitadel_pat 2>&1 >/dev/null)"
case "$err" in *FIRSTINSTANCE*) printf '  ok   explains FirstInstance\n' ;;
               *) printf '  FAIL error does not explain the cause\n'; fail=1 ;; esac

exit $fail
```

- [ ] **Step 2: Run it and watch it fail**

```bash
chmod +x scripts/test-zitadel-pat.sh && ./scripts/test-zitadel-pat.sh
```

Expected: FAIL — `lib/zitadel-pat.sh: No such file or directory`.

- [ ] **Step 3: Write the library**

Create `scripts/lib/zitadel-pat.sh`:

```bash
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
    local name token b64
    name="$(zitadel_pat_secret_name)"

    # 1. The store, which is the only source that survives a restore.
    if store_exists "$name" && token="$(store_read "$name")" && [ -n "$token" ]; then
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
            printf '%s' "$token" | store_write "$name"
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
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
./scripts/test-zitadel-pat.sh && shellcheck -S warning scripts/lib/zitadel-pat.sh
```

Expected: seven `ok` lines, exit 0, no shellcheck output.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/zitadel-pat.sh scripts/test-zitadel-pat.sh
git commit -m "feat(zitadel): persist the admin PAT so it survives a restore"
```

---

### Task 3: Move the four setup scripts onto the libraries

**Files:**
- Modify: `scripts/zitadel-oidc-clients.sh` (inline `store_*` ~102–160, PAT block ~174–205)
- Modify: `scripts/zitadel-idp.sh`
- Modify: `scripts/harbor-oidc.sh`
- Modify: `scripts/secret-store.sh`

**Interfaces:**
- Consumes: `resolve_zitadel_pat` (Task 2), `store_*` (Task 1)
- Produces: no new interface; the four scripts keep their existing CLIs unchanged

- [ ] **Step 1: Confirm the current behaviour before touching it**

```bash
./scripts/zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws --region eu-west-3 \
  > /tmp/before.log 2>&1; echo "exit=$?"; cat /tmp/before.log
```

Expected on a cluster without the Secret: exit 1 and the FirstInstance diagnosis. Keep this output; Step 4 compares against it.

- [ ] **Step 2: Replace the inline blocks in `zitadel-oidc-clients.sh`**

Delete its `store_exists` / `store_read` / `store_write` definitions and the whole `PAT=...` block including its error message, then add after the `set -o` lines:

```bash
# shellcheck source=scripts/lib/zitadel-pat.sh
. "$(dirname "$0")/lib/zitadel-pat.sh"
```

and where `PAT` was assigned:

```bash
PAT="$(resolve_zitadel_pat)" || exit 1
```

- [ ] **Step 3: Repeat for the other three**

`zitadel-idp.sh` and `harbor-oidc.sh`: same deletion and same two additions. `secret-store.sh` only needs `store_*`, so source `lib/cloud-secret-store.sh` and delete its own copies.

Each script keeps its own provenance on secrets it creates, which the shared
`store_write` reads from two optional variables. Set them near the top of each,
preserving what that script writes today — for `zitadel-oidc-clients.sh`:

```bash
STORE_WRITE_DESCRIPTION="OIDC client for ${CLUSTER}. Written by zitadel-oidc-clients.sh."
STORE_WRITE_LABEL="zitadel-oidc-clients"
```

Without these the description and label fall back to generic defaults, which is
a silent loss of provenance on every secret the scripts create.

- [ ] **Step 4: Verify behaviour is unchanged, then improved**

```bash
for s in zitadel-oidc-clients zitadel-idp harbor-oidc secret-store; do
  bash -n "scripts/$s.sh" || echo "SYNTAX $s"
done
shellcheck -S warning scripts/zitadel-oidc-clients.sh scripts/zitadel-idp.sh \
                      scripts/harbor-oidc.sh scripts/secret-store.sh
./scripts/zitadel-oidc-clients.sh sync --cluster aws-0 --cloud aws --region eu-west-3 \
  > /tmp/after.log 2>&1; echo "exit=$?"; diff /tmp/before.log /tmp/after.log
```

Expected: no syntax or shellcheck output; the run still exits 1 on a cluster without the credential, and the message now names both sources it looked in.

- [ ] **Step 5: Commit**

```bash
git add scripts/zitadel-oidc-clients.sh scripts/zitadel-idp.sh \
        scripts/harbor-oidc.sh scripts/secret-store.sh
git commit -m "refactor(zitadel): setup scripts resolve the PAT from one place"
```

---

### Task 4: Make `zitadel-idp.sh` converge

**Files:**
- Modify: `scripts/zitadel-idp.sh`

**Interfaces:**
- Consumes: `resolve_zitadel_pat`, `api` (already in the script)
- Produces: no new interface

The IdP's `issuer` and the action's script body both derive from `$IDP_URL`, so a cluster whose domain has changed — or which has moved cloud — needs them corrected, not skipped.

- [ ] **Step 1: Find out whether it converges today**

```bash
grep -n -A12 "ensure_idp\|ensure_action\|ensure_login_policy_idp" scripts/zitadel-idp.sh | head -60
```

Read each `ensure_*`. Record for each whether it (a) creates when absent and returns, or (b) also compares the existing object and updates on drift. Only (b) is convergence.

- [ ] **Step 2: Write the failing check**

For each `ensure_*` that is (a), add a comparison before the early return. The Google IdP is the concrete case — its `issuer` must match `$IDP_URL`:

```bash
# The IdP's issuer is derived from IDP_URL, so it is wrong on any cluster whose
# domain changed since the provider was created -- which is every restored
# cluster, and every cluster the IdP has moved to.
existing_issuer="$(api GET "/management/v1/idps/${idp_id}" \
                    | jq -r '.idp.config.oidc.issuer // empty')"
if [ "$existing_issuer" != "$IDP_URL" ]; then
    echo "[STALE  ] idp issuer: has ${existing_issuer:-<none>}, want ${IDP_URL}"
    [ "$APPLY" = "true" ] && update_idp_issuer "$idp_id" "$IDP_URL"
fi
```

- [ ] **Step 3: Run it against a cluster with a PAT and confirm the report**

```bash
IDP_URL=https://auth.cloud.ogenki.io ./scripts/zitadel-idp.sh sync \
  --cluster aws-0 --cloud aws --region eu-west-3
```

Expected: every object reported `[ok]` or `[STALE]` with both values shown, and no write without `--apply`.

- [ ] **Step 4: Re-run to prove idempotency**

```bash
IDP_URL=https://auth.cloud.ogenki.io ./scripts/zitadel-idp.sh sync \
  --cluster aws-0 --cloud aws --region eu-west-3 --apply
IDP_URL=https://auth.cloud.ogenki.io ./scripts/zitadel-idp.sh sync \
  --cluster aws-0 --cloud aws --region eu-west-3
```

Expected: the second run reports everything `[ok]` and writes nothing.

- [ ] **Step 5: Commit**

```bash
git add scripts/zitadel-idp.sh
git commit -m "fix(zitadel): correct a stale IdP issuer instead of skipping it"
```

---

### Task 5: Make `harbor-oidc.sh` converge

**Files:**
- Modify: `scripts/harbor-oidc.sh`

**Interfaces:**
- Consumes: `resolve_zitadel_pat`, Harbor's `/api/v2.0/configurations`
- Produces: no new interface

Harbor stores its OIDC configuration in its own database, so nothing in git makes it true and drift is invisible. Its `oidc_endpoint` derives from the IdP URL and its `oidc_client_id` from the ZITADEL client — both change on a restore or a cloud move.

- [ ] **Step 1: Read the current configuration**

```bash
grep -n -A20 "configurations" scripts/harbor-oidc.sh | head -40
```

Determine whether the script PUTs unconditionally (already convergent) or only when `auth_mode` is not `oidc_auth` (not convergent).

- [ ] **Step 2: Compare before writing**

```bash
current="$(harbor_api GET /configurations | jq -r '.oidc_endpoint.value // empty')"
if [ "$current" != "$IDP_URL" ]; then
    echo "[STALE  ] harbor oidc_endpoint: has ${current:-<none>}, want ${IDP_URL}"
    [ "$APPLY" = "true" ] && harbor_api PUT /configurations -d "$(jq -n \
        --arg e "$IDP_URL" '{auth_mode:"oidc_auth", oidc_endpoint:$e}')"
else
    echo "[ok     ] harbor oidc_endpoint"
fi
```

- [ ] **Step 3: Run it and read the report**

```bash
PRIVATE_DOMAIN=priv.aws.ogenki.io ./scripts/harbor-oidc.sh sync \
  --cluster aws-0 --cloud aws --region eu-west-3
```

Expected: `[ok]` or `[STALE]` with both values, nothing written without `--apply`.

- [ ] **Step 4: Apply, then re-run to prove idempotency**

```bash
PRIVATE_DOMAIN=priv.aws.ogenki.io ./scripts/harbor-oidc.sh sync \
  --cluster aws-0 --cloud aws --region eu-west-3 --apply
PRIVATE_DOMAIN=priv.aws.ogenki.io ./scripts/harbor-oidc.sh sync \
  --cluster aws-0 --cloud aws --region eu-west-3
```

Expected: second run all `[ok]`, no writes. Then confirm in a browser that Harbor still offers the SSO button.

- [ ] **Step 5: Commit**

```bash
git add scripts/harbor-oidc.sh
git commit -m "fix(harbor): converge the stored OIDC endpoint rather than only setting auth_mode"
```

---

### Task 6: Documentation, and correct the spec

**Files:**
- Create: `website/content/docs/guides/migrate-the-identity-provider.md`
- Modify: `website/content/docs/get-started/sso.md`
- Modify: `docs/superpowers/specs/2026-08-29-zitadel-bootstrap-and-reconciliation-design.md`

**Interfaces:**
- Consumes: everything above
- Produces: no code interface

- [ ] **Step 1: Correct the spec**

In the design doc, replace the ExternalSecret rehydration with store-direct reads, and say why: nothing in-cluster consumes the PAT, and an ExternalSecret would contend with the chart for ownership of the Secret the chart creates. Update the diagram in section 1 to:

```
FirstInstance (fresh DB only)
  └─> chart writes Secret security/iam-admin-pat
        └─> first script run captures it into the cloud secret store
              └─> every later run, on any cluster, reads it from there
```

- [ ] **Step 2: Update the SSO page**

Remove the manual `kubectl create secret generic iam-admin-pat` prerequisite; it is now automatic on a fresh cluster and unnecessary on a restored one. Keep it as recovery, in a callout, for a cluster restored before this change landed.

- [ ] **Step 3: Write the migration guide**

Create `website/content/docs/guides/migrate-the-identity-provider.md` covering, in order: freeze a seed on the source cloud; copy the seed to the target cloud's backup bucket; copy `zitadel/iam-admin-pat` → `zitadel-iam-admin-pat` (or the reverse); copy the five consumer client secrets; flip the two ADR-0024 gates; deploy; run the four setup scripts to converge the configuration to the new domain; verify a login. State plainly that a move which copies the seed but not the credentials produces a cluster that authenticates nobody and cannot be repaired.

- [ ] **Step 4: Run the documentation gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh && ./scripts/validate-doc-claims.sh
```

Expected: all three pass. `verify-doc-paths.sh` rejects any path named in the docs that does not exist — do not name a generated file.

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/guides/migrate-the-identity-provider.md \
        website/content/docs/get-started/sso.md \
        docs/superpowers/specs/2026-08-29-zitadel-bootstrap-and-reconciliation-design.md
git commit -m "docs: the admin PAT is automatic, and the IdP migration is written down"
```

---

## Verification against the spec's success criteria

| Criterion | Verified by |
|---|---|
| 1. Rebuilt cluster ends with correct redirect URIs, no manual step | Task 3 Step 4, then `sync --apply` on a restored cluster |
| 2. `sync` runs on a restored cluster with no hand-made Secret | Task 2 Step 4 (resolution order) + Task 3 Step 4 |
| 3. Client IDs and secrets unchanged across a rebuild | Task 5 Step 4 — Harbor still logs in without a secret rotation |
| 4. Re-running any script changes nothing the second time | Tasks 4 and 5, Step 4 in each |
| 5. GCP-only migration performed end to end | **Not covered by this plan.** Task 6 documents the procedure; performing it needs a GCP-only platform and is a separate exercise. |

Criterion 5 is deliberately left open rather than claimed. The spec already records the GCP-only path as designed, not proven.

## Out of scope

- Replacing the PAT with the MachineKey/JWT exchange (spec records it as available hardening).
- Automating the cloud migration.
- Rotating client secrets on a schedule.
- Harbor's own user database beyond `auth_mode` and `oidc_endpoint`.
