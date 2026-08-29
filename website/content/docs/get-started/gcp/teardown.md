---
title: Teardown
weight: 30
description: Tear the GCP platform down safely, in reverse dependency order.
lastVerified: 2026-08-27
---

Same shape as the [AWS teardown](../aws/teardown.md), with GCP's own traps. Two
of them cost a manual cleanup on the 2026-08-27 gcp-0 teardown and are now
handled by the destroy workflow itself.

{{< callout type="warning" >}}
`TM_CLOUD` defaults to `aws`, and it gates the **destroy** jobs exactly as it
gates deploy: without `TM_CLOUD=gcp` each one prints `[skip]` and exits 0. A
teardown that appears to succeed instantly did nothing at all — check for
`[skip]` lines before believing the cluster is gone.
{{< /callout >}}

## GKE only

```bash
cd opentofu/gcp/gke/init
TM_CLOUD=gcp terramate script run destroy
```

Six jobs, defined in `opentofu/gcp/gke/init/workflows.tm.hcl`:

1. **confirm + init** — `scripts/terramate-destroy-confirm.sh`, then `tofu init`.
   Init runs *before* anything is destroyed on purpose: a lock file predating a
   new provider must fail here, not once resources have started disappearing.
2. **`stage2-reclaim-volumes`** — reclaims CSI-provisioned PD disks while the
   cluster still exists (see below).
3. **`stage2-destroy-addons`** — destroys the `gke/configure` stack (Gateway API
   CRDs, Cilium, Flux). Never gates the cluster deletion.
4. **`stage1-destroy-cluster`** — destroys the cluster itself. This one *is*
   allowed to fail loudly: it is the billable resource.
5. **`stage2-sweep-orphaned-disks`** — the backstop for whatever step 2 could not
   reclaim in time, and it runs *after* the cluster is gone precisely so nothing
   is still attached ([why](#orphaned-persistent-disks)).
6. **`stage2-reconcile-state`** — drops any stage-2 state left behind, now that
   the cluster holding those objects is provably gone.

## Full teardown

```bash
cd opentofu
TM_CLOUD=gcp terramate script run --reverse destroy
```

Destroys every stack — GKE, OpenBao, Network — in reverse dependency order, with
a single confirmation cached for 10 minutes.

## The two leaks this workflow now prevents

### Orphaned Persistent Disks

Deleting the cluster with PVCs still bound skips the reclaim entirely: the PD
CSI controller dies with the cluster, and every PVC-backed disk is orphaned in
the project with nothing left referencing it. Nothing reports this — `tofu
destroy` says "Destroy complete" and the disks keep billing. Three survived the
2026-08-27 teardown (20/10/5 GB), the GCP replay of an EBS leak EKS already had
a step for.

`stage2-reclaim-volumes` calls `scripts/k8s-reclaim-csi-volumes.sh`, shared with
the AWS teardown because every step of it is plain Kubernetes — what it does,
step by step, is on the
[AWS teardown]({{< relref "/docs/get-started/aws/teardown.md#what-eks-prepare-destroysh-does-first" >}}).

**It is not sufficient on its own, and used to claim otherwise.** The reclaim can
only run while the cluster exists, and when it runs out of time it warns and
exits 0 — it used to say a "cloud-side sweep" would catch the rest, and no such
step existed. The leak therefore repeated: 3 disks on 2026-08-27, **8 disks /
43 GB** on 2026-08-28, on a cluster with more stateful workloads (two CNPG
databases, VictoriaMetrics, VictoriaLogs, runlore, Harbor).

`stage2-sweep-orphaned-disks` is that backstop, made real. It runs **after** the
cluster is deleted — before then, a disk still attached to a draining node is not
yet unattached and would be skipped — and removes only disks that are both
unattached **and** carry the GKE CSI driver's own marker in their description:

```
"storage.gke.io/created-by": "pd.csi.storage.gke.io"
```

so a hand-made disk is never touched. It logs each deletion with the PVC it came
from, and never fails the teardown.

Run it by hand against any project at any time:

```bash
./scripts/gcp-sweep-orphaned-disks.sh --project <project>          # dry run
./scripts/gcp-sweep-orphaned-disks.sh --project <project> --apply
```

{{< callout type="warning" >}}
**AWS has the same leak and no equivalent step.** `eks-prepare-destroy.sh` shares
the same in-cluster reclaim and the same failure mode, and 62 EBS volumes
(~518 GB) were swept by hand after a 2026-07-21 rebuild. Nothing sweeps them
automatically yet.
{{< /callout >}}

{{< callout type="warning" >}}
**This step deletes PVC data unconditionally**, regardless of the reclaim policy
a PV was created with. There is no flag that skips it. Back up anything you need
*before* running the destroy.
{{< /callout >}}

It never gates the teardown. The control-plane endpoint is private, so the usual
reason to be running destroy at all is that the cluster or the tailnet is
unreachable — the script says so and exits 0. Disks it misses stay in the
project; list them with:

```bash
gcloud compute disks list --project <project> \
  --filter="-users:*" --format="table(name,sizeGb,zone)"
```

### `containerNotEmpty` on the Cloud DNS zone

external-dns writes a record into the private zone for every HTTPRoute, and
nothing removes them when the cluster goes — the controller that owned them went
with it. Cloud DNS then refuses to delete a non-empty zone:

```
Error 400: The container is not empty., containerNotEmpty
```

which lands at the *end* of the network destroy, after the rest of the VPC is
already gone, leaving the stack half torn down. On 2026-08-27 that meant deleting
twelve records by hand.

The network stack's destroy now runs `scripts/gcp-purge-dns-records.sh` first,
reading the zone name from state rather than re-deriving it. Apex NS and SOA are
left alone: Cloud DNS will not delete them separately and removes them with the
zone. Safe to re-run — it exits 0 when the zone is already gone or already empty.

## What is not deleted

Secrets in Secret Manager outlive the cluster, by design — they are what a
rebuild reads back. See [ADR-0023](../../decisions/0023-portable-secret-store-names.md).
List and remove them by hand once you are certain:

```bash
gcloud secrets list --project <project> --format='value(name)'
```

The three hand-created bootstrap prerequisites — the state bucket, the Cloud KMS
key ring, and the Tailscale OAuth client — are also left alone. Cloud KMS key
rings cannot be deleted at all.

### Everything Crossplane created

`tofu destroy` does not remove these, and it cannot: Crossplane is *in* the
cluster, so it dies with it. Anything it provisioned in GCP is simply orphaned.
On the 2026-08-28 gcp-0 teardown that was **3 Buckets, 7 BucketIAMMembers and 5
ProjectIAMMembers**.

The buckets survive on purpose rather than by oversight — their
`managementPolicies` are `[Observe, Create, Update, LateInitialize]` with **no
`Delete`**, which is the constitution's "no deletion permissions for stateful
services" applied to object storage. Deleting the claim does not delete the
bucket; nothing does, except a human.

```bash
gcloud storage buckets list --project <project> --format='value(name)'
```

The IAM members cost nothing and reference principals that no longer exist, so
they are noise rather than a leak. The buckets bill.

{{< callout type="warning" >}}
**Keep `<project>-ogenki-cnpg-backups`.** It holds the dated restore seed —
`zitadel-<date>/` — that `security/gcp-0/zitadel` bootstraps the next cluster's
ZITADEL from. Delete it and the rebuild starts with an EMPTY identity provider,
losing what no script can recreate: the Google IdP's user links, and any human
user, which exists only after a first interactive login. It is ~100 MB.
{{< /callout >}}

The other two are a judgement call. `<project>-ogenki-llm-models` held 18.1 GB of
model weights after one preload — keeping it makes a later LLM run skip the
HuggingFace download entirely; deleting it saves a few tens of cents a month.
`<project>-ogenki-harbor` is empty unless images were pushed.

## Verifying nothing is left

Teardown is not finished because a script said so. Check the project:

```bash
gcloud container clusters list --project <project>
gcloud compute instances list --project <project>
gcloud compute disks list --project <project>
gcloud compute addresses list --project <project>
gcloud dns managed-zones list --project <project>
gcloud compute networks list --project <project>   # only `default` should remain

# Expected to REMAIN, not to be empty: the Crossplane-created buckets and the
# bootstrap prerequisites. Confirm the list matches what you meant to keep --
# in particular that <project>-ogenki-cnpg-backups is still there.
gcloud storage buckets list --project <project> --format='value(name)'
```

## Non-interactive

`TM_DESTROY_CONFIRMED=true` skips the interactive `y/n` prompt. It exists for
CI; skip it on a first manual teardown so you get the confirmation.
