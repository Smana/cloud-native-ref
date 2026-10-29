---
title: Unbound PersistentVolumeClaims
weight: 20
description: Which PersistentVolumeClaims are not Bound — a read-only report script, the Storage dashboard, and what a Pending claim usually means on GKE and EKS.
lastVerified: 2026-10-28
---

A PersistentVolumeClaim that never binds does not fail loudly. The workload
that mounts it stays unschedulable — or its StatefulSet stays half-up — while
everything around it keeps reporting green: the claim is not an error state
the API server flags, it is a `Pending` phase that can sit there for days.

This page covers the two views of that signal: the one-shot report from a
laptop, and the standing Grafana view.

## The report: `scripts/ops/k8s/pvc-unbound.sh`

`scripts/ops/k8s/pvc-unbound.sh` prints one line per claim whose phase is not
`Bound`, oldest first:

```console
$ scripts/ops/k8s/pvc-unbound.sh
db-team/data-warehouse Pending standard-rwo 500Gi 400d
apps/checkout-cache Lost premium-rwo 50Gi 3d
apps/scratch Pending fast-rwo 1Gi 2m
```

The line is `<namespace>/<name> <phase> <storageClass> <requested size>
<age>`, where the age is `kubectl`'s own shorthand. `Lost` is reported
alongside `Pending` — a `Lost` claim is one whose volume is gone, and it is
at least as interesting as one that never bound.

It is **a report, not a gate**:

- it exits `0` whatever the count, so it never breaks whatever runs it;
- it reads only (`kubectl get`), changes nothing;
- if the cluster is unreachable it still exits `0`, with a warning on stderr
  and whatever it could list on stdout.

`scripts/ci/tests/test-pvc-unbound.sh` runs the script against a canned
`kubectl get pvc -A -o json` fixture, covering the Pending, Lost, and Bound
cases, the ordering, and the unreachable-cluster path.

## The panel: the Storage dashboard

The **Storage** dashboard (`observability/base/grafana-operator/dashboards/`)
carries two panels on the same signal:

- **Claims not Bound** — a table of every claim whose phase is not `Bound`,
  one row per claim, from
  `kube_persistentvolumeclaim_status_phase{phase!="Bound"}`;
- **Requested capacity by storage class** — the total bytes claims have
  asked for, split by `storageclass`, from
  `kube_persistentvolumeclaim_resource_requests_storage_bytes`.

Both come from kube-state-metrics, which the platform already runs, so there
is nothing to enable. The dashboard is provisioned by the grafana-operator
like every other dashboard in the repository, into the `kubernetes` folder.

### How to read it

- **An empty table** — every claim on the cluster is Bound. The capacity
  panel is still worth a glance: it is the standing demand on the storage
  classes, whether or not anything is stuck.
- **A row that appears and disappears** — a claim in flight, or a transient
  provisioning failure the CSI driver retried. Wait for it to settle.
- **A row that stays** — a claim that is genuinely stuck. Run the script
  above to see how long it has been Pending, then read on.

## What a Pending claim usually means

The phase is `Pending` because no PersistentVolume satisfied the claim, and
the reasons why cluster by cloud.

On **GKE**, the two common ones:

- **No default storage class, or the wrong one.** A claim with no
  `storageClassName` binds against the cluster's default — which is
  `standard-rwo` on new clusters, but is not guaranteed to exist on one that
  predates the feature. The claim then waits forever on a class that is not
  there.
- **PD capacity or quota.** Compute Engine persistent disks are regional
  quota; a claim for a size or type the project has no quota for stays
  `Pending` until the quota moves. The place to look is the
  `persistentvolumeclaim-controller` events on the claim itself
  (`kubectl describe pvc -n <ns> <name>`), which say
  `googleapi: Error 403: quota exceeded`.

On **EKS**, the two common ones:

- **The EBS CSI driver addon is not there.** EKS does not install
  `ebs-csi-controller` by default, and without it no claim for an
  `io1`/`io2`/`gp3` volume is ever provisioned. The addon's absence is
  silent from the claim's side: the events say `provisioning waiting for
  first Consumer to be consumed` or nothing useful at all.
- **No node in the right zone.** The EBS CSI driver provisions a volume in
  the zone of the pod that first consumes the claim, and only when a
  consumer exists. A claim nothing schedules against — a pod pinned
  elsewhere, a node group with no capacity — has no consumer, and no volume.
  Check that something actually mounts the claim and can be scheduled.

On both, `kubectl describe pvc -n <namespace> <name>` is the first stop: the
`Events` at the bottom carry the reason the controller did not bind it, and
that reason names the fix.

## Reading on

- [Flux health]({{< relref "/docs/operations/flux-health.md" >}}) — the
  report-and-panel pair for the reconciliation layer
- [Observability]({{< relref "/docs/platform/observability/_index.md" >}})
  — where the dashboards live and how they reach the cluster
- [Storage classes]({{< relref "/docs/platform/foundations/cloud-support.md" >}})
  — the classes the platform defines per cloud
