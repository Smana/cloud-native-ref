# IdP Topology Enforcement Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible to commit a configuration in which two clouds each host a ZITADEL, by declaring the primary cloud once and checking every gate against it in CI.

**Architecture:** One new Terramate global, `primary_cloud`, becomes the single statement of which cloud hosts the services that cannot exist twice. The OpenTofu gate (`deploy_identity_provider`) stops being a hand-typed literal and is derived from that global at every invocation site. The Flux gate (`spec.suspend`) cannot be derived — Flux never sees Terramate globals — so a new shell script asserts it agrees with the global, and CI runs that script.

**Tech Stack:** Bash + `python3`/`pyyaml` (already a CI dependency) for YAML reads, Terramate HCL globals, OpenTofu variables, Flux Kustomization manifests, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-01-idp-topology-enforcement-design.md`

## Global Constraints

- **Do not derive placement from `TM_CLOUD`.** `TM_CLOUD` selects which lane a single invocation deploys; the IdP's home must not change as a side effect of it (ADR-0027: relocation "is a deliberate act with a written procedure").
- **Do not add a host toggle to `opentofu/aws/eks/configure`.** AWS hosting unconditionally is intentional for this change; the state that would need a toggle is rejected instead.
- **Do not write a new ADR.** ADR-0024 and ADR-0027 get short amendments.
- **An absent `spec.suspend` counts as not-suspended**, matching Flux's own default.
- **Known clouds are exactly `aws` and `gcp`.** A third value must fail the check rather than be ignored.
- **New CI checks fold into the existing `links` job** (`.github/workflows/ci.yaml`), never a new job — the repo does this deliberately so the required-check list on `main` does not have to change.
- Shell scripts under `scripts/` are linted by `shellcheck -x -S warning` in CI and must pass.

---

### Task 1: The topology checker and its fixture tests

Builds the checker first, against fixtures, so it can be proven to fail on the
repository's current (non-compliant) state before Task 2 corrects it.

**Files:**
- Create: `scripts/validate-idp-topology.sh`
- Create: `scripts/test-validate-idp-topology.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `scripts/validate-idp-topology.sh [ROOT_DIR]` — exits `0` when the
  committed topology is consistent, `1` otherwise, printing one `FAIL:` line per
  violation to stdout. `ROOT_DIR` defaults to `git rev-parse --show-toplevel`.
  Task 2 runs it against the real tree; Task 3 wires it into CI.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-validate-idp-topology.sh`:

```bash
#!/usr/bin/env bash
#
# Fixture-driven tests for validate-idp-topology.sh.
#
# The states this checker exists to catch are expensive to produce live -- two
# clusters each running an identity provider is a two-cloud bootstrap -- so it
# is tested against synthetic trees instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-idp-topology.sh"
failures=0

# Build a fixture tree: primary cloud, then "<cluster>:<suspend>" pairs where
# suspend is "true", "false", or "absent".
make_fixture() {
  local root="$1" primary="$2"
  shift 2
  mkdir -p "${root}/opentofu"
  cat >"${root}/opentofu/config.tm.hcl" <<EOF
globals {
  region        = "eu-west-3"
  primary_cloud = "${primary}"
}
EOF
  local pair cluster suspend
  for pair in "$@"; do
    cluster="${pair%%:*}"
    suspend="${pair##*:}"
    mkdir -p "${root}/clusters/${cluster}/security"
    {
      echo "apiVersion: kustomize.toolkit.fluxcd.io/v1"
      echo "kind: Kustomization"
      echo "metadata:"
      echo "  name: zitadel"
      echo "spec:"
      [ "$suspend" != "absent" ] && echo "  suspend: ${suspend}"
      echo "  path: ./security/${cluster}/zitadel"
    } >"${root}/clusters/${cluster}/security/zitadel.yaml"
  done
}

# expect <name> <expected-exit> <expected-substring-or-empty> <primary> <pairs...>
expect() {
  local name="$1" want_exit="$2" want_text="$3" primary="$4"
  shift 4
  local root output rc
  root="$(mktemp -d)"
  make_fixture "$root" "$primary" "$@"
  set +e
  output="$("$VALIDATOR" "$root" 2>&1)"
  rc=$?
  set -e
  rm -rf "$root"

  if [ "$rc" -ne "$want_exit" ]; then
    echo "FAIL ${name}: exit ${rc}, want ${want_exit}"
    echo "     output: ${output}"
    failures=$((failures + 1))
    return
  fi
  if [ -n "$want_text" ] && ! grep -qF "$want_text" <<<"$output"; then
    echo "FAIL ${name}: output missing '${want_text}'"
    echo "     output: ${output}"
    failures=$((failures + 1))
    return
  fi
  echo "ok   ${name}"
}

expect "compliant: aws primary hosts, gcp suspended" \
  0 "" aws "aws-0:absent" "gcp-0:true"

expect "both clouds hosting is rejected" \
  1 "gcp-0" aws "aws-0:absent" "gcp-0:false"

expect "primary hosting nothing is rejected" \
  1 "aws-0" aws "aws-0:true" "gcp-0:true"

expect "gcp primary while aws is present is rejected" \
  1 "unconditionally" gcp "aws-0:absent" "gcp-0:false"

expect "unknown primary_cloud is rejected" \
  1 "azure" azure "aws-0:absent" "gcp-0:true"

# primary_cloud absent entirely
root="$(mktemp -d)"
mkdir -p "${root}/opentofu"
echo 'globals {' >"${root}/opentofu/config.tm.hcl"
echo '  region = "eu-west-3"' >>"${root}/opentofu/config.tm.hcl"
echo '}' >>"${root}/opentofu/config.tm.hcl"
mkdir -p "${root}/clusters/aws-0/security"
printf 'spec:\n  suspend: false\n' >"${root}/clusters/aws-0/security/zitadel.yaml"
set +e
out="$("$VALIDATOR" "$root" 2>&1)"; rc=$?
set -e
rm -rf "$root"
if [ "$rc" -eq 1 ] && grep -qF "primary_cloud" <<<"$out"; then
  echo "ok   undeclared primary_cloud is rejected"
else
  echo "FAIL undeclared primary_cloud is rejected: exit ${rc}: ${out}"
  failures=$((failures + 1))
fi

if [ "$failures" -ne 0 ]; then
  echo "==> ${failures} test(s) failed"
  exit 1
fi
echo "==> all tests passed"
```

Then make it executable:

```bash
chmod +x scripts/test-validate-idp-topology.sh
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-validate-idp-topology.sh`
Expected: FAIL — every case errors because `scripts/validate-idp-topology.sh` does not exist yet (`No such file or directory`), and the script exits non-zero.

- [ ] **Step 3: Write minimal implementation**

Create `scripts/validate-idp-topology.sh`:

```bash
#!/usr/bin/env bash
#
# Assert that exactly one cloud hosts the identity provider, and that it is the
# cloud named by `primary_cloud` in opentofu/config.tm.hcl.
#
# WHY THIS EXISTS
#
# ADR-0027 makes ZITADEL a primary-cloud singleton: it relocates to whichever
# cloud is primary, and two clouds each running one is ruled out -- two user
# directories mean a grant says nothing without knowing which directory issued
# it. Placement is set in two places that cannot enforce each other:
#
#   1. `deploy_identity_provider` (OpenTofu)  -- derived from primary_cloud
#   2. `spec.suspend` (Flux Kustomization)    -- committed Git state
#
# Flux never sees Terramate globals, so gate 2 cannot be derived and is checked
# here instead. The forbidden state has occurred twice; both times the intended
# topology was written only in an ADR, where no machine could read it.
#
# Usage: validate-idp-topology.sh [ROOT_DIR]
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"
CONFIG="${ROOT}/opentofu/config.tm.hcl"
KNOWN_CLOUDS="aws gcp"
failures=0

fail() {
  echo "FAIL: $*"
  failures=$((failures + 1))
}

if [ ! -f "$CONFIG" ]; then
  echo "FAIL: no ${CONFIG}"
  exit 1
fi

primary="$(sed -n 's/^[[:space:]]*primary_cloud[[:space:]]*=[[:space:]]*"\([a-z0-9]*\)".*/\1/p' "$CONFIG" | head -1)"

if [ -z "$primary" ]; then
  echo "FAIL: primary_cloud is not declared in opentofu/config.tm.hcl."
  echo "      ADR-0027 requires one named home for services that cannot exist twice."
  exit 1
fi

if ! grep -qw "$primary" <<<"$KNOWN_CLOUDS"; then
  echo "FAIL: primary_cloud = \"${primary}\" is not a known cloud (${KNOWN_CLOUDS})."
  exit 1
fi

shopt -s nullglob
manifests=("${ROOT}"/clusters/*/security/zitadel.yaml)
shopt -u nullglob

if [ ${#manifests[@]} -eq 0 ]; then
  echo "FAIL: no clusters/*/security/zitadel.yaml found under ${ROOT}"
  exit 1
fi

for manifest in "${manifests[@]}"; do
  cluster="$(basename "$(dirname "$(dirname "$manifest")")")"
  cloud="${cluster%%-*}"

  # An absent spec.suspend means not suspended, which is how Flux reads it.
  suspend="$(python3 - "$manifest" <<'PY'
import sys, yaml
with open(sys.argv[1]) as fh:
    doc = yaml.safe_load(fh) or {}
print(str((doc.get("spec") or {}).get("suspend", False)).lower())
PY
)"

  if [ "$cloud" = "$primary" ]; then
    if [ "$suspend" = "true" ]; then
      fail "${cluster} is on the primary cloud (${primary}) but its identity provider is suspended."
      echo "      Set spec.suspend: false in clusters/${cluster}/security/zitadel.yaml,"
      echo "      or change primary_cloud in opentofu/config.tm.hcl."
    fi
  else
    if [ "$suspend" != "true" ]; then
      fail "${cluster} is not on the primary cloud (${primary}) but would run its own identity provider."
      if [ "$cloud" = "aws" ]; then
        echo "      opentofu/aws/eks/configure sets identity_provider_url unconditionally, so AWS"
        echo "      hosts whenever it is deployed. A non-AWS primary with AWS deployed is not a"
        echo "      supported combination -- it needs an AWS-side host toggle, which is a new decision."
      else
        echo "      Set spec.suspend: true in clusters/${cluster}/security/zitadel.yaml."
      fi
    fi
  fi
done

if [ "$failures" -ne 0 ]; then
  echo "==> identity provider topology is inconsistent (${failures} problem(s)); see ADR-0027."
  exit 1
fi

echo "==> identity provider topology is consistent: ${primary} hosts, all other clouds suspended."
```

Then make it executable:

```bash
chmod +x scripts/validate-idp-topology.sh
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./scripts/test-validate-idp-topology.sh`
Expected: PASS — six `ok` lines and `==> all tests passed`.

- [ ] **Step 5: Confirm the checker fails on the current repository**

Run: `./scripts/validate-idp-topology.sh; echo "exit=$?"`
Expected: `exit=1`, reporting that `primary_cloud` is not declared. This is the
red state Task 2 turns green — record the output in the commit message.

- [ ] **Step 6: Verify shellcheck passes**

Run: `shellcheck -x -S warning scripts/validate-idp-topology.sh scripts/test-validate-idp-topology.sh`
Expected: no output, exit 0. (CI runs the same command across `scripts/`.)

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-idp-topology.sh scripts/test-validate-idp-topology.sh
git commit -m "test(idp): check that exactly one cloud hosts the identity provider

ADR-0027 makes ZITADEL a primary-cloud singleton and rules out two clouds
each running one, but nothing enforced it and the forbidden state has
occurred twice. Adds the checker and its fixture tests; it currently
FAILS on this repository because primary_cloud is not declared yet.

Fixture-driven because the states worth catching -- two clusters each
hosting a directory -- are a two-cloud bootstrap to produce live."
```

---

### Task 2: Declare the primary cloud, derive the OpenTofu gate, restore compliance

**Files:**
- Modify: `opentofu/config.tm.hcl` (globals block, near `region`)
- Modify: `opentofu/gcp/gke/configure/workflows.tm.hcl:37` (deploy), `:55` (preview), `:102-107` (destroy), `:139` (drift detect)
- Modify: `opentofu/gcp/gke/configure/variables.tfvars:57`
- Modify: `clusters/gcp-0/security/zitadel.yaml`

**Interfaces:**
- Consumes: `scripts/validate-idp-topology.sh` from Task 1, as the acceptance test.
- Produces: the Terramate global `global.primary_cloud` (string, `"aws"`), readable by any stack's `workflows.tm.hcl`.

- [ ] **Step 1: Run the checker to see the failure this task fixes**

Run: `./scripts/validate-idp-topology.sh; echo "exit=$?"`
Expected: `exit=1` — `primary_cloud is not declared`.

- [ ] **Step 2: Declare the global**

In `opentofu/config.tm.hcl`, inside the `globals` block, immediately after the
`region` / `profile` lines, add:

```hcl
  # Which cloud hosts the services that cannot sensibly exist twice: the public
  # DNS zone, the cross-cloud federation trust, and ZITADEL (ADR-0027).
  #
  # Changing this is a MIGRATION, not a toggle. The identity provider's database
  # seed, admin credential and OIDC clients travel with it or the move
  # half-works in silence -- which is why placement is stated here once and
  # never derived from TM_CLOUD, whose value changes per invocation.
  #
  # Enforced by ./scripts/validate-idp-topology.sh.
  primary_cloud = "aws"
```

- [ ] **Step 3: Derive the OpenTofu gate at every invocation site**

In `opentofu/gcp/gke/configure/workflows.tm.hcl`, append this argument to the
`tofu` command in **all four** jobs — deploy (line ~37), preview (line ~55),
destroy (line ~102-107), and drift detect (line ~139):

```
-var='deploy_identity_provider=${global.primary_cloud == "gcp"}'
```

For deploy and preview, append it to the existing single-line command after
`-var='flux_instance_version=...'`. For destroy, add it as a new
backslash-continued line after the `flux_instance_version` line. For drift
detect — which passes no other `-var` today — append it after
`-var-file=variables.tfvars`; without it, drift would compare against the
variable's default and report a difference that does not exist.

This is an HCL comparison, not a `tm_` function: Terramate's `tm_*` set mirrors
Terraform's functions and Terraform has no `equal()`. The repo already uses this
operator style in `global.stack_cloud`.

- [ ] **Step 4: Remove the hand-typed literal**

In `opentofu/gcp/gke/configure/variables.tfvars`, delete line 57
(`deploy_identity_provider = true`) and replace the comment block above it
(lines ~50-56, which describes flipping two gates by hand) with:

```hcl
# deploy_identity_provider is NOT set here. It is derived from
# global.primary_cloud in workflows.tm.hcl, so that "which cloud hosts the
# identity provider" has exactly one answer in configuration (ADR-0027).
# The variable's own default is false, so a bare `tofu apply` in this directory
# does not silently stand up a second identity directory.
```

- [ ] **Step 5: Restore the Flux gate to compliance**

In `clusters/gcp-0/security/zitadel.yaml`, set `suspend: true` and replace the
comment above it with:

```yaml
  # SUSPENDED: aws-0 hosts the identity provider (global.primary_cloud = "aws",
  # ADR-0027). ZITADEL is a singleton that relocates for a GCP-only platform
  # rather than being duplicated -- two directories mean a grant says nothing
  # without knowing which one issued it.
  #
  # To make GCP primary: set primary_cloud = "gcp" in opentofu/config.tm.hcl,
  # flip this to false, and migrate the database seed, admin credential and
  # OIDC clients. ./scripts/validate-idp-topology.sh fails if these two
  # disagree. Note that a GCP primary while AWS is also deployed is rejected:
  # opentofu/aws/eks/configure hosts unconditionally.
  suspend: true
```

Leave the surrounding two-gates narrative in the file's header comment intact
only where it is still true; the gate-1 half is now derived, so delete any
sentence instructing a reader to edit `deploy_identity_provider` by hand.

- [ ] **Step 6: Run the checker to verify it now passes**

Run: `./scripts/validate-idp-topology.sh; echo "exit=$?"`
Expected: `exit=0` and
`==> identity provider topology is consistent: aws hosts, all other clouds suspended.`

- [ ] **Step 7: Verify the derivation renders**

Run: `cd opentofu/gcp/gke/configure && terramate script list && cd -`
Expected: exit 0, no HCL parse error. Then:

Run: `terramate --chdir opentofu generate 2>&1 | tail -3`
Expected: exit 0. A parse error in the interpolation surfaces here.

- [ ] **Step 8: Verify the manifests still render**

Run: `./scripts/validate-manifests.sh`
Expected: exit 0, `==> All gates passed`. (The gcp-0 zitadel Kustomization is
suspended, not deleted, so the rendered bundle is unchanged in content.)

- [ ] **Step 9: Commit**

```bash
git add opentofu/config.tm.hcl opentofu/gcp/gke/configure/workflows.tm.hcl \
        opentofu/gcp/gke/configure/variables.tfvars \
        clusters/gcp-0/security/zitadel.yaml
git commit -m "fix(idp): declare the primary cloud and restore the singleton

Adds global.primary_cloud = \"aws\" as the one statement of where the
services that cannot exist twice live, derives the OpenTofu gate from it
at all four invocation sites, and drops the hand-typed literal -- two
gates that could disagree become one that cannot.

Also restores gcp-0 to compliance: it had been left self-hosting after
the GCP validation work, which is the state ADR-0027 rules out. Both
clusters are destroyed, so this correction carries no database seed,
admin credential or client secrets.

Evidence: validate-idp-topology.sh exit 0; terramate generate exit 0;
validate-manifests.sh all gates passed."
```

---

### Task 3: Wire into CI and amend the records

**Files:**
- Modify: `.github/workflows/ci.yaml` (the `links` job, after the `validate-doc-claims.sh` step)
- Modify: `CLAUDE.md` (Validation Commands block)
- Modify: `website/content/docs/decisions/0024-identity-provider-per-cloud.md`
- Modify: `website/content/docs/decisions/0027-primary-cloud-provider.md`

**Interfaces:**
- Consumes: `scripts/validate-idp-topology.sh` (Task 1) and `global.primary_cloud` (Task 2).
- Produces: nothing later tasks depend on.

- [ ] **Step 1: Add the CI step**

In `.github/workflows/ci.yaml`, in the `links` job, immediately after the
`Check documentation claims against configuration` step, add:

```yaml
      # Also folded into this job rather than its own, for the reason above:
      # the required-check list on `main` stays as it is.
      - name: Check identity provider topology
        run: ./scripts/validate-idp-topology.sh
```

The job already installs `pyyaml`, which the checker needs.

- [ ] **Step 2: Add the test to the shell-script job**

The `shellcheck` job already globs `./scripts -name "*.sh"`, so both new scripts
are linted with no change. Add a step to actually run the unit tests, after the
ShellCheck step in that job:

```yaml
      - name: Run script unit tests
        run: ./scripts/test-validate-idp-topology.sh
```

- [ ] **Step 3: Document the command**

In `CLAUDE.md`, in the `## Validation Commands` fenced block, add after the
`validate-doc-claims.sh` line:

```
./scripts/validate-idp-topology.sh  # exactly one cloud hosts ZITADEL (ADR-0027)
```

- [ ] **Step 4: Amend ADR-0024**

In `website/content/docs/decisions/0024-identity-provider-per-cloud.md`, in the
table of two gates, change the Gate 1 row's "Where" cell to note the derivation,
and add immediately below the table:

```markdown
{{< callout type="info" >}}
**Update (2026-09-01):** gate 1 is no longer typed by hand. It is derived from
`global.primary_cloud` (see
[ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}})) at
every invocation site, so it cannot disagree with the declared topology. Gate 2
remains committed Flux state — Flux never sees Terramate globals — and is
checked instead by `./scripts/validate-idp-topology.sh`. "Neither can enforce
the other" is now "one is derived, the other is verified."
{{< /callout >}}
```

Bump `lastVerified` in the front matter to `2026-09-01`.

- [ ] **Step 5: Amend ADR-0027**

In `website/content/docs/decisions/0027-primary-cloud-provider.md`, add to the
end of the **Consequences** section:

```markdown
**How it is enforced (2026-09-01).** The primary cloud is declared once, as
`primary_cloud` in `opentofu/config.tm.hcl`. The OpenTofu gate that decides
whether a cluster hosts ZITADEL is derived from it; the Flux gate, which cannot
be derived, is checked against it by `./scripts/validate-idp-topology.sh` in CI.
The third state this record rules out — two clouds each hosting a singleton —
now fails a required check rather than depending on someone remembering the
rule. A non-AWS primary while AWS is deployed is rejected too, since
`opentofu/aws/eks/configure` hosts unconditionally; supporting it would need an
AWS-side toggle and a new decision.
```

Bump `lastVerified` in the front matter to `2026-09-01`.

- [ ] **Step 6: Run the documentation gates**

Run: `./scripts/validate-links.sh && ./scripts/validate-doc-claims.sh`
Expected: both exit 0.

- [ ] **Step 7: Run the full check set once more**

Run: `./scripts/validate-idp-topology.sh && ./scripts/test-validate-idp-topology.sh`
Expected: both exit 0.

- [ ] **Step 8: Commit**

```bash
git add .github/workflows/ci.yaml CLAUDE.md \
        website/content/docs/decisions/0024-identity-provider-per-cloud.md \
        website/content/docs/decisions/0027-primary-cloud-provider.md
git commit -m "ci(idp): gate the primary-cloud singleton invariant

Runs validate-idp-topology.sh in the links job and the script unit tests
in the shellcheck job -- both folded into existing jobs so the required
check list on main does not change.

Amends ADR-0024 (gate 1 is derived now, not hand-typed) and ADR-0027
(how the invariant is enforced). No new ADR: the decision already
existed, this only makes it checkable."
```

---

## Self-review notes

**Spec coverage.** Design §1 → Task 2 Step 2. §2 → Task 2 Step 3-4. §3 → Task 1.
§4 → Task 2 Step 5. §5 → Task 1 Step 3 (the `cloud = "aws"` branch) and its test
case. Testing table → Task 1 Step 1 (six cases; the design's five plus the
undeclared-global case the script needs). Files-touched table → Tasks 1-3, with
one deliberate difference: the design named a CI *job*, the plan folds the steps
into two existing jobs per the repo's stated convention.

**Success criteria.** 1 → Task 2 Step 6. 2 → Task 1 Step 4. 3 → Task 2 Step 7
(rendering is verified; a full GCP plan needs credentials and is left to the
next deploy). 4 → covered by the `gcp primary` fixture case rather than by
mutating the real tree. 5 → explicitly deferred to the next dual bootstrap,
as the design states.
