# LLM Platform on GCP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `gcp-0` the LLM platform `aws-0` has, with model weights on Cloud Storage FUSE instead of Amazon S3 Files, shipped gated-off exactly as the AWS one is.

**Architecture:** A GCS bucket holds the weights and is mounted by GKE's Cloud Storage FUSE CSI driver through a static PV/PVC pair, mirroring the shape the `InferenceService` composition already expects. The preload Job's identity becomes a bucket-scoped `GCPWorkloadIdentity`. A suspended umbrella at `clusters/gcp-0/llm-platform.yaml` gates six children under `clusters/gcp-0-llm-platform/`.

**Spec:** [`docs/superpowers/specs/2026-08-26-gcp-llm-platform-design.md`](../specs/2026-08-26-gcp-llm-platform-design.md)
**ADR:** [`website/content/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md`](../../../website/content/docs/decisions/0021-gcs-fuse-for-model-weights-on-gcp.md)

## Global Constraints

- **`aws-0`'s rendered output must not change.** Verify with a bundle grep, not by inspection.
- **The bucket is `${project_id}-ogenki-llm-models`, NOT `${region}-…`.** The Crossplane principal's storage role is conditioned on `resource.name.startsWith('projects/_/buckets/<project_id>-ogenki-')`. A region-prefixed name fails at create with a 403 naming `storage.buckets.create` — a permission the role *does* grant, so the error points nowhere near the condition that rejected it. Measured live in workstream 9; do not re-learn it.
- **GCS grants are `bucketRoles`, never project-level `roles:`.** Item shape `{bucket, role}` — `role` SINGULAR. A project-level `roles/storage.*` reaches OpenBao's snapshots and CNPG's backups.
- **Never reconstruct the `principal://` string.** The composition builds it; `projects/` takes the project NUMBER and `workloadIdentityPools/` the project ID, and reversing them yields a binding the API accepts and which silently never matches.
- **Both gates ship CLOSED.** The umbrella is `suspend: true`. Nothing here should deploy anything.
- **Every new `${var}` must exist in both clusters' ConfigMaps**, or be applied only from a path one cluster owns. `scripts/flux-schema/check-substitution.py` now enforces this — it did not exist for workstreams 9 or 13, and it is why their variable omissions must not repeat.
- `./scripts/validate-manifests.sh` must report `Invalid: 0, Skipped: 0`, and `check-substitution.py` must exit 0.

---

### Task 1: Enable the Cloud Storage FUSE CSI driver on gcp-0

**Files:**
- Modify: `opentofu/gcp/gke/init/main.tf`

- [ ] **Step 1: Find the real variable name — do not write one from memory**

`.terraform/` is gitignored, so the module source is not in a fresh worktree. Get it first:

```bash
tofu -chdir=opentofu/gcp/gke/init init -backend=false
grep -rn 'gcs_fuse\|gcsfuse' opentofu/gcp/gke/init/.terraform/modules/gke/modules/private-cluster/variables.tf
```

Report the exact variable name and its default. If no such variable exists on `~> 44.3`, **stop and
report** — the addon would then need `google_container_cluster`'s `addons_config` directly, which is
a different change and not what this task assumes.

A wrong name here does not fail loudly. It produces a cluster where every FUSE mount hangs with no
obvious cause, which is expensive to diagnose on a GPU cluster.

- [ ] **Step 2: Enable it**

Set the flag in the `module "gke"` block, with a comment saying what depends on it (the LLM
platform's weights mount) and that it is inert until the umbrella is resumed — this is an addon on a
cluster whose LLM stack ships suspended, so a reader should not think it is unused.

- [ ] **Step 3: Validate**

```bash
tofu -chdir=opentofu/gcp/gke/init fmt -check
tofu -chdir=opentofu/gcp/gke/init validate
```

Both exit 0. **Do not run `tofu apply`** — no cluster is deployed and none should be.

- [ ] **Step 4: Commit**

```bash
git add opentofu/gcp/gke/init/main.tf
git commit -m "feat(gcp): enable the Cloud Storage FUSE CSI driver on gcp-0"
```

---

### Task 2: Move the AWS-only weights resources out of the shared base

**Files:**
- Move: `apps/base/ai/llm/s3-bucket.yaml` → `apps/aws-0/llm/s3-bucket.yaml`
- Move: `apps/base/ai/llm/models-pvc.yaml` → `apps/aws-0/llm/models-pvc.yaml`
- Modify: `apps/base/ai/llm/kustomization.yaml`
- Create: `apps/aws-0/llm/kustomization.yaml`
- Modify: `apps/llm/kustomization.yaml`

`apps/base/ai/llm/` currently holds two resources that only work on AWS: an
`s3.aws.m.upbound.io` Bucket, and a PV whose `csi.driver` is `efs.csi.aws.com`. This is the same
shape workstreams 9 and 12 removed from `security/base` and `tooling/base` — a shared base carrying
cloud-specific resources.

- [ ] **Step 1: Confirm what is actually AWS-specific before moving anything**

```bash
grep -l 'aws\|s3\|efs' apps/base/ai/llm/*.yaml
```

Expected: `s3-bucket.yaml` and `models-pvc.yaml`. The model manifests (`qwen3-8b.yaml`,
`llamaguard3-1b.yaml`, …), the dashboards, the VMRules, the HF token ExternalSecret and the preload
ServiceAccount are cloud-neutral and **must stay in base**. If the grep names others, read them
before deciding — a false move is worse than none.

- [ ] **Step 2: Move the two files and re-point**

```bash
mkdir -p apps/aws-0/llm
git mv apps/base/ai/llm/s3-bucket.yaml apps/aws-0/llm/s3-bucket.yaml
git mv apps/base/ai/llm/models-pvc.yaml apps/aws-0/llm/models-pvc.yaml
```

`models-pvc.yaml` carries a long comment about the `volumeHandle` being regenerated by every
`tofu apply` and needing a manual update, plus a TODO to close that loop. **That comment travels with
the file unchanged** — it documents a live operational wart on `aws-0`.

Drop both from `apps/base/ai/llm/kustomization.yaml`. Create `apps/aws-0/llm/kustomization.yaml`
pulling `../../base/ai/llm` plus the two moved files. Then `apps/llm/kustomization.yaml` — which is
the *AWS* overlay despite its cloud-neutral name — points at `../aws-0/llm` instead of
`../base/ai/llm`.

- [ ] **Step 3: Prove aws-0 is unchanged**

```bash
./scripts/validate-manifests.sh
grep -rc 'efs.csi.aws.com' .bundle/ | grep -v ':0' | head
grep -rho 'external-name: [a-z0-9-]*ogenki-llm-models' .bundle/ | sort -u
```

The `efs.csi.aws.com` PV must still render exactly once, and the bucket external-name must still read
`eu-west-3-ogenki-llm-models`. `Invalid: 0, Skipped: 0`.

- [ ] **Step 4: Commit**

```bash
git add -A apps/
git commit -m "refactor(llm): move the AWS-only weights bucket and PV out of the shared base"
```

---

### Task 3: The GCP weights path — bucket, mount, identity

**Files:**
- Create: `apps/gcp-0/llm/{kustomization.yaml,gcs-bucket.yaml,models-pv.yaml,workloadidentity.yaml}`

- [ ] **Step 1: The bucket**

`apps/gcp-0/llm/gcs-bucket.yaml`, mirroring `security/gcp-0/openbao-snapshot/gcs-bucket.yaml`:

```yaml
apiVersion: storage.gcp.m.upbound.io/v1beta1
kind: Bucket
metadata:
  name: llm-models
  namespace: llm
  annotations:
    crossplane.io/external-name: ${project_id}-ogenki-llm-models
spec:
  # Model weights outlive any cluster: a fresh preload is ~15 min per model
  # plus a HuggingFace access wait. Crossplane must never attempt a delete --
  # see the same policy on Harbor's and CNPG's buckets.
  managementPolicies: ["Observe", "Create", "Update", "LateInitialize"]
  forProvider:
    location: ${region}
    uniformBucketLevelAccess: true
    forceDestroy: false
```

Note `managementPolicies` without `Delete`, for the reason workstream 9's Task 9 established.

- [ ] **Step 2: The static PV/PVC**

`apps/gcp-0/llm/models-pv.yaml`. The AWS original is a cluster-scoped PV plus a namespaced PVC in
`llm`, RWM, which the `InferenceService` composition mounts with a per-claim `subPath`. Keep that
shape so the composition needs no change:

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: llm-models
spec:
  capacity:
    storage: 100Gi
  accessModes:
    - ReadWriteMany
  persistentVolumeReclaimPolicy: Retain
  storageClassName: gcsfuse-llm-models
  mountOptions:
    - implicit-dirs
  csi:
    driver: gcsfuse.csi.storage.gke.io
    # Just the bucket name. Unlike aws-0's `s3files:<fs-id>::<ap-id>`, which is
    # regenerated by every `tofu apply` and updated by hand (see the TODO in
    # apps/aws-0/llm/models-pvc.yaml), this handle is deterministic -- so the
    # manual loop that file describes does not exist on GCP.
    volumeHandle: ${project_id}-ogenki-llm-models
  claimRef:
    namespace: llm
    name: llm-models
```

plus the matching PVC, mirroring the AWS one.

**Verify `storageClassName` against the driver's requirements for static provisioning** rather than
copying the AWS value's shape — some CSI drivers require an empty class here to prevent dynamic
provisioning. Report what you found and why you chose it.

- [ ] **Step 3: The identity**

`apps/gcp-0/llm/workloadidentity.yaml` — a `GCPWorkloadIdentity` granting the preload
ServiceAccount write on that one bucket:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: GCPWorkloadIdentity
metadata:
  name: xplane-llm-models-preload
  namespace: llm
spec:
  serviceAccount:
    name: llm-models-preload
  bucketRoles:
    - bucket: ${project_id}-ogenki-llm-models
      role: roles/storage.objectAdmin
```

Read `apps/base/ai/llm/preload-serviceaccount.yaml` first and use the ServiceAccount name it actually
declares. **Serving pods read through the FUSE mount and need their own access** — determine from the
driver's docs whether the mount uses the pod's ServiceAccount identity, and if so whether serving
pods need a second, read-only `GCPWorkloadIdentity`. Do not grant `objectAdmin` to serving pods to
avoid finding out.

- [ ] **Step 4: Validate**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
```

`Invalid: 0, Skipped: 0`, and `check-substitution.py` exits 0. If it reports a variable `gke-gcp-0-vars`
does not define, that is the new gate doing its job — add the key to the ConfigMap rather than
removing the reference.

- [ ] **Step 5: Commit**

```bash
git add -A apps/gcp-0
git commit -m "feat(gcp): model weights on a GCS bucket mounted through Cloud Storage FUSE"
```

---

### Task 4: The umbrella and its six children

**Files:**
- Create: `clusters/gcp-0/llm-platform.yaml`
- Create: `clusters/gcp-0-llm-platform/{kustomization.yaml,README.md}` and six child Kustomizations

- [ ] **Step 1: Read the AWS umbrella and mirror its gating exactly**

```bash
cat clusters/aws-0/llm-platform.yaml
ls clusters/aws-0-llm-platform/
```

The umbrella's path **must be a sibling** of `clusters/gcp-0/`, not a sub-path. The AWS file explains
why in its own comment: `flux-system` syncs `clusters/<cluster>/` recursively, so a child underneath
it would be auto-discovered and applied, bypassing `spec.suspend: true`. Getting this wrong ships an
LLM platform that deploys itself.

- [ ] **Step 2: Write the umbrella**

`clusters/gcp-0/llm-platform.yaml` with `suspend: true`, `path: ./clusters/gcp-0-llm-platform`.
Adapt the AWS comment block: the teardown command list differs (no `gpu-nodepools`, no
`runtimeclass-nvidia`), and there is **no OpenTofu opt-in stack on GCP** — `opentofu/aws/llm-platform`
has no GCP counterpart because the weights bucket is a Crossplane claim here, not a Terraform-managed
filesystem. Say so rather than leaving a reader looking for one.

- [ ] **Step 3: Write the six children**

| Child | Path | Notes |
|---|---|---|
| `llm-platform-apps` | `./apps/gcp-0/llm` | substitutes from `gke-gcp-0-vars` |
| `llm-platform-security-wi` | the GCP identity path | replaces AWS's `security-llm-epi` |
| `envoy-gateway` | as AWS | cloud-agnostic |
| `envoy-ai-gateway` | as AWS | cloud-agnostic |
| `vllm-semantic-router` | as AWS | cloud-agnostic |
| `promptfoo` | as AWS | cloud-agnostic |

**No `gpu-nodepools` child** — `infrastructure/gcp-0/computeclass/gpu-l4.yaml` already provisions g2 +
L4 on spot, from workstream 4. **No `runtimeclass-nvidia` child** — that exists on AWS only because
Bottlerocket's NVIDIA AMI advertises `nvidia.com/gpu` through kubelet and crashloops the upstream
device plugin; GKE manages drivers itself. Record both absences in the README so neither reads as an
oversight.

Copy each cloud-agnostic child's `dependsOn` from its AWS counterpart and then **check the named
Kustomizations exist on gcp-0** — several `aws-0` Kustomizations have no GCP equivalent, and a
`dependsOn` naming one that does not exist wedges the whole tree with a `dependency not ready` that
points at the wrong thing.

- [ ] **Step 4: The README**

Mirror `clusters/aws-0-llm-platform/README.md`: what the children are, how to enable, how to tear
down. State the two absences and why, and that enabling costs GPU spend.

- [ ] **Step 5: Validate**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
grep -n 'suspend' clusters/gcp-0/llm-platform.yaml
```

`Invalid: 0, Skipped: 0`; `check-substitution.py` exits 0; the umbrella is `suspend: true`.

- [ ] **Step 6: Commit**

```bash
git add -A clusters/
git commit -m "feat(gcp): suspended LLM platform umbrella and its six children"
```

---

### Task 5: Documentation

**Files:**
- Modify: `docs/superpowers/specs/2026-08-18-gcp-support-design.md` (workstream 14's row)
- Modify: `CLAUDE.md` — the "Self-Hosted LLM Platform (opt-in)" section is AWS-only today

- [ ] **Step 1: Mark workstream 14**

Set its status with what shipped, and correct the row's description if it misdescribes the result —
the row says "GCS Fuse weights, no `runtimeclass-nvidia`", which is right, but it also implies a GPU
`ComputeClass` is part of this workstream when workstream 4 already delivered it.

**Check every other row's status against `git log` before touching the table.** Rows 9, 13 and 15
merged today; if any still says otherwise, fix it. That table is the live index, and this is the last
workstream — leaving it wrong is leaving the programme's own record wrong.

- [ ] **Step 2: Make CLAUDE.md's LLM section cover both clouds**

It currently describes one platform with two gates, both AWS. Add the GCP side: one gate not two (no
OpenTofu opt-in stack), six children not eight, weights on GCS FUSE per ADR-0021, and the
`flux resume` command naming the gcp-0 umbrella.

- [ ] **Step 3: Run the documentation gates**

```bash
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
./scripts/verify-doc-paths.sh
```

All three exit 0.

- [ ] **Step 4: Commit**

```bash
git add -A docs/ CLAUDE.md
git commit -m "docs(gcp): record workstream 14 and the two-cloud LLM platform"
```

---

### Task 6: The HuggingFace token key must be legal on both clouds

> Added during execution. Task 1's implementer flagged that
> `apps/base/ai/llm/hf-token-externalsecret.yaml`'s comment names AWS Secrets Manager. Reading the
> file showed something sharper than a stale comment.

**Files:**
- Modify: `apps/base/ai/llm/hf-token-externalsecret.yaml`
- Modify: `opentofu/aws/eks/configure/kubernetes.tf`, `opentofu/gcp/gke/configure/kubernetes.tf`
- Modify: `scripts/flux-schema/render-bundle.py` (`FIXTURE_VARS`)
- Modify: `docs/gcp-bootstrap.md`

**The problem.** The ExternalSecret extracts `key: /platform/llm/hf_token`. That is a **path-style
name**, and GCP Secret Manager IDs cannot contain `/` — the identical defect workstream 9's Task 14
fixed for the snapshot credentials. On `gcp-0` this fails, and it fails at *runtime*: the
ExternalSecret never syncs, the `hf-token` Secret never exists, and every InferenceService claim that
`envFrom`s it fails to start.

Two things about it are worth noticing:

- **`check-substitution.py` cannot catch this.** The key is a literal string, not a `${var}`. The new
  gate closes the undefined-variable hole, not the wrong-literal one. This is the same free-form
  string blind spot that let a non-existent StorageClass through in workstream 13.
- **The `secretStoreRef` is already portable.** Both clusters have a `ClusterSecretStore` named
  `clustersecretstore` — `aws-0`'s reads AWS Secrets Manager, `gcp-0`'s reads GCP Secret Manager. Only
  the key is wrong.

- [ ] **Step 1: Template the key**

`key: ${llm_hf_token_secret}` in the base ExternalSecret. Update the comment: it currently says
"Pulled from AWS Secrets Manager at /platform/llm/hf_token", which becomes false the moment this is
shared. Say that each cluster's ConfigMap supplies the name, and why the two differ in shape.

- [ ] **Step 2: Define it on both clusters**

Add the key `llm_hf_token_secret` to both vars ConfigMaps, with these values:

| Cluster stack | Value |
|---|---|
| `opentofu/aws/eks/configure/kubernetes.tf` | the existing path-style name, unchanged, so `aws-0` renders byte-identical |
| `opentofu/gcp/gke/configure/kubernetes.tf` | a flat dash-separated ID, matching the convention its siblings use |

Comment both with the reason the shapes differ: AWS Secrets Manager permits `/`, GCP Secret Manager
forbids it. Cross-reference `openbao_snapshot_secret`, which carries the same split for the same
reason.

- [ ] **Step 3: Add the fixture entry**

`FIXTURE_VARS` gains the key with the AWS value, so the rendered bundle is unchanged. Without it the
key renders **empty** and the ExternalSecret extracts nothing — schema-valid, useless.

> Write the entry as key and value on separate lines or via a comment, not as a literal
> `"..._secret": "..."` pair in prose: `detect-secrets`' Secret Keyword heuristic fires on a key
> containing `secret` adjacent to a quoted value. In `.py` and `.tf` files the baseline covers it; it
> is prose that needs care.

- [ ] **Step 4: Document the GCP prerequisite**

The token is **not created by OpenTofu on either cloud** — it is a hand-created entry, confirmed by
grepping all of `opentofu/` for `hf_token` and finding nothing. `docs/gcp-bootstrap.md` already lists
three hand-created GCP prerequisites; this is a fourth, needed only if the LLM platform is enabled.
Say that last part — it is not required for a plain `gcp-0`.

- [ ] **Step 5: Verify**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
grep -rn 'hf_token\|hf-token' .bundle/ | grep -i 'key:' | sort -u
```

`Invalid: 0, Skipped: 0`; the check exits 0; the rendered `aws-0` key still reads
`/platform/llm/hf_token`; and no literal `${llm_hf_token_secret}` survives anywhere in `.bundle/`.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "fix(llm): the HuggingFace token key must be legal on both clouds"
```
