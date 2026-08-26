# Object-Storage Call Sites on GCP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Harbor, `openbao-snapshot` and CNPG backups name object storage their own cluster actually has, so the shared manifests work on `gcp-0` as well as `aws-0`.

**Architecture:** Bucket names become `${region}`-templated (already the convention in `apps/base/complete/app.yaml`). Harbor and `openbao-snapshot` split into cloud-neutral bases with `aws-0` / `gcp-0` overlays supplying the bucket, the identity and the storage-driver config. GCP identities are `GCPWorkloadIdentity` claims using `spec.bucketRoles`. The snapshot script gains a `CLOUD` switch and its image moves in-repo.

**Tech Stack:** Kustomize overlays, Flux `postBuild` substitution, Crossplane v2 (`storage.gcp.m.upbound.io`), `GCPWorkloadIdentity` (`crossplane-configuration-gcp` v0.3.1), Helm (harbor-helm), Bash, Docker.

**Spec:** [`docs/superpowers/specs/2026-08-26-gcp-object-storage-design.md`](../specs/2026-08-26-gcp-object-storage-design.md)
**ADR:** [`website/content/docs/decisions/0020-harbor-gcs-workload-identity.md`](../../../website/content/docs/decisions/0020-harbor-gcs-workload-identity.md)

## Global Constraints

- **`aws-0`'s rendered output must not change.** It is a live cluster. Verify with a bundle diff, not by inspection.
- **No new static credentials.** Every GCP call site uses Workload Identity. If a task seems to need a key, stop and raise it.
- **GCS grants are always `bucketRoles`, never `roles`.** A project-level `roles/storage.*` reaches OpenBao snapshots and CNPG backups.
- **`bucketRoles` item shape is `{bucket, role}` — `role` is SINGULAR.** Verified in the XRD at tag `v0.3.1`. `roles:` fails schema validation.
- **Never reconstruct the `principal://` string.** `projects/` takes the project NUMBER, `workloadIdentityPools/` takes the project ID; reversed, the API accepts the binding and it silently never matches. The composition builds it — pass `serviceAccount.name` and let it.
- **Bucket naming is `${region}-ogenki-<name>`.** No new convention.
- **`./scripts/validate-manifests.sh` is the gate**, and `Invalid: 0, Skipped: 0` is part of the claim.
- **Do not touch `Smana/crossplane-configuration`.** `v0.3.1` already provides everything.

---

### Task 1: CNPG bucket names become region-templated

**Files:**
- Modify: `security/base/zitadel/sqlinstance.yaml:46,50`
- Modify: `observability/base/grafana-oncall/sqlinstance.yaml:19`
- Modify: `tooling/base/harbor/sqlinstance.yaml:18,22`

**Interfaces:**
- Consumes: nothing.
- Produces: the `${region}-ogenki-cnpg-backups` spelling that later tasks assume.

- [ ] **Step 1: Confirm the current values and the existing precedent**

```bash
grep -rn 'bucketName' --include=*.yaml . --exclude-dir=.git --exclude-dir=.bundle
```

Expected: five `"eu-west-3-ogenki-cnpg-backups"` across the three files above, plus one **already-correct** `"${region}-ogenki-cnpg-backups"` at `apps/base/complete/app.yaml:333`. That last line is the precedent — match it exactly, including the quoting.

- [ ] **Step 2: Replace all five occurrences**

Each becomes:

```yaml
    bucketName: "${region}-ogenki-cnpg-backups"
```

Do **not** touch `objectStoreRecovery.path` in `security/base/zitadel/sqlinstance.yaml`. It is `zitadel-20260719`, a frozen snapshot prefix that exists in exactly one bucket on one cloud, and the surrounding comment block explains a migration that must stay accurate.

- [ ] **Step 3: Prove `aws-0` is unchanged**

`${region}` substitutes to `eu-west-3` on `aws-0`, so every one of these must render byte-identical.

```bash
./scripts/validate-manifests.sh
grep -rho 'bucketName: [a-z0-9"-]*' .bundle/ | sort | uniq -c
```

Expected: every rendered `bucketName` reads `eu-west-3-ogenki-cnpg-backups`; no occurrence of a literal `${region}`.

- [ ] **Step 4: Commit**

```bash
git add security/base/zitadel/sqlinstance.yaml observability/base/grafana-oncall/sqlinstance.yaml tooling/base/harbor/sqlinstance.yaml
git commit -m "feat(storage): template the CNPG backup bucket name by region"
```

---

### Task 2: Harbor splits into cloud-neutral base plus per-cloud overlays

**Files:**
- Modify: `tooling/base/harbor/kustomization.yaml`
- Modify: `tooling/base/harbor/helmrelease-harbor.yaml` (remove the storage + registry-credential blocks)
- Move: `tooling/base/harbor/s3-bucket.yaml` → `tooling/aws-0/harbor/s3-bucket.yaml`
- Move: `tooling/base/harbor/iam-user.yaml` → `tooling/aws-0/harbor/iam-user.yaml`
- Create: `tooling/aws-0/harbor/{kustomization.yaml,storage-s3.yaml}`
- Create: `tooling/gcp-0/harbor/{kustomization.yaml,gcs-bucket.yaml,workloadidentity.yaml,storage-gcs.yaml}`
- Create: `tooling/gcp-0/kustomization.yaml`
- Modify: `tooling/aws-0/kustomization.yaml` (`../base/harbor` → `./harbor`)

**Interfaces:**
- Consumes: Task 1's `sqlinstance.yaml` edit (same directory — rebase, don't revert it).
- Produces: the `tooling/gcp-0/` overlay root that Task 6 documents.

- [ ] **Step 1: Remove the AWS-specific blocks from the base HelmRelease**

Delete from `tooling/base/harbor/helmrelease-harbor.yaml` the whole `imageChartStorage:` block (currently `type: s3` with `s3.region` / `s3.bucket`) and the `registry.registry.extraEnvVars` list carrying `REGISTRY_STORAGE_S3_ACCESSKEY` / `REGISTRY_STORAGE_S3_SECRETKEY`. Leave `persistence.enabled: true` and `registry.serviceAccountName: harbor` in the base — both are cloud-neutral.

Replace them with a pointer comment so the split is discoverable:

```yaml
    persistence:
      enabled: true
      # imageChartStorage is supplied per cloud:
      #   tooling/aws-0/harbor/storage-s3.yaml   -- s3 driver + IAM user keys
      #   tooling/gcp-0/harbor/storage-gcs.yaml  -- gcs driver + Workload Identity
      # The drivers differ because goharbor#18686 blocks Pod Identity for the S3
      # driver on AWS but says nothing about GCP, where the chart's gcs driver
      # takes Workload Identity directly. See ADR-0020.
```

- [ ] **Step 2: Trim the base kustomization**

`tooling/base/harbor/kustomization.yaml` drops `iam-user.yaml` and `s3-bucket.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: tooling

resources:
  - externalsecret-admin-password.yaml
  - externalsecret-valkey-password.yaml
  - helmrelease-harbor.yaml
  - serviceaccount-harbor.yaml
  - httproute.yaml
  - kvstore.yaml
  - sqlinstance.yaml
```

- [ ] **Step 3: Create the `aws-0` overlay, preserving today's behaviour exactly**

```bash
mkdir -p tooling/aws-0/harbor
git mv tooling/base/harbor/s3-bucket.yaml tooling/aws-0/harbor/s3-bucket.yaml
git mv tooling/base/harbor/iam-user.yaml tooling/aws-0/harbor/iam-user.yaml
```

`tooling/aws-0/harbor/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: tooling

resources:
  - ../../base/harbor
  - s3-bucket.yaml
  - iam-user.yaml

patches:
  - path: storage-s3.yaml
    target:
      kind: HelmRelease
      name: harbor
```

`tooling/aws-0/harbor/storage-s3.yaml` restores verbatim what Step 1 removed:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: harbor
spec:
  values:
    persistence:
      imageChartStorage:
        # EKS Pod Identity does not reach the registry's S3 driver
        # (goharbor#18686), so this one workload keeps a static key. The EPI in
        # security/base/epis/harbor.yaml stays for Harbor's other AWS calls.
        type: s3
        s3:
          region: ${region}
          bucket: ${region}-ogenki-harbor
    registry:
      registry:
        extraEnvVars:
          - name: REGISTRY_STORAGE_S3_ACCESSKEY
            valueFrom:
              secretKeyRef:
                name: xplane-harbor-access-key
                key: username
          - name: REGISTRY_STORAGE_S3_SECRETKEY
            valueFrom:
              secretKeyRef:
                name: xplane-harbor-access-key
                key: password
```

- [ ] **Step 4: Point the `aws-0` tooling overlay at the new path**

In `tooling/aws-0/kustomization.yaml`, change `- ../base/harbor` to `- ./harbor`. Leave every other line, including the commented-out entries, untouched.

- [ ] **Step 5: Create the `gcp-0` overlay**

`tooling/gcp-0/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ./harbor
```

`tooling/gcp-0/harbor/gcs-bucket.yaml`:

```yaml
apiVersion: storage.gcp.m.upbound.io/v1beta1
kind: Bucket
metadata:
  name: harbor
  namespace: tooling
  annotations:
    crossplane.io/external-name: ${region}-ogenki-harbor
spec:
  forProvider:
    location: ${region}
    uniformBucketLevelAccess: true
    forceDestroy: false
```

`tooling/gcp-0/harbor/workloadidentity.yaml`:

```yaml
# Harbor's Google identity. Bucket-scoped, never project-scoped: a
# roles/storage.* grant at project level would also reach OpenBao's snapshot
# bucket and CNPG's backup bucket.
#
# No annotation on the ServiceAccount -- GKE Workload Identity binds by SUBJECT,
# and the composition builds the principal:// string. Do not rebuild it here:
# projects/ takes the project NUMBER while workloadIdentityPools/ takes the
# project ID, and reversing them yields a binding the API accepts and which
# silently never matches (see opentofu/gcp/gke/init/iam.tf).
apiVersion: cloud.ogenki.io/v1alpha1
kind: GCPWorkloadIdentity
metadata:
  name: xplane-harbor
  namespace: tooling
spec:
  serviceAccount:
    name: harbor
  bucketRoles:
    - bucket: ${region}-ogenki-harbor
      role: roles/storage.objectAdmin
```

`tooling/gcp-0/harbor/storage-gcs.yaml`:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: harbor
spec:
  values:
    persistence:
      imageChartStorage:
        # Native gcs driver with Workload Identity -- no key material. ADR-0020
        # records why this differs from the s3 driver used on aws-0.
        type: gcs
        gcs:
          bucket: ${region}-ogenki-harbor
          useWorkloadIdentity: true
```

`tooling/gcp-0/harbor/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: tooling

resources:
  - ../../base/harbor
  - gcs-bucket.yaml
  - workloadidentity.yaml

patches:
  - path: storage-gcs.yaml
    target:
      kind: HelmRelease
      name: harbor
```

- [ ] **Step 6: Prove `aws-0` renders byte-identical**

This is the step that matters. Capture the bundle before and after is not possible in one pass, so diff against `origin/main`:

```bash
./scripts/validate-manifests.sh
git stash list   # must be untouched; never stash in this repo
```

Then confirm the rendered Harbor HelmRelease still carries the S3 block and the two env vars:

```bash
grep -A8 'imageChartStorage' .bundle/*harbor* | head -30
grep -c 'REGISTRY_STORAGE_S3_ACCESSKEY' .bundle/*harbor*
```

Expected: `type: s3`, `bucket: eu-west-3-ogenki-harbor`, and exactly one `REGISTRY_STORAGE_S3_ACCESSKEY`. If the rendered AWS output differs in any way other than resource ordering, stop — the split is wrong.

- [ ] **Step 7: Commit**

```bash
git add -A tooling/
git commit -m "feat(gcp): Harbor storage splits per cloud -- s3 on aws-0, gcs on gcp-0"
```

---

### Task 3: The snapshot script learns a second cloud

**Files:**
- Modify: `scripts/openbao-snapshot.sh` (four `aws` call sites: lines ~116, ~183, ~197, ~204)

**Interfaces:**
- Consumes: nothing.
- Produces: the `CLOUD` contract (`aws` | `gcp`) that Tasks 4 and 5 set.

- [ ] **Step 1: Add the cloud switch near the top of the script**

After the existing variable defaults, before the first function:

```bash
# Which cloud's CLIs to use. Set by the CronJob; defaults to aws so an operator
# running this by hand against aws-0 needs no new environment.
CLOUD="${CLOUD:-aws}"
case "${CLOUD}" in
    aws|gcp) ;;
    *) echo "${err}: CLOUD must be 'aws' or 'gcp', got '${CLOUD}'." ; exit 1 ;;
esac
```

- [ ] **Step 2: Branch the recovery-keys lookup**

Replace the single `aws secretsmanager` line in `generate_root_token()`. The error message above it names AWS explicitly and must stop doing so:

```bash
    if [ -z "${RECOVERY_KEYS_SECRET_ID:-}" ]; then
        echo "${err}: RECOVERY_KEYS_SECRET_ID must be set to run a restore."
        echo "${err}: It names the secret holding the OpenBao recovery keys --"
        echo "${err}: an AWS Secrets Manager entry, or a GCP Secret Manager secret."
        exit 1
    fi

    if [ "${CLOUD}" = "gcp" ]; then
        RECOVERY_SECRET=$(gcloud secrets versions access latest --secret="${RECOVERY_KEYS_SECRET_ID}")
    else
        RECOVERY_SECRET=$(aws secretsmanager get-secret-value --secret-id "${RECOVERY_KEYS_SECRET_ID}" | jq -r '.SecretString')
    fi
```

Note the asymmetry: the AWS call returns a JSON envelope needing `jq -r '.SecretString'`; `gcloud secrets versions access` returns the payload directly. Both leave `RECOVERY_SECRET` holding the same JSON document, which the following `jq -r '.threshold // 1'` then reads.

- [ ] **Step 3: Branch the save**

```bash
    if [ "${CLOUD}" = "gcp" ]; then
        gcloud storage cp "${SNAPSHOT_FILE}" "gs://${BUCKET_NAME}/$(date -u +"%Y-%m-%dT%H%M%SZ").snap"
    else
        aws s3 cp "${SNAPSHOT_FILE}" "s3://${BUCKET_NAME}/$(date -u +"%Y-%m-%dT%H%M%SZ").snap"
    fi
```

Keep the existing comment about the colon-free sortable UTC format above it — it explains the filename and still applies to both clouds.

- [ ] **Step 4: Branch the restore lookup, and record why the two sorts differ**

```bash
    if [ "${CLOUD}" = "gcp" ]; then
        # Lexicographic is chronological here, and only here. The AWS bucket
        # still holds objects in the old "%Y-%m-%d_%H:%M:%S_%Z" format, where
        # '_' sorts after 'T' so every legacy key ranks above every new one --
        # hence the LastModified sort below. The GCP bucket was created after
        # the format change and has only ever held the sortable form.
        SNAP=$(gcloud storage ls "gs://${BUCKET_NAME}/" | sed 's#.*/##' | grep '\.snap$' | sort | tail -n1)
    else
        SNAP=$(aws s3api list-objects-v2 --bucket "${BUCKET_NAME}" \
            --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
    fi
```

Leave the existing `if [ -z "${SNAP}" ] || [ "${SNAP}" = "None" ]` guard as-is — `gcloud storage ls` yields an empty string on an empty bucket, which the first test already catches.

- [ ] **Step 5: Branch the restore download**

```bash
    if [ "${CLOUD}" = "gcp" ]; then
        gcloud storage cp "gs://${BUCKET_NAME}/${SNAP}" /tmp/bao.snap
    else
        aws s3 cp "s3://${BUCKET_NAME}/${SNAP}" /tmp/bao.snap
    fi
```

- [ ] **Step 6: Update the two user-facing strings that say S3**

`restore()` prints `Restoring OpenBao from S3...` and `Fetching latest backup from S3 bucket`. Make both cloud-neutral: `Restoring OpenBao from object storage...` and `Fetching latest backup from bucket ${BUCKET_NAME}`.

- [ ] **Step 7: Verify the script still parses and the AWS path is unchanged**

```bash
bash -n scripts/openbao-snapshot.sh && echo "syntax ok"
CLOUD=bogus bash scripts/openbao-snapshot.sh save 2>&1 | head -2
```

Expected: `syntax ok`, then the `CLOUD must be 'aws' or 'gcp'` error and exit 1. Also confirm `check_required_bin` — if it hardcodes a list of binaries, `gcloud` must be required only when `CLOUD=gcp`, and `aws` only when `CLOUD=aws`. Read that function before assuming.

- [ ] **Step 8: Commit**

```bash
git add scripts/openbao-snapshot.sh
git commit -m "feat(gcp): openbao-snapshot script branches on CLOUD for storage and secrets"
```

---

### Task 4: The snapshot image moves in-repo

**Files:**
- Create: `container-images/openbao-snapshot/{Dockerfile,build.sh,README.md}`
- Move: `scripts/openbao-snapshot.sh` → `container-images/openbao-snapshot/openbao-snapshot.sh`
- Create: `scripts/openbao-snapshot.sh` as a relative symlink to the moved file

**Interfaces:**
- Consumes: Task 3's script.
- Produces: `ghcr.io/smana/openbao-snapshot:<tag>`, which Task 5's CronJob references.

> **Corrected during execution — the original plan was wrong here.** It said to copy the script from
> `scripts/` and to "check how `pev2/build.sh` sets its context and follow it". Two facts checked
> afterwards make that impossible:
>
> 1. **CI's build context is the image directory, not the repo root.** The matrix builds it as
>    `"context": ("container-images/" + .)` in `.github/workflows/build-container-images.yml`. A
>    `COPY scripts/openbao-snapshot.sh` would work locally with a repo-root context and fail in CI,
>    because the file is outside the context.
> 2. **The workflow only triggers on `container-images/**`.** A change to `scripts/openbao-snapshot.sh`
>    would never rebuild the image. It would silently go stale — the same shape as the failure this
>    workflow already carries a scar for, where a green run published nothing.
>
> So the script's canonical home must be inside the image directory. But it is also a documented
> operator command — `website/content/docs/platform/security/openbao.md:218` runs
> `./scripts/openbao-snapshot.sh restore -a "${VAULT_ADDR}"`, and it is listed in
> `website/content/docs/reference/commands.md:111`. A relative symlink at the old path keeps that
> working, keeps one source of truth, and needs no CI change at all. Docker never sees the symlink:
> the real file is inside the build context; the symlink points inward from outside it.

- [ ] **Step 1: Read the precedent before writing anything**

```bash
cat container-images/pev2/Dockerfile container-images/pev2/build.sh container-images/README.md
```

Match its conventions — base image choice, label scheme, how `build.sh` derives a tag. Do not invent a different shape.

- [ ] **Step 2: Write the Dockerfile**

First move the script and leave a symlink behind:

```bash
git mv scripts/openbao-snapshot.sh container-images/openbao-snapshot/openbao-snapshot.sh
ln -s ../container-images/openbao-snapshot/openbao-snapshot.sh scripts/openbao-snapshot.sh
git add scripts/openbao-snapshot.sh
```

Verify the symlink resolves before going further — `bash scripts/openbao-snapshot.sh` must still print
its usage, and pre-commit's broken-symlink hook must pass.

The Dockerfile must provide `bao`, `jq`, `aws` and `gcloud`, and `COPY openbao-snapshot.sh` (a plain
relative path now that the file is in the context). Run as a non-root user with a read-only root
filesystem, per the platform constitution.

**The image builds for `linux/amd64` AND `linux/arm64`** — the workflow sets both. This is the part
most likely to bite: the AWS CLI v2 ships no musl build, so `pip install awscli` or an Alpine base
will fail or silently give you v1 on one architecture. Choose a base and an install method that
genuinely produce both architectures, and **state in your report which base you chose and why**. If
you cannot make both work, say so and stop rather than quietly building amd64 only — a
single-architecture image is exactly the kind of thing that passes here and fails on a node you did
not test.

- [ ] **Step 3: Write build.sh and README.md**

`README.md` states what the image is for, that it is consumed by `security/base/openbao-snapshot/snapshot-cronjob.yaml`, and that `CLOUD` selects the cloud.

- [ ] **Step 4: Build locally and verify both CLIs are present**

```bash
./container-images/openbao-snapshot/build.sh
docker run --rm --entrypoint sh <image>:<tag> -c 'aws --version; gcloud --version | head -1; bao version; jq --version'
```

All four must report a version.

- [ ] **Step 5: Commit**

```bash
git add container-images/openbao-snapshot
git commit -m "feat(gcp): build the openbao-snapshot image in-repo with both cloud CLIs"
```

---

### Task 5: The snapshot workload splits per cloud

**Files:**
- Modify: `security/base/openbao-snapshot/snapshot-cronjob.yaml` (image, `CLOUD` env)
- Modify: `security/base/openbao-snapshot/kustomization.yaml` if the bucket name is defined there
- Create: `security/gcp-0/openbao-snapshot/{kustomization.yaml,gcs-bucket.yaml,workloadidentity.yaml}`
- Modify: `security/gcp-0/kustomization.yaml`

**Interfaces:**
- Consumes: Task 3's `CLOUD` contract, Task 4's image reference.
- Produces: the `gcp-0` snapshot workload that Task 7 deploys and verifies.

- [ ] **Step 1: Point the base CronJob at the new image and default `CLOUD`**

Replace `image: smana/openbao-snapshot:v0.1.0` with the `ghcr.io/smana/openbao-snapshot` reference and the tag Task 4 published. Add to the container's `env`:

```yaml
                - name: CLOUD
                  value: "${cloud}"
```

If no `cloud` substitution variable exists in either cluster's ConfigMap, do **not** invent one here — instead set `value: "aws"` in the base and patch it to `"gcp"` from the `gcp-0` overlay. Check first:

```bash
grep -n 'cloud' opentofu/aws/eks/configure/kubernetes.tf opentofu/gcp/gke/configure/kubernetes.tf
```

- [ ] **Step 2: Confirm the image actually exists in the registry**

```bash
gh api /users/smana/packages/container/openbao-snapshot/versions --jq '.[].metadata.container.tags[]' | head
```

`.github/workflows/build-container-images.yml` once emptied its build matrix through a `changed-files` JSON-escaping bug and **still reported success**, which is how `ghcr.io/smana/app-wizard` went unpublished despite green runs. A green workflow is not evidence the image exists. If it is missing, fix the build before wiring the CronJob to it.

- [ ] **Step 3: Create the `gcp-0` overlay**

`security/gcp-0/openbao-snapshot/gcs-bucket.yaml` mirrors Task 2's bucket with `crossplane.io/external-name: ${region}-ogenki-openbao-snapshot`.

`security/gcp-0/openbao-snapshot/workloadidentity.yaml`:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: GCPWorkloadIdentity
metadata:
  name: xplane-openbao-snapshot
  namespace: security
spec:
  serviceAccount:
    name: openbao-snapshot
  bucketRoles:
    - bucket: ${region}-ogenki-openbao-snapshot
      role: roles/storage.objectAdmin
```

The AWS EPI also grants KMS usage. On GCP the bucket is encrypted with Google-managed keys by default, so no KMS grant is needed unless the bucket declares a CMEK — it does not. Say so in a comment rather than leaving the asymmetry unexplained.

`security/gcp-0/openbao-snapshot/kustomization.yaml` pulls `../../base/openbao-snapshot` plus the two new files, and patches `CLOUD` to `"gcp"` if Step 1 took that route.

- [ ] **Step 4: Wire it into `security/gcp-0/kustomization.yaml`**

Add `- ./openbao-snapshot` alongside the existing entries.

- [ ] **Step 5: Validate**

```bash
./scripts/validate-manifests.sh
python3 scripts/flux-schema/check-substitution.py
```

Both must exit 0, with `Invalid: 0, Skipped: 0`.

- [ ] **Step 6: Commit**

```bash
git add -A security/
git commit -m "feat(gcp): openbao-snapshot runs on gcp-0 with a bucket-scoped Google identity"
```

---

### Task 6: Documentation catches up, including the stale roadmap

**Files:**
- Modify: `docs/superpowers/specs/2026-08-18-gcp-support-design.md` (the workstream table)
- Modify: `website/content/docs/` pages describing Harbor storage or OpenBao snapshots, if any name S3 unconditionally

**Interfaces:**
- Consumes: everything above.
- Produces: nothing.

- [ ] **Step 1: Mark workstream 9, and fix the rows that are already wrong**

The Status column is stale: 11, 12 and 13 are done or in flight and show nothing. This is the live index workstreams 14 and 15 read.

```bash
sed -n '210,222p' docs/superpowers/specs/2026-08-18-gcp-support-design.md
git log --oneline origin/main | grep -iE 'workstream 1[123]|#18(2[5-9]|3[0-9]|41)' | head
```

Set 9 to this workstream's state, and give 11, 12 and 13 statuses that match what actually merged — verify each against `git log` rather than memory.

- [ ] **Step 2: Find any doc page that claims object storage is S3**

```bash
grep -rln 'S3\|s3://' website/content/docs/ | head
./scripts/validate-doc-claims.sh
```

Fix only pages whose claim is now false. A page describing `aws-0` specifically is still correct.

- [ ] **Step 3: Run every documentation gate**

```bash
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
./scripts/verify-doc-paths.sh
```

All three exit 0.

- [ ] **Step 4: Commit**

```bash
git add -A docs/ website/
git commit -m "docs(gcp): record workstream 9 and correct three stale roadmap statuses"
```

---

### Task 7: Deploy `gcp-0` and prove the snapshot path, then tear it down

**Files:** none — this task produces evidence.

**Interfaces:**
- Consumes: Tasks 1–6.
- Produces: `docs/superpowers/specs/2026-08-26-gcp-object-storage-verification.md`.

> **This task deploys billable infrastructure.** Nothing may be left running. The teardown step is not optional and is not "cleanup at the end" — it is part of the task.

- [ ] **Step 1: Deploy the GCP stack on this branch**

```bash
TM_GCP_ENABLED=true TF_VAR_flux_git_ref=refs/heads/worktree-gcp-object-storage \
  terramate -C opentofu/gcp/gke/init script run deploy
```

Then OpenBao, which workstream 11 already built:

```bash
TM_GCP_ENABLED=true terramate -C opentofu/gcp/openbao/cluster script run deploy
TM_GCP_ENABLED=true terramate -C opentofu/gcp/openbao/management script run deploy
```

- [ ] **Step 2: Wait for Flux and confirm the identity bound**

```bash
flux get kustomizations
kubectl get gcpworkloadidentity -A
kubectl get buckets.storage.gcp.m.upbound.io -A
```

`GCPWorkloadIdentity` must be `SYNCED=True READY=True`. A binding that renders but never matches is the documented `principal://` failure — if READY is true but the snapshot later gets a 403, that is the trap, and the fix is in the composition, not the claim.

- [ ] **Step 3: Trigger a snapshot and prove the object landed**

```bash
kubectl create job -n security --from=cronjob/openbao-snapshot snapshot-verify
kubectl logs -n security job/snapshot-verify
gcloud storage ls "gs://europe-west4-ogenki-openbao-snapshot/"
```

Expected: one `.snap` object with a current UTC timestamp. Record its exact name and size — that object is the evidence.

- [ ] **Step 4: Prove the restore path selects it**

Run the restore's selection logic without restoring:

```bash
kubectl exec -n security job/snapshot-verify -- sh -c \
  'gcloud storage ls "gs://${BUCKET_NAME}/" | sed "s#.*/##" | grep "\.snap$" | sort | tail -n1'
```

It must name the object from Step 3.

- [ ] **Step 5: Write the verification document**

`docs/superpowers/specs/2026-08-26-gcp-object-storage-verification.md`. State plainly which criteria were proven on live infrastructure and which were not. Harbor-on-GCS and CNPG-on-GCS have no `gcp-0` consumer and **cannot** be marked PASS — mark them `NOT CHECKABLE BY THE AVAILABLE METHOD` and say why. Paste real command output, not summaries.

- [ ] **Step 6: Destroy everything, and verify against the APIs**

```bash
TM_GCP_ENABLED=true TM_DESTROY_CONFIRMED=true terramate -C opentofu/gcp script run --reverse destroy
```

Then confirm against the provider, not against the tool's exit code:

```bash
gcloud container clusters list
gcloud compute instances list
gcloud compute forwarding-rules list
gcloud storage buckets list --filter='name~ogenki'
```

Clusters, instances and forwarding rules must be empty. Buckets holding real data are expected to survive — confirm which remain and that their contents are intact, the way the S3 buckets were checked in workstream 8.

- [ ] **Step 7: Commit the verification**

```bash
git add docs/superpowers/specs/2026-08-26-gcp-object-storage-verification.md
git commit -m "docs: verification for object-storage call sites on GCP"
```

---

### Task 8: The CNPG backups bucket leaves the shared base

> Added during execution. Task 1 templated the *consumer* (`bucketName` in five claims) but left the
> *producer* — the bucket itself — as an AWS-only managed resource inside a `base/` directory that is
> supposed to be cloud-neutral. Surfaced by Task 1's reviewer, which found the file while checking for
> a missed sixth occurrence.

**Files:**
- Move: `infrastructure/base/cloudnative-pg/s3-bucket.yaml` → `infrastructure/aws-0/cloudnative-pg/s3-bucket.yaml`
- Modify: `infrastructure/base/cloudnative-pg/kustomization.yaml` (drop `s3-bucket.yaml`)
- Create: `infrastructure/aws-0/cloudnative-pg/kustomization.yaml`
- Modify: `infrastructure/aws-0/kustomization.yaml` (`../base/cloudnative-pg` → `./cloudnative-pg`)

**Interfaces:**
- Consumes: Task 1's templated `bucketName`, and the overlay pattern Task 2 establishes for Harbor.
- Produces: a genuinely cloud-neutral `infrastructure/base/cloudnative-pg/`.

**Scope limit — do NOT create a GCS bucket in this task.** CloudNativePG is not deployed on `gcp-0`
at all: nothing references `infrastructure/base/cloudnative-pg` outside `infrastructure/aws-0/`. A
GCS bucket here would be an unused billable resource created for a consumer that does not exist. The
GCP bucket lands with the workstream that brings CNPG to `gcp-0`. This task only stops a shared base
from carrying a cloud-specific resource.

- [ ] **Step 1: Confirm the current wiring before moving anything**

```bash
grep -rn 'cloudnative-pg' --include=kustomization.yaml infrastructure/
head -12 infrastructure/base/cloudnative-pg/s3-bucket.yaml
```

Expected: only `infrastructure/aws-0/kustomization.yaml` references it, and the file is an
`s3.aws.m.upbound.io/v1beta1` Bucket. If anything under `gcp-0` references it, STOP — that is a live
bug, not a latent one, and it changes this task.

- [ ] **Step 2: Move the file, preserving its comment block**

```bash
mkdir -p infrastructure/aws-0/cloudnative-pg
git mv infrastructure/base/cloudnative-pg/s3-bucket.yaml infrastructure/aws-0/cloudnative-pg/s3-bucket.yaml
```

The file opens with a comment explaining why `managementPolicies` omits `Delete` — postgres backups
outlive any individual cluster, and a delete attempt hangs the namespace teardown on a finalizer.
That comment must travel with the file unchanged.

- [ ] **Step 3: Drop it from the base kustomization, and create the overlay**

`infrastructure/aws-0/cloudnative-pg/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - ../../base/cloudnative-pg
  - s3-bucket.yaml
```

Then change `- ../base/cloudnative-pg` to `- ./cloudnative-pg` in `infrastructure/aws-0/kustomization.yaml`.
Leave the adjacent `../base/cloudnative-pg-barman-plugin` line alone — the plugin is cloud-neutral.

- [ ] **Step 4: Add a pointer comment in the base kustomization**

So the next reader knows where the bucket went and why:

```yaml
# The cnpg-backups bucket is NOT here: it is a cloud-specific managed resource
# and lives in the per-cloud overlay (infrastructure/aws-0/cloudnative-pg/).
# CloudNativePG is not deployed on gcp-0 yet; its GCS bucket lands with the
# workstream that brings it there.
```

- [ ] **Step 5: Prove `aws-0` still renders the bucket**

```bash
./scripts/validate-manifests.sh
grep -rn 'kind: Bucket' .bundle/ | grep -c cnpg
```

Expected: `Invalid: 0, Skipped: 0`, and the `cnpg-backups` Bucket still present exactly once in the
rendered bundle. A move that silently drops it from `aws-0` is the failure mode here.

- [ ] **Step 6: Commit**

```bash
git add -A infrastructure/
git commit -m "refactor(storage): move the CNPG backups bucket out of the shared base"
```

---

### Task 9: Harbor's buckets get the same delete protection every other stateful bucket has

> Added during execution, from Task 2's review. Neither Harbor bucket sets `managementPolicies`,
> while `infrastructure/base/cloudnative-pg/s3-bucket.yaml`, `security/base/openbao-snapshot/s3-bucket.yaml`
> and `apps/base/ai/llm/s3-bucket.yaml` all set `["Observe", "Create", "Update", "LateInitialize"]`.
> This is pre-existing on the AWS side, not a regression from Task 2 — the byte-identical constraint
> is exactly why the implementer was right not to add it unilaterally.

**Files:**
- Modify: `tooling/aws-0/harbor/s3-bucket.yaml`
- Modify: `tooling/gcp-0/harbor/gcs-bucket.yaml`

**Interfaces:**
- Consumes: Task 2's overlay layout.
- Produces: nothing.

**This task deliberately changes `aws-0`'s rendered output, overriding this plan's first Global
Constraint.** The reasoning, which belongs in the commit message:

- That constraint exists to catch *accidental behavioural regressions* on a live cluster, not to
  forbid a deliberate safety fix to a file this workstream is already restructuring.
- `managementPolicies` without `Delete` does not change what the bucket is or how anything reads it.
  It changes only what Crossplane attempts on prune. It cannot lose data; it prevents an attempt.
- This repo has already been bitten by the omission. The comment atop the CNPG bucket records it:
  Crossplane keeps retrying `s3:DeleteBucket`, AWS denies it (the platform grants no deletion
  permission for stateful services), and the managed resource's finalizer hangs the parent
  namespace's teardown.
- Harbor's registry bucket holds image layers, which are among the most expensive data in the
  platform to reconstruct.

- [ ] **Step 1: Read one of the three existing examples first**

```bash
sed -n '1,20p' infrastructure/base/cloudnative-pg/s3-bucket.yaml
```

Match its shape and the spirit of its comment. Do not invent a different field order or a different
policy list.

- [ ] **Step 2: Add the policy to the AWS bucket**

In `tooling/aws-0/harbor/s3-bucket.yaml`, above `forProvider:`:

```yaml
  # Registry image layers are expensive to reconstruct and outlive any single
  # cluster, so Crossplane must never attempt to remove the bucket. Without
  # this it retries s3:DeleteBucket on prune, AWS denies it (no deletion
  # permission for stateful services), and the MR finalizer hangs the
  # namespace teardown. To remove intentionally, use the aws CLI.
  # (Crossplane v2 namespaced MRs do not expose spec.deletionPolicy;
  # managementPolicies is the v2 mechanism.)
  managementPolicies: ["Observe", "Create", "Update", "LateInitialize"]
```

- [ ] **Step 3: Add the equivalent to the GCS bucket**

Same list in `tooling/gcp-0/harbor/gcs-bucket.yaml`. Its comment should note that `forceDestroy: false`
already refuses to delete a non-empty bucket, so the realistic failure this prevents on GCP is the
same finalizer wedge rather than data loss.

- [ ] **Step 4: Validate, and state the aws-0 delta plainly**

```bash
./scripts/validate-manifests.sh
grep -rn -A3 'kind: Bucket' .bundle/overlay-tooling-aws-0.yaml | grep -i managementpolicies
```

`Invalid: 0, Skipped: 0`. The rendered `aws-0` Bucket now carries `managementPolicies` — that is the
intended, and only, `aws-0` change in this task. Confirm nothing else moved.

- [ ] **Step 5: Commit**

```bash
git add tooling/aws-0/harbor/s3-bucket.yaml tooling/gcp-0/harbor/gcs-bucket.yaml
git commit -m "fix(storage): stop Crossplane attempting to delete Harbor's buckets"
```
