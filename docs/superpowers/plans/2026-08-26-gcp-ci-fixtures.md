# Per-Cluster CI Rendering and the Undefined-Variable Gate — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fail CI when a Flux Kustomization applies a `${var}` that its cluster's ConfigMap does not define, and stop rendering `gcp-0` overlays with AWS values.

**Architecture:** Extend `scripts/flux-schema/check-substitution.py`, which already walks cluster → Kustomization → applied variables. The missing half is the ConfigMap's keys, read from the `flux_cluster_vars` resource in each `configure` stack. Then split `FIXTURE_VARS` in `render-bundle.py` per cluster.

**Tech Stack:** Python 3 (stdlib + PyYAML), kustomize, OpenTofu HCL (read-only).

**Spec:** [`docs/superpowers/specs/2026-08-26-gcp-ci-fixtures-design.md`](../specs/2026-08-26-gcp-ci-fixtures-design.md)

## Global Constraints

- **Part A is the gate; Part B adds none.** Do not describe Part B as catching errors. It removes a documented falsehood from the bundle. The design explains why.
- **The ConfigMap extractor must fail loudly if its anchor disappears.** An empty key set would make every variable look undefined, and a silently skipped file would make every variable look fine. Both are worse than a crash.
- **Walk the cluster graph, never the filesystem, to decide what applies to whom.** `base/` is not uniformly shared: `infrastructure/base/karpenter` and `infrastructure/base/aws-load-balancer-controller` use AWS-only variables that `gcp-0` never references, and `infrastructure/base/crossplane` holds both AWS- and GCP-specific subtrees.
- **`aws-0`'s rendered bundle must not change.** Verify with a bundle grep, not by inspection.
- **`$${var}` is not a variable.** The existing `ESCAPED_RE`/`VAR_RE` pair already handles this (163 `$${datasource}`, 52 `$${model}` in the repo). Do not touch that logic.
- **Only two ConfigMaps exist**: `eks-aws-0-vars` (28 references) and `gke-gcp-0-vars` (11). An unrecognised name must fail, not be skipped.
- `./scripts/validate-manifests.sh` must still report `Invalid: 0, Skipped: 0`.

---

### Task 1: Read each cluster's ConfigMap keys

**Files:**
- Modify: `scripts/flux-schema/check-substitution.py`

**Interfaces:**
- Produces: `configmap_keys(name) -> set[str]`, used by Task 2.

- [ ] **Step 1: Confirm the shape both stacks share**

```bash
grep -n -A3 'resource "kubectl_manifest" "flux_cluster_vars"' \
  opentofu/aws/eks/configure/kubernetes.tf opentofu/gcp/gke/configure/kubernetes.tf
```

Both open the same way and reach a `data = {` block. Neither block contains a heredoc, a nested
brace, a ternary or a list — verified before this plan was written. Comments interleave and must be
skipped.

- [ ] **Step 2: Add the extractor**

```python
# The two cluster vars ConfigMaps, and the OpenTofu that declares them. Only
# these two names appear in any substituteFrom in clusters/ (28 and 11 uses);
# an unrecognised name is a mistake, not a case to skip.
CONFIGMAP_SOURCES = {
    "eks-aws-0-vars": "opentofu/aws/eks/configure/kubernetes.tf",
    "gke-gcp-0-vars": "opentofu/gcp/gke/configure/kubernetes.tf",
}

# Anchored on the resource name and the `data = {` inside it, NOT a general HCL
# parse -- this file's own docstring rightly calls that fragile. The block is
# plain `key = value` lines: no heredocs, nested braces, ternaries or lists.
_RESOURCE_RE = re.compile(r'resource\s+"kubectl_manifest"\s+"flux_cluster_vars"\s*\{')
_KEY_RE = re.compile(r"^\s+([a-z_][a-z0-9_]*)\s*=")


def configmap_keys(name):
    """Keys of a cluster vars ConfigMap, read from the OpenTofu that creates it.

    Raises rather than returning an empty set. An empty set would make every
    variable look undefined; a silently skipped file would make every variable
    look fine. Both are worse failures than a crash, because both look like a
    passing gate.
    """
    rel = CONFIGMAP_SOURCES.get(name)
    if rel is None:
        raise SystemExit(
            f"error: no OpenTofu source known for ConfigMap {name!r}.\n"
            f"       Known: {', '.join(sorted(CONFIGMAP_SOURCES))}.\n"
            f"       A new cluster vars ConfigMap must be added to CONFIGMAP_SOURCES."
        )
    path = REPO_ROOT / rel
    text = path.read_text()

    m = _RESOURCE_RE.search(text)
    if not m:
        raise SystemExit(
            f"error: {rel} no longer contains "
            f'resource "kubectl_manifest" "flux_cluster_vars".\n'
            f"       This check reads that block for the ConfigMap's keys; it cannot\n"
            f"       verify anything without it. Update _RESOURCE_RE if the resource\n"
            f"       was renamed."
        )

    lines = text[m.end():].splitlines()
    keys, in_data = set(), False
    for line in lines:
        stripped = line.strip()
        if not in_data:
            if stripped.startswith("data") and stripped.endswith("{"):
                in_data = True
            continue
        if stripped == "}":
            break
        if stripped.startswith("#"):
            continue
        km = _KEY_RE.match(line)
        if km:
            keys.add(km.group(1))

    if not keys:
        raise SystemExit(
            f"error: found no keys in {rel}'s flux_cluster_vars data block.\n"
            f"       The block shape changed. Refusing to report every variable as\n"
            f"       undefined on the strength of a parse that found nothing."
        )
    return keys
```

- [ ] **Step 3: Prove it reads both, and fails loudly**

```bash
python3 -c "
import sys; sys.path.insert(0, 'scripts/flux-schema')
import importlib; m = importlib.import_module('check-substitution')
a = m.configmap_keys('eks-aws-0-vars'); g = m.configmap_keys('gke-gcp-0-vars')
print('aws keys:', len(a)); print('gcp keys:', len(g))
print('aws-only:', sorted(a - g)); print('gcp-only:', sorted(g - a))
"
```

Expected: both non-empty, and the asymmetry visible — `aws_account_id`, `oidc_*`, `vpc_id`,
`karpenter_queue_name` on AWS only; `project_id`, `project_number`, `workload_pool`, `zone` on GCP
only. Report the two counts in your report.

Then confirm the loud failures:

```bash
python3 -c "
import sys; sys.path.insert(0,'scripts/flux-schema'); import importlib
m = importlib.import_module('check-substitution')
try: m.configmap_keys('nonexistent-vars')
except SystemExit as e: print('unknown name ->', str(e).splitlines()[0])
"
```

- [ ] **Step 4: Commit**

```bash
git add scripts/flux-schema/check-substitution.py
git commit -m "feat(ci): read each cluster's vars ConfigMap keys from its OpenTofu"
```

---

### Task 2: Fail when an applied variable is not defined

**Files:**
- Modify: `scripts/flux-schema/check-substitution.py` (`main()`, and the module docstring)

**Interfaces:**
- Consumes: Task 1's `configmap_keys`.

- [ ] **Step 1: Extend the per-Kustomization loop**

After the existing `wired` check, and only when substitution IS wired, diff the variables:

```python
        for ref in k["post_build"].get("substituteFrom", []):
            if ref.get("kind") != "ConfigMap":
                continue
            defined = configmap_keys(ref["name"])
            missing = [v for v in variables if v not in defined]
            if missing:
                failures.append(
                    f"  {k['file']}\n"
                    f"    Kustomization/{k['name']} path={k['path']}\n"
                    f"    applies {len(missing)} variable(s) that {ref['name']} "
                    f"does not define: {', '.join('${' + v + '}' for v in missing)}\n"
                    f"    -> Flux substitutes an EMPTY STRING for these. That is"
                    f" schema-valid and silently wrong.\n"
                    f"    -> Add them to {CONFIGMAP_SOURCES[ref['name']]}, or stop"
                    f" applying them from this path."
                )
```

Note `substitute` (inline key/values) is a separate mechanism and is not checked here — say so in a
comment rather than leaving the omission unexplained.

- [ ] **Step 2: Update the module docstring**

It currently ends with "Deliberately NOT checked here: whether each `${var}` is a key of the
ConfigMap named in `substituteFrom`… parsing HCL to find out would trade a precise check for a
fragile one." That is now false — the check exists, and it does not parse general HCL. Rewrite that
paragraph to describe what is checked and why the narrow anchored read is not the fragile thing the
old text warned about. **Keep the history**: say it was previously excluded and why the objection no
longer applies.

- [ ] **Step 3: Run it against the repo as it stands**

```bash
python3 scripts/flux-schema/check-substitution.py; echo "exit: $?"
```

Expected on `origin/main`: exit 0. If it fails, you have found a real pre-existing bug — **stop and
report it** rather than adjusting the check to pass. That outcome is a result, not an obstacle.

- [ ] **Step 4: Commit**

```bash
git add scripts/flux-schema/check-substitution.py
git commit -m "feat(ci): fail when a cluster applies a variable it does not define"
```

---

### Task 3: Prove the gate catches the three real omissions

**Files:**
- Create: `scripts/flux-schema/test-check-substitution.py`

**Interfaces:**
- Consumes: Tasks 1 and 2.

> `render-bundle.py`'s docstring references `test-flux-schema.sh` as a safety net. **That file does
> not exist** — there is no test harness for any of these scripts. This task adds the first one, for
> the new gate only. Fixing the stale reference is Task 5.

The gate must be shown to fire on the omissions it exists for. Workstream 9 needed `storage_class`,
`openbao_cidr` and `openbao_snapshot_secret` added to both ConfigMaps; each was caught only by a
human remembering. Note that on `origin/main` those keys do not all exist yet — `storage_class`
arrives with PR #1841 and the other two with #1844 — so the test must not assume them.

- [ ] **Step 1: Write a test that feeds synthetic key sets**

Do **not** mutate tracked files. Test the pure logic: given a set of applied variables and a set of
defined keys, the diff must report exactly the missing ones. Cover:

1. A variable applied and defined → no failure.
2. A variable applied and NOT defined → failure naming that variable.
3. A variable defined but not applied → no failure (ConfigMaps may carry unused keys).
4. `configmap_keys` on an unknown ConfigMap name → `SystemExit`.
5. `configmap_keys` against a temp file whose `flux_cluster_vars` resource is absent → `SystemExit`.
6. `configmap_keys` against a temp file whose `data` block is empty → `SystemExit`.

Cases 4–6 are the loud-failure contract from the Global Constraints, and they are the ones most
likely to rot silently, because nothing else exercises them.

- [ ] **Step 2: Also assert the real extraction is non-trivial**

```python
def test_real_configmaps_have_plausible_keys():
    aws = configmap_keys("eks-aws-0-vars")
    gcp = configmap_keys("gke-gcp-0-vars")
    assert "region" in aws and "region" in gcp
    assert "project_id" in gcp and "project_id" not in aws
    assert len(aws) > 10 and len(gcp) > 10
```

This is the guard against a parse that "succeeds" while finding two keys.

- [ ] **Step 3: Run it**

```bash
python3 scripts/flux-schema/test-check-substitution.py; echo "exit: $?"
```

Report the number of cases run and the exit code.

- [ ] **Step 4: Commit**

```bash
git add scripts/flux-schema/test-check-substitution.py
git commit -m "test(ci): cover the undefined-variable gate and its loud-failure contract"
```

---

### Task 4: Per-cluster fixtures

**Files:**
- Modify: `scripts/flux-schema/render-bundle.py`

- [ ] **Step 1: Split the map**

Keep `FIXTURE_VARS` as the shared/merged map — it is referenced elsewhere and `base/` roots keep
using it. Add two overlays on top:

```python
# Values that differ per cluster. FIXTURE_VARS stays the merged map: base/
# roots are rendered from it, because they belong to no cluster (they appear as
# roots only because top_most_overlays() treats a nested-but-unreferenced dir as
# one, and nothing deploys them). Per-cluster correctness for base/ is enforced
# by check-substitution.py, which walks the cluster graph instead of guessing
# from the path.
CLUSTER_FIXTURE_VARS = {
    "aws-0": {},                      # the merged map is already AWS-shaped
    "gcp-0": {
        "region": "europe-west4",
        "private_domain_name": "priv.gcp.cluster.local",
        # route53_region stays AWS-shaped even on gcp-0: it is an AWS region
        # hint for the Route53 solver, and gcp-0 really does substitute an AWS
        # region there. See opentofu/gcp/gke/configure's var.route53_region.
    },
}
```

Add every genuinely GCP-shaped value. `route53_region` is the trap: it is AWS-shaped *on purpose* on
both clusters, and the existing comment explains why. Do not "fix" it.

- [ ] **Step 2: Select by overlay root**

The cluster is the second path segment of the root (`security/gcp-0/openbao-snapshot` → `gcp-0`).
Anything else — including `base` — uses the merged map. Write the lookup so an unknown segment falls
back to merged rather than raising: a new area directory must not break the renderer.

- [ ] **Step 3: Prove aws-0 is unchanged and gcp-0 moved**

```bash
./scripts/validate-manifests.sh
grep -rho 'eu-west-3' .bundle/overlay-*aws-0* | head -3
grep -rho 'europe-west4' .bundle/overlay-*gcp-0* | head -3
```

`Invalid: 0, Skipped: 0`. AWS overlays still carry `eu-west-3`; GCP overlays now carry
`europe-west4`. Report both.

- [ ] **Step 4: Commit**

```bash
git add scripts/flux-schema/render-bundle.py
git commit -m "feat(ci): render gcp-0 overlays with GCP values, not AWS ones"
```

---

### Task 5: Documentation, and one stale reference

**Files:**
- Modify: `scripts/flux-schema/render-bundle.py` (the `test-flux-schema.sh` reference)
- Modify: `CLAUDE.md` and/or `.claude/rules/process.md` if either describes the validation gates

- [ ] **Step 1: Fix the stale test reference**

`render-bundle.py`'s `top_most_overlays()` docstring says "test-flux-schema.sh pins the known nested
cases as a safety net". That file does not exist. Either point at Task 3's new test if it covers the
case, or state plainly that the nested cases are **not** currently pinned by any test. Do not leave a
docstring claiming a safety net that is absent — that is the same class of defect as an inert
Renovate annotation.

- [ ] **Step 2: Record the new gate where the others are listed**

Find where `validate-manifests.sh` and its two gates are documented and add this check alongside,
with one line on what it catches: a variable a cluster applies but does not define, which Flux
substitutes as an empty string.

- [ ] **Step 3: Run the documentation gates**

```bash
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
./scripts/verify-doc-paths.sh
```

All three exit 0.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "docs(ci): record the undefined-variable gate, and drop a stale test reference"
```
