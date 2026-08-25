# `objectStore` API migration — workstream 8

**Status:** design approved 2026-08-25, not yet implemented.

Migrates the `App` composition's developer-facing `spec.s3Bucket` to a cloud-neutral
`spec.objectStore`, and ships a GCP `App` Composition so the neutral contract has an
implementation on both clouds.

Gates workstream 9 (Harbor GCS, `openbao-snapshot` GCS + Cloud KMS, CNPG barman GCS) and
workstream 14 (GPU/LLM). Implements the developer-facing half of
[ADR-0007](../../../website/content/docs/decisions/0007-cloud-abstraction-boundaries.md):
*cloud-shaped platform APIs, neutral developer APIs*.

## The problem

`spec.s3Bucket` is an AWS-shaped field in a **cloud-neutral contract package**. The
compositions repo splits deliberately: `packages/core` ships the neutral XRDs (`App`,
`SQLInstance`, `KVStore`, `InferenceService`), while `packages/aws` and `packages/gcp` ship the
Compositions that implement them. `App`'s contract names an AWS service in its own field name.

It is not merely a naming problem. The field cannot express GCP:

```yaml
# apis/app/definition.yaml — the "neutral" contract
region:
  type: string
  description: AWS region
  pattern: "^[a-z]+-[a-z]+-[0-9]+$"
```

That pattern matches `eu-west-3`. It cannot match `europe-west4` — two segments, with a digit
inside what the pattern requires to be `[a-z]+`. A GCP claim is rejected at admission by the
contract that is supposed to be cloud-neutral.

There is a second, quieter problem in this repo. `apps/base/complete/app.yaml` fills that field
with `${region}`, and on `gcp-0` that variable holds `europe-west4`. This is the same
cross-cloud substitution trap that reached review twice during workstream 12 — a key with one
name and two shapes, where CI renders one cloud and the cluster runs the other. Removing
`region` from the claim surface removes a third instance of it before anyone writes a GCP claim.

## Decisions

| Decision | Outcome |
|---|---|
| Scope | Contract **and** both implementations — an `objectStore` claim works on `aws-0` and `gcp-0` |
| KCL sharing | One `main.k`, cloud pinned per Composition (approach A below) |
| Location | Read from the EnvironmentConfig, **not** stated in the claim |
| `sqlInstance` on GCP | A stub Composition fails it explicitly with a reason; CNPG-on-GCP is workstream 9 |
| GCS grant scope | `GCPWorkloadIdentity` gains optional `bucketRoles`, rendering `StorageBucketIAMMember` — project-scoped storage admin is not acceptable |

## The contract

`apis/app/definition.yaml`, in `packages/core`:

```yaml
objectStore:
  type: object
  description: Object storage bucket, implemented per cloud (S3 on AWS, GCS on GCP)
  properties:
    enabled: { type: boolean, default: false }
    permissions:
      type: string
      enum: ["readwrite", "readonly", "custom"]
      default: "readwrite"
    versioning: { type: boolean, default: false }
    retentionDays: { type: integer, minimum: 1 }
    aws:
      type: object
      description: AWS-only knobs. Ignored on other clouds.
      properties:
        customPolicy:
          type: string
          description: IAM policy JSON, when permissions is custom
        region:
          type: string
          description: Overrides the cluster's region. Rarely needed.
          pattern: "^[a-z]+-[a-z]+-[0-9]+$"
    gcp:
      type: object
      description: GCP-only knobs. Ignored on other clouds.
      properties:
        location:
          type: string
          description: Overrides the cluster's region. Rarely needed.
        storageClass:
          type: string
          enum: ["STANDARD", "NEARLINE", "COLDLINE", "ARCHIVE"]
          default: "STANDARD"
```

Three deliberate removals from the old `s3Bucket`:

- **Top-level `region`.** Its regex was AWS-only, so the field was never neutral. Location now
  comes from the EnvironmentConfig the platform already populates on both clouds. A claim
  should not have to know which cloud it lands on — that is the whole point of a neutral API.
  Per-cloud overrides survive inside the escape hatches for the rare case, where an AWS-shaped
  regex is honest because it sits under `aws:`.
- **`providerConfigRef`.** The Composition knows its own provider config; a claim naming it is a
  chance to name the wrong one.
- **`customPolicy`** moves under `aws:`. IAM policy JSON has no neutral form — the same
  reasoning ADR-0007 used to keep `EPI` and `GCPWorkloadIdentity` as sibling XRDs rather than
  forcing a single abstraction over `spec.policyDocument`.

`enabled`, `permissions`, `versioning` and `retentionDays` are genuinely neutral: every one has
a faithful meaning on both clouds.

### Why escape hatches rather than a lowest common denominator

`gcp.storageClass` has no AWS equivalent worth abstracting, and `aws.customPolicy` has no GCP
one. Forcing them into neutral names would produce fields that mean different things per cloud —
which is precisely the `${region}` failure, moved up a layer. ADR-0007 anticipates this:
quarantine the provider knobs, keep the shared surface honest.

## Composition topology

The `App` KCL module is 1291 lines, of which roughly 69 mention S3, IAM, ARNs or `EPI`. About
**95% is cloud-neutral** — `Deployment`, `Service`, `HTTPRoute`, `HorizontalPodAutoscaler`,
`PodDisruptionBudget`, `PersistentVolumeClaim`, `CiliumNetworkPolicy`, `ExternalSecret`,
`VMServiceScrape`, `VMRule`, `CronJob`, plus the `KVStore` and `SQLInstance` sub-claims.

**Approach A: one `main.k`, cloud pinned per Composition.**

`apis/app/kcl/main.k` stays a single file and gains branching for the 5% that differs.
`apis/app/composition-aws.yaml` and `apis/app/composition-gcp.yaml` both inline that same
source; each selects its own EnvironmentConfig.

No `compositionSelector` labels and no cloud field on the claim are needed, because **each
cluster only ever has one of them**: `aws-0` installs `crossplane-configuration-aws` and `gcp-0`
installs `crossplane-configuration-gcp`. The package split already carries the selection.

Rejected alternatives:

- **Split KCL files concatenated at generate time** — physically separates the cloud code, but
  invents build machinery, and `kcl fmt` / `kcl test` would then operate on fragments of a file
  that never exists on disk. The golden-fixture render tests get harder to reason about for a
  gain that 69 lines does not justify.
- **Duplicate `main.k` per cloud** — 1291 lines copied to vary 69. Every future `App` feature
  would be written twice and the two would drift. Not seriously considered.

### How the KCL learns its cloud

Both EnvironmentConfigs gain one key:

```yaml
# infrastructure/base/crossplane/configuration/environmentconfig.yaml      (eks-environment)
cloud: aws
# infrastructure/base/crossplane/configuration-gcp/environmentconfig.yaml  (gke-environment)
cloud: gcp
```

The KCL reads it from the environment context rather than inferring the cloud from which keys
happen to be present (`accountId` vs `projectID`). Inference would work today and break the
first time either EnvironmentConfig gains a field — an explicit key states the fact once.

### What branches

| Concern | AWS branch | GCP branch |
|---|---|---|
| Bucket | `Bucket` + `BucketVersioning` (`s3.aws.m.upbound.io`) | `StorageBucket` (`storage.gcp.m.upbound.io`), versioning inline |
| Identity | `EPI` | `GCPWorkloadIdentity` |
| Grant | IAM policy JSON, scoped to the bucket ARN | `roles/storage.objectAdmin` via `StorageBucketIAMMember`, scoped to the bucket — see below |
| Location | `eks-environment.region` | `gke-environment.region` |
| Naming | `xplane-<name>` | `xplane-<name>` (unchanged — the prefix is load-bearing for IAM scoping on both) |

### `GCPWorkloadIdentity` must gain bucket scope

**Found while writing the implementation plan, and it changes that contract.**
`GCPWorkloadIdentity` renders `ProjectIAMMember` and nothing else — its own module header says
so. Granting `roles/storage.objectAdmin` through it would give the app's ServiceAccount admin
over **every bucket in the project**: OpenBao's snapshots, Harbor's registry storage, and CNPG's
backups once workstream 9 lands.

The AWS branch scopes its IAM policy to one bucket ARN. Shipping the project-scoped GCP branch
would make the same claim mean *bucket-scoped* on AWS and *project-wide storage admin* on GCP —
an asymmetry that renders cleanly, passes every test, and is a real privilege escalation.

So `GCPWorkloadIdentity` gains an optional bucket-scoped binding that renders
`StorageBucketIAMMember` rather than `ProjectIAMMember`:

```yaml
spec:
  serviceAccount:
    name: my-app
  roles:                      # unchanged — still project-level
    - roles/monitoring.viewer
  bucketRoles:                # new, optional
    - bucket: xplane-my-app-ogenki-435905
      role: roles/storage.objectAdmin
```

The `principal://` member string — which needs the project **NUMBER**, not the ID, and fails as
an opaque permission error when confused — stays constructed in exactly one place. The
alternative, having the `App` composition emit `StorageBucketIAMMember` itself, would duplicate
that construction into a second place where it can drift.

Consequences the plan must carry: `bucketRoles` is additive and optional, so existing
`GCPWorkloadIdentity` claims are unaffected; `storagebucketiammembers` must be added to the
`ManagedResourceActivationPolicy` in this repo, or the CRD is never installed and the render
fails with `no matches for kind`; and the resource-name slugging must cover bucket names as
well as role names.

GCS bucket names are globally unique across all of GCP, unlike S3 names which are unique per
partition. The GCP branch therefore suffixes the project ID: `xplane-<name>-<projectID>`. This
is a real difference the neutral contract cannot hide, and it is why `objectStore` exposes no
`bucketName` field — the platform owns the name on both clouds.

## The `sqlInstance` boundary

`App` with `sqlInstance.enabled: true` renders a `SQLInstance` claim. `packages/gcp` will not
ship a `SQLInstance` Composition in this workstream, so on `gcp-0` that claim would sit
unsatisfied and the `App` would never reach Ready — with nothing in its status naming the cause.

This platform has been bitten repeatedly by exactly that shape of failure: a healthy-looking
resource that silently does nothing.

**A CEL rule on the XRD cannot fix this**, and it is worth saying why, because it is the
obvious first idea. The XRD is one cluster-agnostic contract shipped in `packages/core`; CEL
validation runs at admission against the claim alone, with no access to the EnvironmentConfig
and therefore no knowledge of which cloud the cluster is. A rule that rejected
`sqlInstance.enabled` would reject it on `aws-0` too, where it works.

**Decision: `packages/gcp` ships a stub `SQLInstance` Composition** whose only job is to set an
explicit failure condition:

```
Ready=False
Reason=NotImplementedOnGCP
Message=SQLInstance has no GCP implementation yet (workstream 9). Use an external
        database, or deploy this App on aws-0.
```

It fails in the resource the user actually asked for, carries its reason in that resource's own
status, and disappears cleanly when workstream 9 replaces it with a real Composition. The
alternative — the `App` Composition refusing to render the sub-claim — hides the reason one
level up, in a resource whose status is already busy with a dozen other things.

`SQLInstance`'s own contract needs no rename: its fields are already neutral
(`objectStoreRecovery`, `backup.bucketName`). Only their **descriptions** say "S3 bucket", which
this workstream corrects. The AWS-bound part is the CNPG barman plumbing inside its KCL, and
that is workstream 9's subject.

## Build changes

`scripts/generate.py` inlines `apis/<api>/kcl/main.k` into `apis/<api>/composition.yaml` as a
literal block scalar, locating `main.k` from the composition's parent directory. It assumes one
Composition per API. It must glob `composition*.yaml` instead, inlining the same `main.k` into
each match.

`scripts/assemble.sh` currently copies `apis/<api>/composition.yaml` into the AWS package. It
must route `composition-aws.yaml` → `build/aws/apis/` and `composition-gcp.yaml` →
`build/gcp/apis/`.

`packages/gcp/crossplane.yaml` gains nothing structurally — it already depends on
`crossplane-configuration-core` for the contracts and declares its own functions explicitly.
Its description needs updating: it will no longer be only `GCPWorkloadIdentity`.

## Migration in `cloud-native-ref`

Two call sites, both ours:

- `apps/base/complete/app.yaml` — rename the block, drop `region: ${region}`
- `apps/platform/app-wizard/ui-hints.yaml` — rename, and drop the region hint

Then bump both pins in `infrastructure/base/crossplane/configuration/configuration-packages.yaml`
and `infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml`, and move the
App Wizard's clone tag with them — the wizard clones the compositions repo at the pinned tag, so
a pin bump that does not move the tag renders the old schema in the UI.

**This is a breaking change with no deprecation window.** Both call sites are in this repo and
no external consumer exists, so a compatibility shim accepting both spellings would be
machinery serving nobody. The XRD rename is delete-and-recreate for the field, not for the XR,
so existing `App` claims keep their identity; an S3 bucket already created keeps being
reconciled as long as the claim is updated in the same commit as the pin bump.

> **Ordering constraint for the plan.** Crossplane Configuration packages *adopt* existing XRDs,
> but Flux prune still deletes them — the two-PR cutover recorded during the crossplane
> extraction. A pin bump whose XRD drops a field the live claims still set will fail admission
> on those claims. The plan must land the claim edits and the pin bump together, and verify
> against a live `aws-0` before `gcp-0`.

## Testing

- `main_test.k` asserts **both** branches: resource counts per cloud, `xplane-*` naming, the
  GCS project-ID suffix, security contexts, and that `objectStore.enabled: false` renders
  neither bucket kind.
- Golden fixtures gain a GCP render of the complete example, so `task check`'s render-equivalence
  step covers the new Composition.
- `task check` in the compositions repo is the gate there (generate-sync, `kcl fmt`, `kcl test`,
  XRD schema, render equivalence).
- `./scripts/validate-manifests.sh` is the gate here — the claims are validated against the XRD
  schemas fetched from the pinned release, so a pin bump whose schema no longer matches a claim
  fails locally rather than on the cluster.

## Success criteria

1. An `App` claim with `objectStore.enabled: true` on `aws-0` creates an S3 bucket and an `EPI`,
   and the pod reads and writes it with no static credentials.
2. The same claim, byte-identical apart from cluster, does the same on `gcp-0` with a GCS bucket
   and a `GCPWorkloadIdentity`.
3. No claim anywhere states a region or a cloud.
4. `App` with `sqlInstance.enabled: true` on `gcp-0` fails with a message naming the gap, within
   one reconcile — not by hanging.
5. `task check` and `./scripts/validate-manifests.sh` both pass, the latter with
   `Invalid: 0, Skipped: 0`.
6. Both clusters torn down afterwards, verified against the cloud APIs rather than exit codes.

## Out of scope

- CNPG on GCP (barman to GCS) — workstream 9.
- Harbor's GCS driver and `openbao-snapshot` — workstream 9.
- Storage classes (`gp3` → `pd-balanced`) — workstream 13.
- Any change to `EPI` or `GCPWorkloadIdentity`, which stay sibling cloud-shaped APIs per
  ADR-0007.
