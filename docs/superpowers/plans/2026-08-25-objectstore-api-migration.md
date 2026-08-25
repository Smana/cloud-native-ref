# `objectStore` API Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the `App` composition's AWS-shaped `spec.s3Bucket` with a cloud-neutral `spec.objectStore` that works on both `aws-0` (S3) and `gcp-0` (GCS), with no cloud named in the claim.

**Architecture:** The compositions live in a separate repo and ship as OCI packages. One `main.k` is inlined into two Composition manifests — `composition-aws.yaml` and `composition-gcp.yaml` — each routed to its own package and each selecting its own EnvironmentConfig, which gains an explicit `cloud:` key the KCL branches on. Each cluster installs only one package, so no selector labels are needed and no cloud leaks into the claim.

**Tech Stack:** Crossplane v2 (`m.upbound.io` namespaced managed resources), KCL via `function-kcl`, `function-environment-configs`, Flux, OCI Configuration packages.

**Spec:** [`docs/superpowers/specs/2026-08-25-objectstore-api-migration-design.md`](../specs/2026-08-25-objectstore-api-migration-design.md)

## Two repositories

| Repo | Path | Holds |
|---|---|---|
| `Smana/crossplane-configuration` | `/home/smana/Sources/crossplane-configuration` | XRDs, KCL, Compositions, packages. **Tasks 1–5.** |
| `Smana/cloud-native-ref` | this worktree | Package pins, EnvironmentConfigs, claims. **Tasks 6–7.** |

Tasks 1–5 must be released before Task 6 can pin them. Task 6 cuts that release.

## Global Constraints

- **Never mutate a dict or list after creation in KCL** — function-kcl [#285](https://github.com/crossplane-contrib/function-kcl/issues/285) re-evaluates and emits resources twice. Build each set in ONE expression. `main.k:544` (`_s3ResourceList`) exists solely because of this; its comment records a live incident.
- **List comprehensions must be single-line.** `kcl fmt` is enforced by CI.
- **Resource naming:** IAM-bearing resources carry the `xplane-` prefix, applied by the composition via `_managedMetadata`, never typed by a developer. The prefix is load-bearing for IAM scoping on both clouds.
- **`task check`** in `crossplane-configuration` is the gate there: generate-sync, `kcl fmt`, `kcl test`, XRD schema, render equivalence against golden fixtures.
- **`./scripts/validate-manifests.sh`** is the gate in `cloud-native-ref`, and `Invalid: 0, Skipped: 0` is part of the claim, not decoration.
- **Never co-author commits**; no "Generated with Claude Code" lines. Commit messages and PR text in English.
- **Nothing stays running.** Any cluster deployed for verification is torn down, verified against the cloud API rather than an exit code.

---

### Task 1: `GCPWorkloadIdentity` gains bucket-scoped grants

**Files:**
- Modify: `apis/gcpworkloadidentity/definition.yaml`
- Modify: `apis/gcpworkloadidentity/kcl/main.k`
- Modify: `apis/gcpworkloadidentity/kcl/main_test.k`
- Modify: `apis/gcpworkloadidentity/kcl/settings-example.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: `spec.bucketRoles: [{bucket: str, role: str}]` on `GCPWorkloadIdentity`, rendering one `BucketIAMMember` per entry. Task 4's GCP branch sets it.

**Why this task exists.** `GCPWorkloadIdentity` today renders `ProjectIAMMember` and nothing else. Granting `roles/storage.objectAdmin` that way would give an app admin over *every* bucket in the project — OpenBao's snapshots, Harbor's registry storage, CNPG's backups. The AWS branch scopes to one bucket ARN, so without this the same claim would mean bucket-scoped on AWS and project-wide on GCP.

- [ ] **Step 1: Add `bucketRoles` to the XRD**

In `apis/gcpworkloadidentity/definition.yaml`, immediately after the `roles:` property block (which ends with its `pattern:` line, before `projectID:`), add:

```yaml
                bucketRoles:
                  type: array
                  description: >-
                    Google IAM roles granted on a SINGLE bucket rather than on the
                    project. Use this for anything storage-related: a project-level
                    roles/storage.* grant reaches every bucket in the project,
                    including OpenBao snapshots and CNPG backups, which is almost
                    never what a workload needs.
                    Optional and additive — omitting it leaves behaviour unchanged.
                  items:
                    type: object
                    properties:
                      bucket:
                        type: string
                        description: Bucket name, without a gs:// prefix.
                        pattern: '^[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]$'
                      role:
                        type: string
                        description: >-
                          Predefined or project-level custom role, same forms as
                          spec.roles.
                        pattern: '^(roles/[A-Za-z0-9_.]+|projects/([a-z][a-z0-9-]{4,28}[a-z0-9]|[0-9]{1,20})/roles/[A-Za-z0-9_.]+)$'
                    required:
                      - bucket
                      - role
```

`bucketRoles` is **not** added to the XRD's `required` list — the existing `required: [serviceAccount, roles]` stays exactly as it is, so every existing claim keeps validating.

- [ ] **Step 2: Write the failing tests**

Append to `apis/gcpworkloadidentity/kcl/main_test.k`:

```kcl
# ---- Test: bucketRoles render BucketIAMMember, not ProjectIAMMember ----
test_bucket_roles_are_bucket_scoped = lambda {
    bucketMembers = [r for r in items if r.kind == "BucketIAMMember"]
    assert len(bucketMembers) == 1, "expected 1 BucketIAMMember, got {}".format(len(bucketMembers))
    m = bucketMembers[0]
    assert m.spec.forProvider.bucket == "test-bucket", "expected bucket test-bucket, got {}".format(m.spec.forProvider.bucket)
    assert m.spec.forProvider.role == "roles/storage.objectAdmin", "expected roles/storage.objectAdmin, got {}".format(m.spec.forProvider.role)
}

# ---- Test: the bucket member binds the SAME principal as the project members ----
# A second construction of the principal:// string is exactly the drift this
# contract exists to prevent, so assert both kinds agree.
test_bucket_role_member_matches_project_member = lambda {
    bucketMembers = [r for r in items if r.kind == "BucketIAMMember"]
    projectMembers = [r for r in items if r.kind == "ProjectIAMMember"]
    assert bucketMembers[0].spec.forProvider.member == projectMembers[0].spec.forProvider.member, "bucket and project bindings must name the same principal"
}

# ---- Test: omitting bucketRoles changes nothing ----
test_bucket_roles_optional = lambda {
    projectMembers = [r for r in items if r.kind == "ProjectIAMMember"]
    assert len(projectMembers) >= 1, "project bindings must still render when bucketRoles is set"
}
```

- [ ] **Step 3: Add the test fixture input**

In `apis/gcpworkloadidentity/kcl/settings-example.yaml`, add `bucketRoles` to the `spec` block of the example XR:

```yaml
    bucketRoles:
      - bucket: test-bucket
        role: roles/storage.objectAdmin
```

- [ ] **Step 4: Run the tests to verify they fail**

```bash
cd /home/smana/Sources/crossplane-configuration/apis/gcpworkloadidentity/kcl
kcl test . -Y settings-example.yaml
```

Expected: FAIL on `test_bucket_roles_are_bucket_scoped` with `expected 1 BucketIAMMember, got 0`.

- [ ] **Step 5: Render the bucket members**

In `apis/gcpworkloadidentity/kcl/main.k`, find where `_items` is assembled from the ProjectIAMMember comprehension. Add the bucket members as a **separate single-expression list**, then concatenate once — never `+=` into an existing list under a conditional (constraint above; `apis/app/kcl/main.k:529-546` records what happens otherwise):

```kcl
# Bucket-scoped bindings. Rendered as BucketIAMMember so the grant
# reaches ONE bucket: a project-level roles/storage.* would reach every bucket
# in the project, including OpenBao's snapshots and CNPG's backups.
#
# `_member` is reused verbatim rather than rebuilt. That string needs the
# project NUMBER, not the ID, and a wrong one fails as an opaque permission
# error at request time rather than at apply time.
_bucketMembers = [
    {
        apiVersion = "storage.gcp.m.upbound.io/v1beta1"
        kind = "BucketIAMMember"
        metadata = _bindingMetadata(_slug(br.role) + "-" + br.bucket)
        spec = {
            forProvider = {
                bucket = br.bucket
                role = br.role
                member = _member
            }
            **_providerConfigAndPolicies
        }
    } for br in oxr.spec?.bucketRoles or []
]
```

Use the module's existing metadata helper and provider-config spread rather than inventing new ones — read the ProjectIAMMember block and mirror its exact names. If the module names them differently, use its names; the point is that both kinds are built the same way.

Then extend the single concatenation that produces `items` so it includes `_bucketMembers`.

- [ ] **Step 6: Run the tests to verify they pass**

```bash
cd /home/smana/Sources/crossplane-configuration/apis/gcpworkloadidentity/kcl
kcl fmt .
kcl test . -Y settings-example.yaml
```

Expected: PASS, all tests.

- [ ] **Step 7: Regenerate and check**

```bash
cd /home/smana/Sources/crossplane-configuration
task generate
task check
```

Expected: exit 0. `task check` includes generate-sync, which fails if `composition.yaml` is stale relative to `main.k`.

- [ ] **Step 8: Commit**

```bash
cd /home/smana/Sources/crossplane-configuration
git add apis/gcpworkloadidentity/
git commit -m "feat(gcp): bucket-scoped grants on GCPWorkloadIdentity

Adds an optional spec.bucketRoles that renders BucketIAMMember per
entry, so a workload can be granted a role on ONE bucket.

Without it the only way to grant storage access is spec.roles, which renders
ProjectIAMMember -- and roles/storage.objectAdmin at project level reaches
every bucket in the project, including OpenBao's snapshots and CNPG's backups.

The principal:// member string is reused from the existing construction rather
than rebuilt. It needs the project NUMBER, not the ID, and a wrong one fails as
an opaque permission error at request time."
```

---

### Task 2: The `objectStore` contract

**Files:**
- Modify: `apis/app/definition.yaml` (the `s3Bucket` block)
- Modify: `apis/sqlinstance/definition.yaml` (descriptions only)

**Interfaces:**
- Consumes: nothing.
- Produces: `spec.objectStore` with `enabled`, `permissions`, `versioning`, `retentionDays`, `aws{customPolicy, region}`, `gcp{location, storageClass}`. Task 4's KCL reads it; Task 6's claims set it.

- [ ] **Step 1: Replace the `s3Bucket` block**

In `apis/app/definition.yaml`, replace the whole `s3Bucket:` property block with:

```yaml
                objectStore:
                  type: object
                  description: >-
                    Object storage bucket, implemented per cloud: S3 on AWS, GCS
                    on GCP. The bucket's name and location are owned by the
                    platform — a claim states what it needs, not where it lands.
                  properties:
                    enabled:
                      type: boolean
                      description: Enable the bucket
                      default: false
                    permissions:
                      type: string
                      description: Access the workload receives on the bucket
                      enum: ["readwrite", "readonly", "custom"]
                      default: "readwrite"
                    versioning:
                      type: boolean
                      description: Keep non-current object versions
                      default: false
                    retentionDays:
                      type: integer
                      description: Object retention in days
                      minimum: 1
                    aws:
                      type: object
                      description: >-
                        AWS-only knobs, ignored on other clouds. Present because
                        these have no honest neutral form — not as a general
                        escape hatch.
                      properties:
                        customPolicy:
                          type: string
                          description: IAM policy JSON, used when permissions is custom
                        region:
                          type: string
                          description: >-
                            Overrides the cluster's own region. Rarely needed; the
                            EnvironmentConfig supplies it.
                          pattern: "^[a-z]+-[a-z]+-[0-9]+$"
                    gcp:
                      type: object
                      description: GCP-only knobs, ignored on other clouds.
                      properties:
                        location:
                          type: string
                          description: >-
                            Overrides the cluster's own region. Rarely needed; the
                            EnvironmentConfig supplies it.
                        storageClass:
                          type: string
                          enum: ["STANDARD", "NEARLINE", "COLDLINE", "ARCHIVE"]
                          default: "STANDARD"
```

Three fields are deliberately gone: top-level `region` (its `^[a-z]+-[a-z]+-[0-9]+$` pattern cannot match `europe-west4`, so it was never neutral), `providerConfigRef` (the composition knows its own), and top-level `customPolicy` (moved under `aws`, since IAM JSON has no neutral form).

- [ ] **Step 2: Correct the SQLInstance descriptions**

`apis/sqlinstance/definition.yaml` needs no schema change — `objectStoreRecovery` and `backup.bucketName` are already neutral names. Only their descriptions name S3. Replace every occurrence of `The name of the S3 bucket to store backups.` with `The name of the object-storage bucket holding backups.`, and `The path to the backup in the S3 bucket (Usualy a cluster name).` with `The path to the backup within the bucket (usually a cluster name).`

- [ ] **Step 3: Verify the XRD still parses**

```bash
cd /home/smana/Sources/crossplane-configuration
python3 scripts/xrd-to-crd.py apis/app/definition.yaml > /dev/null && echo "app XRD OK"
python3 scripts/xrd-to-crd.py apis/sqlinstance/definition.yaml > /dev/null && echo "sqlinstance XRD OK"
```

Expected: both print OK. `task check` will not pass yet — the KCL still reads `s3Bucket`, which Task 4 fixes.

- [ ] **Step 4: Commit**

```bash
cd /home/smana/Sources/crossplane-configuration
git add apis/app/definition.yaml apis/sqlinstance/definition.yaml
git commit -m "feat(api)!: spec.s3Bucket becomes spec.objectStore

The App contract ships in the cloud-NEUTRAL core package while naming an AWS
service, and the mismatch is not cosmetic: region carried the pattern
^[a-z]+-[a-z]+-[0-9]+\$, which matches eu-west-3 and cannot match europe-west4.
The neutral contract rejected a GCP claim at admission.

Location now comes from the EnvironmentConfig rather than the claim, so a claim
never states which cloud it lands on. Per-cloud knobs that have no honest
neutral form -- IAM policy JSON, GCS storage class -- are quarantined under
aws{} and gcp{} per ADR-0007.

BREAKING: spec.s3Bucket is removed. Both call sites are in cloud-native-ref and
migrate in the same change as the package pin.

SQLInstance needed no schema change; its field names were already neutral. Only
their descriptions said S3."
```

---

### Task 3: Build machinery for two Compositions per API

**Files:**
- Modify: `scripts/generate.py`
- Modify: `scripts/assemble.sh`
- Rename: `apis/app/composition.yaml` → `apis/app/composition-aws.yaml`

**Interfaces:**
- Consumes: nothing.
- Produces: `generate.py` inlines `main.k` into every `composition*.yaml` in an API dir; `assemble.sh` routes `composition-aws.yaml` to the aws package and `composition-gcp.yaml` to the gcp package. Task 4 adds `composition-gcp.yaml` and relies on both.

- [ ] **Step 1: Rename the AWS composition**

```bash
cd /home/smana/Sources/crossplane-configuration
git mv apis/app/composition.yaml apis/app/composition-aws.yaml
```

- [ ] **Step 2: Make `generate.py` handle multiple compositions**

`scripts/generate.py:82` globs `apis/*/composition.yaml` and locates `main.k` at `comp_path.parent / "kcl" / "main.k"`. Change the glob to cover both spellings:

```python
    for comp in sorted(ROOT.glob("apis/*/composition*.yaml")):
```

The `main.k` lookup already derives from `comp_path.parent`, so a directory with two compositions inlines the same module into both — which is the point: one source of truth, two manifests.

- [ ] **Step 3: Route each composition to its package**

In `scripts/assemble.sh`, the aws section currently copies `apis/$api/composition.yaml`. Change the AWS loop to copy `composition-aws.yaml`, and add the App composition to the GCP section:

```bash
# --- aws: the AWS contract, plus every AWS Composition ------------------------
cp apis/epi/definition.yaml build/aws/apis/epi-definition.yaml
for api in app sqlinstance inferenceservice; do
  cp "apis/$api/composition-aws.yaml" "build/aws/apis/$api-composition.yaml"
done
```

```bash
# --- gcp: the GCP contract and its Compositions -------------------------------
cp apis/gcpworkloadidentity/definition.yaml build/gcp/apis/gcpworkloadidentity-definition.yaml
cp apis/gcpworkloadidentity/composition.yaml build/gcp/apis/gcpworkloadidentity-composition.yaml
cp apis/app/composition-gcp.yaml build/gcp/apis/app-composition.yaml
cp apis/sqlinstance/composition-gcp.yaml build/gcp/apis/sqlinstance-composition.yaml
```

Read the existing loop before editing — it may list APIs differently. Preserve its API list; only the filename changes. `gcpworkloadidentity` keeps the singular `composition.yaml`: it is a GCP-only API with one implementation, and renaming it would be churn for symmetry's sake.

The two GCP lines reference files Tasks 4 and 5 create, so `assemble.sh` will fail until then. That is expected and is why Task 3's verification stops at `generate`.

- [ ] **Step 4: Verify generation is stable**

```bash
cd /home/smana/Sources/crossplane-configuration
task generate
git diff --stat -- apis/
```

Expected: `apis/app/composition-aws.yaml` shows no content change (the same `main.k` inlined into the renamed file). If it shows a diff, the inliner round-tripped differently — stop and read `generate.py:71`, which raises on exactly that.

- [ ] **Step 5: Commit**

```bash
cd /home/smana/Sources/crossplane-configuration
git add scripts/generate.py scripts/assemble.sh apis/app/
git commit -m "build: allow one API to ship a Composition per cloud

generate.py assumed one composition.yaml per API directory and assemble.sh
copied it unconditionally into the AWS package. Neither survives an API that
needs an AWS and a GCP implementation of the same contract.

generate.py now globs composition*.yaml and inlines the same main.k into each,
which is what keeps one KCL module as the single source of truth for both
clouds. assemble.sh routes by filename.

apis/app/composition.yaml is renamed to composition-aws.yaml; the GCP sibling
arrives with the KCL branch that needs it."
```

---

### Task 4: The cloud branch in `main.k`, and the GCP Composition

**Files:**
- Modify: `apis/app/kcl/main.k` (the `s3Bucket` block at ~1078–1192)
- Create: `apis/app/composition-gcp.yaml`
- Modify: `apis/app/kcl/main_test.k`
- Modify: `apis/app/kcl/settings-example.yaml`

**Interfaces:**
- Consumes: `spec.objectStore` (Task 2), `GCPWorkloadIdentity.spec.bucketRoles` (Task 1), the `composition*.yaml` routing (Task 3).
- Produces: an `App` that renders S3+EPI on `aws-0` and a GCS `Bucket`+GCPWorkloadIdentity on `gcp-0`.

- [ ] **Step 1: Write the failing tests**

Append to `apis/app/kcl/main_test.k`:

```kcl
# ---- Test: the AWS branch renders S3, not GCS ----
# DISCRIMINATE BY apiVersion, NOT BY kind. Both providers name the resource
# `Bucket` -- s3.aws.m.upbound.io/v1beta1 and storage.gcp.m.upbound.io/v1beta2 --
# so `r.kind == "Bucket"` matches BOTH clouds and this test would pass while
# rendering the wrong one.
test_objectstore_aws_branch = lambda {
    s3Buckets = [r for r in items if r.kind == "Bucket" and r.apiVersion.startswith("s3.aws")]
    gcsBuckets = [r for r in items if r.kind == "Bucket" and r.apiVersion.startswith("storage.gcp")]
    epis = [r for r in items if r.kind == "EPI"]
    assert len(s3Buckets) == 1, "expected 1 S3 Bucket, got {}".format(len(s3Buckets))
    assert len(gcsBuckets) == 0, "AWS branch must not render a GCS Bucket"
    assert len(epis) == 1, "expected 1 EPI, got {}".format(len(epis))
}

# ---- Test: the bucket location comes from the environment, not the claim ----
# The claim has no region field at all now; this asserts the composition
# actually falls back to the EnvironmentConfig rather than rendering an empty
# prefix, which would produce the bucket name "-ogenki-<app>".
test_objectstore_location_from_environment = lambda {
    bucket = [r for r in items if r.kind == "Bucket" and r.apiVersion.startswith("s3.aws")][0]
    _env = option("params").ctx["apiextensions.crossplane.io/environment"]
    _expected = _env.region + "-ogenki-" + option("params").oxr.metadata.name
    assert bucket.metadata.annotations["crossplane.io/external-name"] == _expected, "expected bucket {}, got {}".format(_expected, bucket.metadata.annotations["crossplane.io/external-name"])
}

# ---- Test: versioning off renders no versioning resource and no duplicates ----
# function-kcl #285: the pre-migration code emitted the Bucket and the EPI TWICE
# when versioning was off. Kept as a regression test across the rename.
test_objectstore_no_duplicates_versioning_off = lambda {
    names = [r.metadata.name for r in items]
    assert len(names) == len({n: None for n in names}), "duplicate composed-resource names: {}".format(names)
}
```

- [ ] **Step 2: Rename the claim field in the test fixture**

In `apis/app/kcl/settings-example.yaml`, rename the `s3Bucket:` key to `objectStore:` and delete its `region:` line. Do the same in `apis/app/kcl/settings-minimal.yaml` and `examples/app-complete.yaml` if they set it.

- [ ] **Step 3: Run the tests to verify they fail**

```bash
cd /home/smana/Sources/crossplane-configuration/apis/app/kcl
kcl test . -Y settings-example.yaml
```

Expected: FAIL — the module still reads `oxr.spec.s3Bucket`, which the fixture no longer sets, so no bucket renders at all.

- [ ] **Step 4: Branch the object-storage block**

Replace the `if oxr.spec.s3Bucket?.enabled:` block in `apis/app/kcl/main.k` (from the `if` through `_items += _s3BucketResources`). Keep the existing AWS bodies verbatim apart from the field rename and the location fallback — this is a rename plus a branch, not a rewrite:

```kcl
# Which cloud this cluster is. Read from an explicit key rather than inferred
# from which EnvironmentConfig fields happen to exist (accountId vs projectID):
# inference works today and breaks silently the first time either config gains
# a field.
_cloud = envConfig?.cloud or "aws"

if oxr.spec.objectStore?.enabled and _cloud == "aws":
    _bucketName = (oxr.spec.objectStore.aws?.region or envConfig.region) + "-ogenki-" + _name
    _bucketArn = "arn:aws:s3:::" + _bucketName
    # ... existing _s3Bucket, _s3BucketVersioning, _s3Epi bodies unchanged except:
    #   oxr.spec.s3Bucket.region            -> oxr.spec.objectStore.aws?.region or envConfig.region
    #   oxr.spec.s3Bucket.permissions       -> oxr.spec.objectStore.permissions
    #   oxr.spec.s3Bucket.customPolicy      -> oxr.spec.objectStore.aws?.customPolicy
    #   oxr.spec.s3Bucket.providerConfigRef -> removed; use "default"
    _items += _s3ResourceList(_s3Bucket, _s3BucketVersioning, _s3Epi, oxr.spec.objectStore.versioning or False)

if oxr.spec.objectStore?.enabled and _cloud == "gcp":
    # GCS bucket names are globally unique across ALL of GCP, not per-account
    # like S3. The project ID is itself globally unique, so prefixing with it
    # guarantees uniqueness while keeping the same <scope>-ogenki-<app> shape
    # the AWS branch uses with its region.
    _gcsName = envConfig.projectID + "-ogenki-" + _name

    _gcsBucket = [{
        apiVersion = "storage.gcp.m.upbound.io/v1beta2"
        kind = "Bucket"
        metadata = {
            name = _name + "-gcs-bucket"
            namespace = _namespace
            annotations = {
                "krm.kcl.dev/composition-resource-name" = _name + "-gcs-bucket"
                "crossplane.io/external-name" = _gcsName
            }
        }
        spec = {
            providerConfigRef = {
                name = "default"
                kind = "ClusterProviderConfig"
            }
            forProvider = {
                location = oxr.spec.objectStore.gcp?.location or envConfig.region
                storageClass = oxr.spec.objectStore.gcp?.storageClass or "STANDARD"
                # Unlike S3, versioning is a field on the bucket itself rather
                # than a separate resource -- so there is no second resource to
                # conditionally append, and no function-kcl #285 hazard here.
                versioning = [{enabled = oxr.spec.objectStore.versioning or False}]
                uniformBucketLevelAccess = True
                if oxr.spec.objectStore.retentionDays:
                    lifecycleRule = [{
                        action = [{type = "Delete"}]
                        condition = [{age = oxr.spec.objectStore.retentionDays}]
                    }]
            }
        }
    }]

    # Bucket-SCOPED, never project-scoped: see the bucketRoles rationale in
    # apis/gcpworkloadidentity/definition.yaml.
    _gcsIdentity = [{
        apiVersion = "cloud.ogenki.io/v1alpha1"
        kind = "GCPWorkloadIdentity"
        metadata = _managedMetadata("gcs-workload-identity")
        spec = {
            serviceAccount = {name = _name}
            roles = []
            bucketRoles = [{
                bucket = _gcsName
                role = "roles/storage.objectAdmin" if oxr.spec.objectStore.permissions == "readwrite" else "roles/storage.objectViewer"
            }]
        }
    }]

    _items += _gcsBucket + _gcsIdentity
```

Two notes for the implementer. `roles = []` may violate the `minItems: 1` on `GCPWorkloadIdentity.spec.roles` — check `apis/gcpworkloadidentity/definition.yaml`. If it does, relax `minItems` to 0 in Task 1's file and add a CEL rule requiring at least one of `roles` or `bucketRoles` to be non-empty, so an empty claim is still rejected. And `permissions: "custom"` has no GCP meaning — a custom IAM *policy* is AWS JSON. Treat `custom` on GCP as `readonly` and emit a comment saying so, rather than silently granting write.

- [ ] **Step 5: Create the GCP Composition manifest**

`apis/app/composition-gcp.yaml` — identical to `composition-aws.yaml` except for the metadata, the provider label and the EnvironmentConfig it selects. Copy the AWS file and change exactly these:

```yaml
metadata:
  name: xapps-gcp.cloud.ogenki.io      # was xapps.cloud.ogenki.io
  labels:
    provider: gcp                       # was aws
```

```yaml
        environmentConfigs:
        - type: Reference
          ref:
            name: gke-environment       # was eks-environment
```

Leave the `spec.source` block alone — `task generate` writes it.

- [ ] **Step 6: Run the tests, generate, and check**

```bash
cd /home/smana/Sources/crossplane-configuration/apis/app/kcl
kcl fmt .
kcl test . -Y settings-example.yaml
cd /home/smana/Sources/crossplane-configuration
task generate && task check
```

Expected: tests PASS, `task check` exit 0.

- [ ] **Step 7: Commit**

```bash
cd /home/smana/Sources/crossplane-configuration
git add apis/app/
git commit -m "feat(app): render GCS on gcp-0 and S3 on aws-0 from one claim

The App KCL is ~1291 lines of which ~69 were AWS-shaped, so the composition is
NOT duplicated per cloud: one main.k is inlined into composition-aws.yaml and
composition-gcp.yaml, each selecting its own EnvironmentConfig, and the module
branches on an explicit cloud key.

The cloud is read from envConfig.cloud rather than inferred from which fields
exist (accountId vs projectID). Inference works today and breaks silently the
first time either EnvironmentConfig gains a field.

The GCS grant is bucket-scoped via GCPWorkloadIdentity.bucketRoles. A
project-level roles/storage.objectAdmin would have reached every bucket in the
project while the AWS branch scoped to one ARN -- the same claim meaning two
very different things per cloud.

Bucket location comes from the EnvironmentConfig on both clouds. No claim
states a region, which also removes the last \${region} cross-cloud
substitution hazard from the App surface."
```

---

### Task 5: The `SQLInstance` stub Composition for GCP

**Files:**
- Create: `apis/sqlinstance/composition-gcp.yaml`
- Create: `apis/sqlinstance/kcl-gcp/main.k`
- Rename: `apis/sqlinstance/composition.yaml` → `apis/sqlinstance/composition-aws.yaml`

**Interfaces:**
- Consumes: the routing from Task 3.
- Produces: a `SQLInstance` on `gcp-0` that fails explicitly rather than hanging.

**Why a stub rather than a CEL rule.** The `App` XRD ships in the cloud-neutral `core` package and CEL validation runs at admission against the claim alone, with no access to the EnvironmentConfig. A rule rejecting `sqlInstance.enabled` would reject it on `aws-0` too, where it works.

- [ ] **Step 1: Rename the AWS composition**

```bash
cd /home/smana/Sources/crossplane-configuration
git mv apis/sqlinstance/composition.yaml apis/sqlinstance/composition-aws.yaml
```

- [ ] **Step 2: Write the stub module**

`generate.py` locates `main.k` at `<composition dir>/kcl/main.k`, which the AWS module already occupies. Rather than complicate the inliner further, give the stub its own directory and point the GCP manifest's `source` at it manually — the stub is nine lines and will be deleted by workstream 9.

`apis/sqlinstance/kcl-gcp/main.k`:

```kcl
# SQLInstance has no GCP implementation yet (workstream 9 brings CNPG with
# barman backups to GCS). This Composition exists so that an App claiming
# sqlInstance on gcp-0 FAILS with a reason, in the resource the developer asked
# for, instead of sitting Ready=Unknown forever with nothing naming the cause.
#
# Delete this file and its Composition when the real one lands.
items = []
```

- [ ] **Step 3: Write the GCP Composition manifest**

`apis/sqlinstance/composition-gcp.yaml`:

```yaml
# A deliberate dead-end. See apis/sqlinstance/kcl-gcp/main.k.
apiVersion: apiextensions.crossplane.io/v1
kind: Composition
metadata:
  name: xsqlinstances-gcp.cloud.ogenki.io
  labels:
    provider: gcp
spec:
  compositeTypeRef:
    apiVersion: cloud.ogenki.io/v1alpha1
    kind: SQLInstance
  mode: Pipeline
  pipeline:
    - step: not-implemented
      functionRef:
        name: function-kcl
      input:
        apiVersion: krm.kcl.dev/v1alpha1
        kind: KCLRun
        spec:
          target: Default
          source: |
            items = []
```

Composing zero resources leaves the XR without a Ready condition, which is the
hang this task exists to prevent. Verify in Task 7 how the XR actually reports;
if it does not surface a failure on its own, add a `function-auto-ready` step or
a status patch so the XR carries
`Ready=False, Reason=NotImplementedOnGCP` with the message from Step 2's
comment. **Do not leave it silent** — that is the whole point of the task.

- [ ] **Step 4: Exclude the stub directory from generate**

`generate.py` globs `apis/*/composition*.yaml` and looks for `kcl/main.k` beside it. `composition-gcp.yaml` has no `kcl/` sibling of its own — it shares the directory with the AWS one, so the inliner would overwrite its inline `source` with the AWS module. Add a skip:

```python
SKIP_INLINE = {"apis/sqlinstance/composition-gcp.yaml"}
```

and `continue` when `str(comp.relative_to(ROOT))` is in that set, with a comment saying the stub carries its own literal source and is deleted by workstream 9.

- [ ] **Step 5: Assemble and check**

```bash
cd /home/smana/Sources/crossplane-configuration
task generate && task check
bash scripts/assemble.sh && ls build/gcp/apis/
```

Expected: `task check` exit 0, and `build/gcp/apis/` contains `app-composition.yaml`, `sqlinstance-composition.yaml`, `gcpworkloadidentity-*`.

- [ ] **Step 6: Update the GCP package description and commit**

`packages/gcp/crossplane.yaml`'s description says the package holds only `GCPWorkloadIdentity`. Replace that paragraph:

```yaml
      GCP implementations of the ogenki platform APIs: the GCPWorkloadIdentity
      contract and Composition, the GCP App Composition (GCS buckets with
      bucket-scoped workload identity), and a placeholder SQLInstance
      Composition that fails explicitly until CNPG lands on GCP.
```

```bash
cd /home/smana/Sources/crossplane-configuration
git add apis/sqlinstance/ scripts/generate.py packages/gcp/crossplane.yaml
git commit -m "feat(gcp): SQLInstance fails loudly on GCP instead of hanging

An App with sqlInstance.enabled on gcp-0 renders a SQLInstance claim that no
Composition satisfies, so it would sit unsatisfied with nothing naming the
cause -- the silent never-Ready failure this platform keeps getting bitten by.

A CEL rule on the XRD cannot guard it: the XRD is one cluster-agnostic contract
in the core package, and admission cannot see the EnvironmentConfig, so the
rule would reject it on aws-0 too. A stub Composition fails in the resource the
developer actually asked for.

Deleted by workstream 9, which brings CNPG with barman backups to GCS."
```

---

### Task 6: Migrate `cloud-native-ref` and pin the release

**Files (in this worktree):**
- Modify: `infrastructure/base/crossplane/configuration/environmentconfig.yaml`
- Modify: `infrastructure/base/crossplane/configuration-gcp/environmentconfig.yaml`
- Modify: `infrastructure/base/crossplane/providers/activation-policy.yaml`
- Modify: `apps/base/complete/app.yaml`
- Modify: `apps/platform/app-wizard/ui-hints.yaml`
- Modify: `infrastructure/base/crossplane/configuration/configuration-packages.yaml`
- Modify: `infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml`
- Modify: `apps/platform/app-wizard/app.yaml` (the clone tag)

**Interfaces:**
- Consumes: the released packages from Tasks 1–5.
- Produces: a repo whose claims match the pinned schema.

- [ ] **Step 1: Cut the release in the compositions repo**

```bash
cd /home/smana/Sources/crossplane-configuration
task check          # must be exit 0 before tagging
git push origin HEAD
```

Open a PR, let CI publish, then tag per that repo's release process. Record the resulting version — every pin below uses it. **Do not invent a version number**; read it from the published package.

- [ ] **Step 2: Add the `cloud` key to both EnvironmentConfigs**

`infrastructure/base/crossplane/configuration/environmentconfig.yaml`, in `data:`:

```yaml
  # Which cloud this cluster runs on. Read by the App Composition to choose
  # between S3 and GCS. Explicit rather than inferred from which other keys
  # exist here -- inference works today and breaks the first time this file
  # gains a field.
  cloud: aws
```

`infrastructure/base/crossplane/configuration-gcp/environmentconfig.yaml`, same comment:

```yaml
  cloud: gcp
```

- [ ] **Step 3: Activate the new managed resource**

`infrastructure/base/crossplane/providers/activation-policy.yaml` gates which provider CRDs are installed. Without an entry the render fails with `no matches for kind "BucketIAMMember"`. Add both plural names to the GCP activation list, matching the file's existing style:

```yaml
    - buckets.storage.gcp.m.upbound.io
    - bucketiammembers.storage.gcp.m.upbound.io
```

Read the file first — if `buckets.storage.gcp.m.upbound.io` is already listed, add only the second.

- [ ] **Step 4: Migrate the two claims**

`apps/base/complete/app.yaml` — rename the block and drop the region:

```yaml
  # Object storage for user uploads
  objectStore:
    enabled: true
    permissions: readwrite
    versioning: true
    retentionDays: 90
```

The removed `region: ${region}` is the point of the change, not an oversight: on `gcp-0` that variable holds `europe-west4`, and it was being fed to an AWS-shaped field.

`apps/platform/app-wizard/ui-hints.yaml` — rename the `s3Bucket:` key to `objectStore:` and delete any region hint under it. Read the surrounding structure and keep its shape.

- [ ] **Step 5: Bump both pins and the wizard tag**

`infrastructure/base/crossplane/configuration/configuration-packages.yaml` and `.../configuration-gcp/configuration-packages.yaml`: set both `spec.package` tags to the version from Step 1.

`apps/platform/app-wizard/app.yaml`: the wizard clones the compositions repo at the pinned tag to render its form. Move that tag to the same version. A pin bump that leaves the tag behind renders the old schema in the UI while the cluster enforces the new one.

- [ ] **Step 6: Validate**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
```

Expected: `Invalid: 0, Skipped: 0`, both exit 0. The claims are validated against XRD schemas fetched from the pinned release, so a claim that still says `s3Bucket` fails here rather than on the cluster.

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat(crossplane)!: migrate claims to spec.objectStore

Renames the two call sites and bumps both Configuration package pins to the
release carrying the new contract. The claim edits and the pin bump land
TOGETHER on purpose: Configuration packages adopt existing XRDs, but a pin
whose XRD drops a field the live claims still set fails admission on those
claims.

apps/base/complete/app.yaml loses region: \${region}. That key holds an AWS
region on aws-0 and a GCP region on gcp-0, and it was being fed to an
AWS-shaped field -- the third instance of the cross-cloud substitution hazard
found on this branch.

Both EnvironmentConfigs gain an explicit cloud: key, and the activation policy
gains bucketiammembers without which the GCP render fails with 'no
matches for kind'."
```

---

### Task 7: Live verification on both clouds, then teardown

**Files:**
- Create: `docs/superpowers/specs/2026-08-25-objectstore-api-migration-verification.md`

**Interfaces:**
- Consumes: everything above.

**This task creates billable infrastructure and must tear it down.** Nothing is left running.

- [ ] **Step 1: Verify on `aws-0` first**

`aws-0` is the cluster with existing S3 buckets, so it is where a regression would do real damage. Deploy it, let Flux reconcile the new pin, and confirm an existing `App` claim still reconciles its bucket rather than replacing it:

```bash
kubectl get app -A
kubectl get bucket -A
kubectl get xapp -A -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}'
```

Expected: every `App` Ready=True, and the `Bucket` external-names unchanged from before the bump. A changed external name means delete-and-recreate of a live bucket — **stop immediately** and report.

- [ ] **Step 2: Verify criterion 1 — S3 works with no static credentials**

```bash
kubectl exec -n <ns> deploy/<app> -- sh -c 'echo hello > /tmp/t && aws s3 cp /tmp/t s3://$BUCKET/t && aws s3 ls s3://$BUCKET/'
kubectl get secrets -A -o json | jq -r '.items[] | select((.data // {}) | keys[] | test("aws.?access.?key";"i")) | .metadata.name'
```

Expected: the copy succeeds; the secret query returns nothing.

- [ ] **Step 3: Deploy `gcp-0` and verify criterion 2**

Deploy per `docs/gcp-bootstrap.md`, then apply the same claim, byte-identical apart from namespace:

```bash
kubectl get buckets.storage.gcp.m.upbound.io -A
kubectl get gcpworkloadidentity -A -o yaml | grep -A3 bucketRoles
gcloud storage buckets get-iam-policy gs://<bucket> --project ogenki-435905
```

Expected: the bucket exists; the IAM policy names the workload principal with `roles/storage.objectAdmin` **on that bucket**. Then confirm the negative half, which is the security claim:

```bash
gcloud projects get-iam-policy ogenki-435905 --flatten="bindings[].members" \
  --filter="bindings.role:roles/storage" --format="table(bindings.role,bindings.members)"
```

Expected: **no** project-level `roles/storage.*` binding for the app's principal. A project-level grant here means the bucket scoping silently did not take effect.

- [ ] **Step 4: Verify criterion 4 — `sqlInstance` fails loudly**

```bash
kubectl apply -f - <<'EOF'
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata: {name: sqlprobe, namespace: apps}
spec:
  image: {repository: nginx, tag: alpine}
  sqlInstance: {enabled: true, size: small, storageSize: 20Gi, instances: 1}
EOF
kubectl get sqlinstance -n apps sqlprobe -o jsonpath='{.status.conditions}'
```

Expected: a condition naming the gap within one reconcile — not `Ready=Unknown` indefinitely. If it hangs, Task 5 Step 3's open question resolved the wrong way; fix it there.

- [ ] **Step 5: Write the verification document**

Create `docs/superpowers/specs/2026-08-25-objectstore-api-migration-verification.md` with each of the spec's six success criteria, the command run, and its output pasted inline. Record honestly anything not exercised.

- [ ] **Step 6: Tear down and verify**

Follow the order established in workstream 12 — reclaim first, then destroy, then confirm against the API:

```bash
kubectl delete app --all -A          # releases buckets before the cluster goes
cd opentofu/gcp && TM_GCP_ENABLED=true TM_DESTROY_CONFIRMED=true terramate script run --reverse \
  --disable-check-git-remote --disable-check-git-untracked --disable-check-git-uncommitted destroy
```

```bash
gcloud container clusters list --project=ogenki-435905
gcloud storage buckets list --project=ogenki-435905
gcloud compute forwarding-rules list --project=ogenki-435905
aws eks list-clusters --region eu-west-3
aws s3 ls | grep ogenki
```

Expected: empty, except buckets that predate this work. **Read each listing** — `gcloud compute instances list` exits 0 with a warning when nothing matches, so its exit code is not evidence.

- [ ] **Step 7: Commit and open the PR**

```bash
git add docs/superpowers/specs/2026-08-25-objectstore-api-migration-verification.md
git commit -m "docs: objectStore migration verified on both clouds"
git push -u origin "$(git branch --show-current)"
gh pr create --title "feat(crossplane)!: cloud-neutral objectStore API" --body-file <(...)
```

The PR body links the design and the verification document, and states plainly that `spec.s3Bucket` is removed with no deprecation window.

---

## Self-review

**Spec coverage.** Contract → Task 2. Composition topology and the `cloud` key → Tasks 3, 4, 6. Bucket-scoped GCS grant → Tasks 1, 4. `sqlInstance` boundary → Task 5. Build changes → Tasks 3, 5. Migration and pins → Task 6. Testing → Tasks 1, 4 plus `task check` throughout. Success criteria 1–6 → Task 7. No section unimplemented.

**Known open items, deliberately carried rather than guessed:**

1. **Task 1 Step 5** tells the implementer to mirror the existing metadata helper and provider-config spread rather than naming them exactly. The names were not read during planning; mirroring the sibling block is more robust than a guessed identifier.
2. **Task 4 Step 4** flags that `roles = []` may violate `minItems: 1` and gives the fix if it does.
3. **Task 5 Step 3** flags that a zero-resource Composition may leave the XR without a Ready condition, and requires the implementer to verify and add an explicit failure if so. This is the one place the plan cannot settle from reading alone.

**Naming refinement against the spec.** The spec sketched the GCS bucket as `xplane-<name>-<projectID>`; this plan uses `<projectID>-ogenki-<name>`. Both satisfy the requirement (global uniqueness via the project ID), but the latter mirrors the AWS branch's existing `<region>-ogenki-<name>` shape, and the `xplane-` prefix belongs on IAM-bearing resources rather than on buckets — `main.k:30-38` says so explicitly.
