---
title: Flux health
weight: 10
description: Which Flux Kustomizations and HelmReleases are not Ready — a read-only report script, and the Grafana panel that shows the same signal over time.
lastVerified: 2026-10-28
---

Everything on the cluster is reconciled by Flux, so "is the platform healthy"
mostly reduces to "are the Flux objects Ready". A `Kustomization` whose health
check times out and a `HelmRelease` whose chart failed to install look
identical from the outside: the object's `Ready` condition goes false, and
everything around it keeps reporting green.

This page covers the two views of that signal, on `gcp-0` and anywhere else
the repository is deployed.

## The report: `scripts/ops/k8s/flux-health.sh`

`scripts/ops/k8s/flux-health.sh` prints one line per `Kustomization` or
`HelmRelease` that is not Ready:

```console
$ scripts/ops/k8s/flux-health.sh
Kustomization flux-system/apps: HealthCheck failed: timeout waiting for health check
HelmRelease observability/victoria-metrics-k8s-stack: Helm install failed: context deadline exceeded
```

The line is `<kind> <namespace>/<name>: <reason>`, where `<reason>` is the
message of the object's `Ready` condition. An object with no `Ready`
condition at all yet — just created, or the status never arrived — is reported
as `no Ready condition reported`, because silence is not health.

It is **a report, not a gate**:

- it exits `0` whatever the count, so it never breaks whatever runs it;
- it reads only (`kubectl get`), changes nothing;
- if the cluster is unreachable or the Flux CRDs are absent it still exits
  `0`, with a warning on stderr and whatever it could list on stdout.

`scripts/ci/tests/test-flux-health.sh` runs the script against a canned
`kubectl get -o json` fixture, covering the not-ready, ready, and
no-condition cases for both kinds plus the unreachable-cluster path.

Why a second script, when `flux-not-ready.sh` already exists? That one covers
the Kustomizations only. On `gcp-0` the `HelmRelease`s are just as
load-bearing — a chart that fails to reconcile surfaces its error in the
object's `Ready` condition, nowhere else.

## The panel: Not-Ready Flux resources

The **flux-cluster** dashboard (vendored inline in
`flux/observability/grafana-dashboards.yaml`) has a **Not-Ready Flux
resources** panel: a time series of the count of `Kustomization`s and
`HelmRelease`s that are not Ready, one line per kind:

```promql
sum(gotk_resource_info{exported_namespace=~"$namespace",
  customresource_kind=~"Kustomization|HelmRelease", ready!="True"})
by (customresource_kind)
```

The `gotk_resource_info` metric is exported by the Flux controllers
themselves; the `$namespace` variable is the dashboard's namespace filter.

### How to read it

- **Flat on zero** — every `Kustomization` and `HelmRelease` on the selected
  namespaces is Ready.
- **A line that steps up and back** — a reconciliation in flight, or a
  transient failure that the next reconcile fixed. The Flux controllers
  retry; a blip that resolves itself is normal.
- **A line that steps up and stays** — something is stuck. Run the script
  above to get the per-object reason, and see
  [Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}) for the
  failures specific to this platform.

Note that `ready!="True"` is deliberately wider than the dashboard's *Failing
Reconcilers* stat, which counts `ready="False"` only: this panel also counts
`Unknown` — objects whose reconciliation has not concluded. That matches the
script's definition of not-Ready (an object is Ready, or it is not), so the
panel and the script answer the same question.

## Reading on

- [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}}) — the
  reconciliation model behind these conditions
- [Observability]({{< relref "/docs/platform/observability/_index.md" >}})
  — where the dashboards live and how they reach the cluster
- [Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}) — the
  failures specific to this platform
