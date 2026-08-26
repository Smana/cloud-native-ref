# Portable Storage Classes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every PVC in `*/base/` name a storage class its cluster actually has, so shared manifests render correctly on both `aws-0` (`gp3`) and `gcp-0` (`balanced-rwo`).

**Architecture:** A single `storage_class` key is added to each cluster's vars ConfigMap, published by that cluster's `configure` OpenTofu stack. The eight hardcoded `gp3` values become `${storage_class}`, substituted by the `postBuild.substituteFrom` block every consuming Kustomization already declares. No new plumbing.

**Tech Stack:** OpenTofu, Flux `postBuild` variable substitution, Kustomize, Helm.

**Spec:** [`docs/superpowers/specs/2026-08-26-gcp-storage-class-design.md`](../specs/2026-08-26-gcp-storage-class-design.md)

## Global Constraints

- **`aws-0`'s rendered output must not change** apart from the substitution itself. It is a live cluster; a different storage class on an existing PVC is not a rename, it is a new volume.
- **`aws-0` value is `gp3`; `gcp-0` value is `balanced-rwo`.** Exact strings.
- **The `FIXTURE_VARS` entry is mandatory.** Without it the bundle renders a literal `${storage_class}`, which passes schema validation because `storageClassName` is a free-form string — the blind spot recorded in workstream 8.
- **Do not touch `volumeType: gp3`** in `infrastructure/base/karpenter-nodepools/default-ec2nc.yaml` or `karpenter-nodepools-gpu/gpu-l4-ec2nc.yaml`. That is an EC2 node root-volume type on a resource GKE does not have.
- **Do not touch `infrastructure/base/aws-efs-csi-driver/`.** Filestore is dropped; the EFS driver serves `aws-0` and is out of scope.
- **`./scripts/validate-manifests.sh` is the gate**, and `Invalid: 0, Skipped: 0` is part of the claim, not decoration.
- Never co-author commits; no "Generated with Claude Code" attribution. Commit messages in English.

---

### Task 1: Publish `storage_class` from both configure stacks

**Files:**
- Modify: `opentofu/aws/eks/configure/kubernetes.tf` (the `data = {` block at ~line 51)
- Modify: `opentofu/gcp/gke/configure/kubernetes.tf` (the cloud-neutral block at ~line 50)

**Interfaces:**
- Consumes: nothing.
- Produces: a `storage_class` key on `eks-aws-0-vars` (value `gp3`) and on `gke-gcp-0-vars` (value `balanced-rwo`). Task 2's manifests substitute it; Task 3's fixture mirrors it.

- [ ] **Step 1: Add the key to the AWS ConfigMap**

In `opentofu/aws/eks/configure/kubernetes.tf`, inside the `data = {` block, add after `region`:

```hcl
      # The cluster's default block-storage class for PVCs. Shared name with
      # the GCP ConfigMap, different value: EKS's EBS CSI provides gp3, GKE
      # provides balanced-rwo. Both are SSD-backed and both are consumed as an
      # opaque string by storageClassName -- nothing derives anything else from
      # it, which is what makes one shared key honest here where ${region} was
      # not (see the workstream 13 design).
      storage_class = "gp3"
```

Match the surrounding alignment — that block aligns its `=` signs.

- [ ] **Step 2: Add the key to the GCP ConfigMap**

In `opentofu/gcp/gke/configure/kubernetes.tf`, inside the block commented `# Cloud-neutral — names shared with the AWS ConfigMap.`, add after `region`:

```hcl
      # balanced-rwo is pd-balanced, GKE's SSD class and the honest gp3
      # equivalent. NOT standard-rwo: that is pd-standard (HDD), and the
      # largest consumer is a VictoriaMetrics cluster whose write path is
      # I/O-sensitive -- a reference platform running it on HDD would be
      # unrepresentative of production.
      storage_class = "balanced-rwo"
```

- [ ] **Step 3: Verify both stacks still parse**

```bash
cd opentofu/aws/eks/configure && tofu fmt -check && tofu init -backend=false -input=false >/dev/null && tofu validate
cd ../../../gcp/gke/configure && tofu fmt -check && tofu init -backend=false -input=false >/dev/null && tofu validate
```

Expected: `tofu fmt -check` exit 0 for both (no diff), and `Success! The configuration is valid.` twice. If `fmt` reports a diff, the alignment is off — run `tofu fmt` and re-check.

Remove any `.terraform/` and `.terraform.lock.hcl` the local `init` created, so the worktree stays clean.

- [ ] **Step 4: Commit**

```bash
git add opentofu/aws/eks/configure/kubernetes.tf opentofu/gcp/gke/configure/kubernetes.tf
git commit -m "feat(storage): publish a storage_class var from both configure stacks

gp3 on aws-0, balanced-rwo on gcp-0. One shared key name, different values --
honest here because storageClassName consumes it as an opaque string and
nothing derives anything else from it, unlike \${region}, which was fed to the
AWS SDK and broke on a GCP value."
```

---

### Task 2: Substitute the variable at all eight call sites

**Files:**
- Modify: `observability/base/victoria-metrics-k8s-stack/helmrelease-vmcluster.yaml` (2 occurrences)
- Modify: `observability/base/victoria-traces/helmrelease-vtsingle.yaml`
- Modify: `observability/base/grafana-oncall/helmrelease-rabbitmq.yaml`
- Modify: `observability/base/runlore/helmrelease.yaml`
- Modify: `infrastructure/base/vllm-semantic-router/helmrelease.yaml`
- Modify: `apps/base/openwebui/pvc.yaml`
- Modify: `tooling/base/gha-runners/default-scale-set-helmrelease.yaml`

**Interfaces:**
- Consumes: `storage_class` from Task 1.
- Produces: eight manifests that render per-cluster. Task 3's fixture is what makes them render in CI at all.

- [ ] **Step 1: Confirm the exact call sites before editing**

```bash
grep -rn 'storageClassName\|storageClass:' --include=*.yaml \
  infrastructure/ observability/ apps/ tooling/ | grep gp3
```

Expected: exactly 8 lines, matching the Files list above. Note the quoting is inconsistent across them — some are `gp3`, some `"gp3"`. **Preserve each file's existing quoting style**; `${storage_class}` and `"${storage_class}"` both substitute identically, and a gratuitous quoting change adds diff noise to a file you are otherwise barely touching.

If the count is not 8, stop and report — the plan was written against a specific tree and something has moved.

- [ ] **Step 2: Replace each occurrence**

Change `gp3` → `${storage_class}` (or `"gp3"` → `"${storage_class}"`) at each of the 8 sites. Nothing else in these files changes.

Do **not** touch:
- `infrastructure/base/karpenter-nodepools/default-ec2nc.yaml` — `volumeType: gp3`, an EC2 node root-volume type
- `infrastructure/base/karpenter-nodepools-gpu/gpu-l4-ec2nc.yaml` — same
- `apps/base/ai/llm/models-pvc.yaml` — `s3files-llm-models`, the EFS-backed static PV, out of scope
- `security/base/openbao-snapshot/s3-bucket.yaml` — `storageClass: GLACIER` is an S3 lifecycle tier, unrelated

- [ ] **Step 3: Verify no `gp3` remains where a variable belongs**

```bash
grep -rn 'gp3' --include=*.yaml infrastructure/ observability/ apps/ tooling/ security/ | grep -v volumeType
```

Expected: **no output**. Any hit that is not a Karpenter `volumeType` is a missed call site. (Comments mentioning gp3 are acceptable if they now read as history — check each.)

- [ ] **Step 4: Commit**

```bash
git add observability/ infrastructure/ apps/ tooling/
git commit -m "feat(storage): substitute \${storage_class} at all eight PVC call sites

These manifests live under */base/ and are shared between clusters, but named
gp3 -- which EKS's EBS CSI provides and GKE does not. A PVC asking for it on
gcp-0 binds to nothing and stays Pending with no error naming the cause.

Karpenter's volumeType: gp3 is deliberately untouched: that is an EC2 node
root-volume type on a resource GKE does not have, so substituting there would
be a category error."
```

---

### Task 3: Teach the render fixture, and prove the gate catches a regression

**Files:**
- Modify: `scripts/flux-schema/render-bundle.py` (the `FIXTURE_VARS` dict at ~line 72)

**Interfaces:**
- Consumes: the variable name `storage_class` from Task 1.
- Produces: a CI bundle that renders a real value rather than a literal `${storage_class}`.

**Why this task is not optional.** `render-bundle.py` substitutes `FIXTURE_VARS` and passes unmapped names through verbatim. `storageClassName` is a free-form string in every schema, so a bundle containing the literal `${storage_class}` **passes validation**. Without the fixture, Task 2 would be silently unverified — the exact blind spot recorded in the workstream 8 design.

- [ ] **Step 1: Add the fixture entry**

In `scripts/flux-schema/render-bundle.py`, add to `FIXTURE_VARS` beside the other cloud-neutral entries:

```python
    # Both clusters define this; the value differs (gp3 / balanced-rwo) but the
    # SHAPE does not -- it is an opaque string either way, which is why one
    # fixture is honest here. Contrast "region" above, where a single
    # AWS-shaped fixture masks a GCP-shaped runtime value.
    "storage_class": "gp3",
```

- [ ] **Step 2: Run the gate**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
```

Expected: `Invalid: 0, Skipped: 0` and `All gates passed`, exit 0 for both. `check-substitution.py` confirms every manifest using `${storage_class}` is applied by a Kustomization declaring `postBuild` — all of them already do, so this should pass without further change. If it reports an inconsistency, a consuming Kustomization is missing `postBuild.substituteFrom` and that must be fixed before proceeding.

- [ ] **Step 3: Confirm the substitution actually happened**

```bash
grep -rc 'storageClassName: gp3\|storageClassName: "gp3"' .bundle/ | grep -v ':0' | head
grep -rn '\${storage_class}' .bundle/ | head
```

Expected: the first finds rendered `gp3` values (the fixture worked); the second finds **nothing** (no unsubstituted literals). A hit on the second means a manifest uses the variable from a Kustomization without `postBuild`.

- [ ] **Step 4: Mutation-test the gate**

This is the step that proves the coverage is real rather than decorative. Temporarily delete the `storage_class` line from `FIXTURE_VARS`, re-run, and confirm the bundle now contains literals:

```bash
python3 - <<'EOF'
import pathlib, re
p = pathlib.Path("scripts/flux-schema/render-bundle.py")
s = p.read_text()
p.write_text(re.sub(r'\n *"storage_class": "gp3",', '', s, count=1))
EOF
./scripts/validate-manifests.sh >/dev/null 2>&1
grep -rn '\${storage_class}' .bundle/ | head -3
```

Expected: unsubstituted `${storage_class}` literals **do** appear in the bundle. Record whether `validate-manifests.sh` itself failed or passed anyway — **if it passed, say so plainly in the report**: it means the schema gate cannot catch this class, the fixture is the only protection, and that is worth knowing rather than glossing.

Then restore:

```bash
git checkout scripts/flux-schema/render-bundle.py
```

and re-apply Step 1's entry before committing.

- [ ] **Step 5: Commit**

```bash
git add scripts/flux-schema/render-bundle.py
git commit -m "test(ci): fixture for storage_class so the bundle renders a real value

render-bundle.py passes unmapped variable names through verbatim, and
storageClassName is a free-form string in every schema -- so without this entry
the bundle would carry a literal \${storage_class} and still pass validation.
Same blind spot recorded in the objectStore design."
```

---

### Task 4: Verify per-cluster rendering, and document the pattern

**Files:**
- Modify: `website/content/docs/platform/developer-platform/app-field-reference.md` — only if it documents a storage class; check first
- Create: `docs/superpowers/specs/2026-08-26-gcp-storage-class-verification.md`

**Interfaces:**
- Consumes: everything above.

**No cluster deploy.** Both clusters are torn down and this change is verifiable from the rendered bundle: the substitution is a build-time concern, and a live deploy would prove nothing the bundle does not. That is a deliberate scope call — record it in the verification document rather than leaving a reader to assume a cluster was tested.

- [ ] **Step 1: Confirm each cluster's bundle gets the right value**

`render-bundle.py` uses one fixture map for both clusters, so it cannot show the per-cluster difference. Read it from the source of truth instead — the two ConfigMaps:

```bash
grep -n 'storage_class' opentofu/aws/eks/configure/kubernetes.tf
grep -n 'storage_class' opentofu/gcp/gke/configure/kubernetes.tf
```

Expected: `gp3` in the first, `balanced-rwo` in the second. Paste both lines into the verification document — this is the only place the per-cluster difference is asserted, and the single-fixture limitation is precisely why it must be asserted here rather than inferred from the bundle.

- [ ] **Step 2: Confirm `aws-0` is unchanged**

The global constraint is that AWS's rendered output changes only by substitution. Verify against the merge base:

```bash
git stash list >/dev/null 2>&1  # no-op; just avoid a bare `git stash`
git diff origin/main --stat -- observability/ infrastructure/ apps/ tooling/
```

Expected: only the eight lines from Task 2. Any other changed line in those trees is out of scope and must be justified or reverted.

- [ ] **Step 3: Check whether any doc names the storage class**

```bash
grep -rn 'gp3' website/content/docs/ docs/architecture/ 2>/dev/null | grep -v superpowers
```

If a page documents `gp3` as the storage class a developer gets, update it to say the class is per-cluster (`gp3` on `aws-0`, `balanced-rwo` on `gcp-0`) and supplied by the platform. If nothing matches, say so in the report — a null result is a finding, not a skipped step. **Do not** edit archived specs under `docs/specs/` or the superpowers directories.

- [ ] **Step 4: Write the verification document**

Create `docs/superpowers/specs/2026-08-26-gcp-storage-class-verification.md` with each of the spec's six success criteria, the command run, and its output pasted inline. Criterion 4 (the mutation test) carries Task 3 Step 4's finding, including whether `validate-manifests.sh` failed or passed. State plainly that no cluster was deployed and why.

- [ ] **Step 5: Run every gate fresh and commit**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
./scripts/verify-doc-paths.sh
```

Expected: all exit 0; `validate-manifests.sh` reports `Invalid: 0, Skipped: 0`.

```bash
git add docs/superpowers/specs/2026-08-26-gcp-storage-class-verification.md website/
git commit -m "docs: verification for the portable storage-class change"
```

---

## Self-Review

**Spec coverage.** Mechanism → Task 1. Eight call sites → Task 2. Fixture → Task 3. Karpenter and EFS exclusions → Task 2 Step 2, stated as explicit do-not-touch lists. Success criteria 1–6 → Task 4, with criterion 4's mutation test in Task 3 Step 4. Filestore removal → already done in the design commit; no task needed, and the roadmap table was amended so it cannot be re-added from there.

**No placeholders.** Every step carries the actual content: the HCL to add, the grep to run, the expected counts, the mutation-test script.

**Consistency.** The variable is `storage_class` in the ConfigMaps, `${storage_class}` in manifests, and `"storage_class"` in `FIXTURE_VARS` — one name, three syntaxes, each correct for its context.

**One judgement recorded rather than hidden:** Task 4 deploys no cluster. The change is build-time and the bundle proves it; a deploy would cost real money to demonstrate nothing new. If a reviewer disagrees, the argument to beat is that a rendered `balanced-rwo` in a manifest and a bound PVC on GKE test the same substitution — the latter merely also tests that GKE has a class by that name, which Google guarantees.
