# Verification — object-storage call sites on GCP (workstream 9)

**Date:** 2026-08-26
**Design:** [2026-08-26-gcp-object-storage-design.md](2026-08-26-gcp-object-storage-design.md)
**Plan:** [2026-08-26-gcp-object-storage.md](../plans/2026-08-26-gcp-object-storage.md)
**Branch:** `worktree-gcp-object-storage`
**Cluster:** `gcp-0`, project `ogenki-435905`, `europe-west4-a` — deployed, verified, destroyed.

## Summary

**3 of 6 criteria pass outright. One is blocked by a property of gcp-0's OpenBao that this
workstream cannot change, and two are not checkable because their consumers do not exist on GCP.**

The deploy found two blockers that every gate in this repository passed over. One was a design error
in this workstream; the other is an architectural property of workstream 11. Both are recorded below
with the command output that established them.

| # | Criterion | Result |
|---|---|---|
| 1 | Bucket names render per cloud and `aws-0` is byte-identical | **PASS** |
| 2 | The GCP snapshot identity is bucket-scoped, never project-scoped | **PASS** |
| 3 | The snapshot job's ExternalSecret syncs on `gcp-0` | **PASS** |
| 4 | A snapshot lands in GCS and the restore logic selects it | **BLOCKED** — no raft endpoint on `gcp-0` |
| 5 | Harbor stores images in GCS | **NOT CHECKABLE** — Harbor is not deployed on `gcp-0` |
| 6 | CNPG backs up to GCS | **NOT CHECKABLE** — CloudNativePG is not deployed on `gcp-0` |

---

## Criterion 4 — BLOCKED, and this is the workstream's headline result

`openbao-snapshot.sh save` runs `bao operator raft snapshot save`, which requires OpenBao's
integrated (raft) storage. `gcp-0`'s OpenBao does not have it:

```
$ bao operator raft snapshot save /tmp/gcp-test.snap
Error taking the snapshot: Error making API request.

URL: GET https://bao.priv.gcp.ogenki.io:8200/v1/sys/storage/raft/snapshot
Code: 404
```

This is deliberate, and predates this workstream. `opentofu/gcp/openbao/cluster/compute.tf`:

> Single-node OpenBao compute: instance template + a one-instance MIG. This mirrors the AWS stack's
> "dev" mode, not "ha" — one node, `storage "file"`, no raft join, no quorum. This stack is a
> demo/test posture torn down and rebuilt on every platform test cycle; scaling to a real multi-node
> raft cluster is future work, not attempted here.

The snapshot job was ported from `aws-0`, where OpenBao runs raft in HA mode. `sys/storage/raft/*`
does not exist on a file-backed OpenBao — which is also the exact path the new GCP snapshot policy
grants.

**Everything built for this criterion is correct and none of it is wasted.** Criteria 2 and 3 below
verify the AppRole, the Secret Manager entry, the bucket, the identity and the ExternalSecret on live
infrastructure. Only the endpoint is absent.

**Disposition:** `clusters/gcp-0/security/security-openbao-snapshot.yaml` is `suspend: true`, with the
404 and the unblocking condition recorded in the file. Left active it would run daily, fail, and read
as backup coverage to anyone not reading logs. Resuming needs raft storage on `gcp-0` — workstream
11 — and a one-line change here.

---

## Criterion 1 — PASS

Bucket names are per-cloud, and `aws-0` renders unchanged.

```
$ ./scripts/validate-manifests.sh
Summary: 1823 resources found in 242 files - Valid: 1823, Invalid: 0, Skipped: 0
==> All gates passed
```

`aws-0`'s rendered CNPG bucket name is `eu-west-3-ogenki-cnpg-backups` before and after templating,
and no literal `${...}` survives into the bundle.

### The design error this criterion nearly shipped

The design asserted that the existing `${region}-ogenki-<name>` convention "ports cleanly" to GCP.
That was checked against GCS bucket-name *legality* and nothing else. It is legal, and it does not
work:

```
Error 403: Caller does not have storage.buckets.create access to the Google Cloud project.
Permission 'storage.buckets.create' denied on resource
'//storage.googleapis.com/projects/_/buckets/europe-west4-ogenki-openbao-snapshot'
```

`opentofu/gcp/gke/init/iam.tf` conditions the Crossplane principal's storage role on

```
resource.name.startsWith('projects/_/buckets/${var.project_id}-ogenki-')
```

so a region-prefixed bucket falls outside the grant.

**The error is actively misleading and worth remembering.** The custom role *does* carry
`storage.buckets.create` — so the 403 names a permission that was granted, and points nowhere near
the IAM *condition* that actually rejected it. Reading the role tells you it should work.

Fixed at all six sites, including the `BUCKET_NAME` the OpenBao secret carries: a mismatch between
the real bucket and the name in the secret fails at runtime, not at validation. After the fix:

```
$ kubectl get buckets.storage.gcp.m.upbound.io -A
NAMESPACE   NAME               SYNCED   READY   EXTERNAL-NAME
security    openbao-snapshot   True     True    ogenki-435905-ogenki-openbao-snapshot

$ gcloud storage buckets list --format='value(name)'
ogenki-435905-ogenki-openbao-snapshot
ogenki-435905-tfstate
```

The project prefix is also the better convention: GCS names are globally unique, so two projects in
one region would collide under a region prefix.

---

## Criterion 2 — PASS

The GCP snapshot identity grants `storage.objectAdmin` on **one bucket**, never on the project. The
composed `BucketIAMMember`'s external name is the whole claim in one string:

```
$ kubectl get bucketiammember.storage.gcp.m.upbound.io -n security
NAME                                                        SYNCED  READY  EXTERNAL-NAME
xplane-openbao-snapshot-storage-objectadmin-ogenki-435905-…  True    True   b/ogenki-435905-ogenki-openbao-snapshot/roles/storage.objectAdmin/principal://iam.googleapis.com/projects/323586397743/locations/global/workloadIdentityPools/ogenki-435905.svc.id.goog/subject/ns/security/sa/openbao-snapshot
```

Three things are verified at once by that value:

- **`b/<bucket>/roles/storage.objectAdmin`** — bucket-scoped. A project-level `roles/storage.*` would
  have reached OpenBao's snapshots *and* CNPG's backups; the `GCPWorkloadIdentity` XRD's own field
  description names those two as the reason `bucketRoles` exists.
- **`projects/323586397743` with `workloadIdentityPools/ogenki-435905.svc.id.goog`** — project
  **number** in the first position, project **ID** in the second. `opentofu/gcp/gke/init/iam.tf`
  documents that reversing them yields a binding the API accepts and which silently never matches.
  The composition builds this string; no manifest in this repo reconstructs it.
- **`subject/ns/security/sa/openbao-snapshot`** — bound to the job's ServiceAccount, by subject. No
  annotation on the ServiceAccount, and no Google service account in between.

The claim requests `bucketRoles` only and no `roles:`. The CronJob runs `save`, which needs bucket
write and nothing else; `RECOVERY_KEYS_SECRET_ID` is read only by `restore`, an operator action.

---

## Criterion 3 — PASS

This is the criterion a pre-deploy review predicted would fail, and the reason Tasks 13 and 14 exist.
The base ExternalSecret pulls a GCP Secret Manager entry that did not exist, from an AppRole that did
not exist, with no IAM binding — `opentofu/gcp/openbao/management/auth.tf` recorded that gap in its
own header. The Pod would have failed with `CreateContainerConfigError`.

```
$ kubectl get externalsecret -n security
NAME                       STORE                REFRESH   STATUS         READY
cert-manager-bao-approle   clustersecretstore   1h        SecretSynced   True
openbao-ca                 clustersecretstore   1h        SecretSynced   True
openbao-snapshot           clustersecretstore   1h        SecretSynced   True

$ flux get kustomizations | grep openbao-snapshot
security-openbao-snapshot   latest@sha256:be73644e   False   True   Applied revision: …
```

Supporting evidence on the OpenTofu side:

```
$ gcloud secrets list --filter='name~openbao-priv-gcp'
openbao-priv-gcp-approle-cert-manager
openbao-priv-gcp-ca-chain
openbao-priv-gcp-intermediate-ca
openbao-priv-gcp-recovery-keys
openbao-priv-gcp-root-token
openbao-priv-gcp-server-cert
openbao-priv-gcp-snapshot          <- Task 14

$ bao list auth/approle/role
cert-manager
snapshot-agent                     <- Task 13
```

`openbao-priv-gcp-snapshot` is the dash-separated name from Task 14. The original path-style
`security/openbao/openbao-snapshot`, copied from AWS, would have failed at apply — GCP Secret Manager
IDs cannot contain `/`, and `tofu validate` does not catch it.

---

## Criteria 5 and 6 — NOT CHECKABLE BY THE AVAILABLE METHOD

Harbor and CloudNativePG are not deployed on `gcp-0`, so neither GCS path can be exercised. Verifying
Harbor would need `SQLInstance` and `KVStore` on GCP, which is a separate workstream.

What *is* verified for them: their manifests render with the GCS driver and the corrected bucket
names, `aws-0`'s rendered output is unchanged, and Harbor's GCP path declares
`useWorkloadIdentity: true` with no key material anywhere in the rendered chart — no `GCS_KEY_DATA`,
no `encodedkey`, no `existingSecret`, no `GOOGLE_APPLICATION_CREDENTIALS`.

That the `gcs` driver authenticates through Workload Identity at runtime remains an assumption, as
the design stated. It is not claimed as tested.

---

## Two questions the deploy answered that no gate could

### `gcloud storage ls` on an existing-but-empty bucket

Task 3's restore branch was written without knowing this, deliberately, and the code turns out to be
correct as written:

```
$ gcloud storage ls "gs://ogenki-435905-ogenki-openbao-snapshot/"
EXIT CODE: 0          (no output)
```

Zero exit with empty output. So the two-step guard is right: `if ! LISTING=$(gcloud storage ls …)`
catches a genuine listing failure, and the existing `-z "${SNAP}"` guard catches an empty bucket. Had
this been guessed the other way, a healthy new bucket would have been reported as a listing failure
during a restore.

### Where the snapshot pod's traffic appears to come from

Predicted from configuration before the cluster existed, then measured:

```
$ kubectl -n kube-system exec ds/cilium -c cilium-agent -- cilium-dbg status
Routing:       Network: Native   Host: Legacy
Masquerading:  IPTables [IPv4: Enabled, IPv6: Disabled]
KubeProxyReplacement: True [eth0 10.10.0.5 …]
IPAM:          IPv4: 6/254 allocated from 100.65.1.0/24

$ kubectl -n kube-system get cm cilium-config -o jsonpath='{.data.ipv4-native-routing-cidr}'
100.65.0.0/16
```

Native routing with the native-routing CIDR set to the **pod** CIDR, masquerading on. OpenBao's
internal load balancer is at `10.10.0.9`, in the **node** CIDR `10.10.0.0/16` — outside the
native-routing CIDR — so pod egress to it is masqueraded to the node IP.

**Consequence:** `token_bound_cidrs` for the GCP snapshot AppRole should be the node CIDR
`10.10.0.0/16`, the same value `openbao_cidr` already carries. A security review flagged its absence
as a defence-in-depth gap versus AWS; it was deliberately deferred rather than guessed, because a
wrong CIDR does not degrade — it breaks AppRole login outright. A follow-up can now set it from this
measurement.

Incidentally, `10.10.0.0/16` is not AWS's `10.0.0.0/16`: Task 12's CIDR templating was not
theoretical. The hardcoded AWS value would have denied this exact path.

---

## Follow-ups this verification generates

1. **Raft storage for `gcp-0`'s OpenBao** (workstream 11). Unblocks criterion 4 and the suspended
   Kustomization, with no change needed in this repo.
2. **`token_bound_cidrs = 10.10.0.0/16`** on the GCP snapshot AppRole, now evidence-backed.
3. **A stale `BucketIAMMember` survives a bucket rename.** After renaming the bucket, the composed
   binding for the old name remained, reconciling forever against a 404. It was destroyed with the
   cluster, but it is a `crossplane-configuration` behaviour worth confirming.
4. **The IAM-condition trap is worth documenting** wherever GCS buckets get created: a 403 naming a
   permission the role holds means the *condition* rejected the resource name.

## Teardown

Recorded in the section below after destruction, verified against the GCP APIs rather than the
tool's exit code.
