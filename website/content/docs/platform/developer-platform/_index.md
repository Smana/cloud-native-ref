---
title: Developer Platform
weight: 35
description: The App, SQLInstance, and KVStore claims that let a developer deploy a production-ready service with kubectl basics and no Crossplane knowledge.
lastVerified: 2026-08-27
---

{{< callout type="info" >}}
**The XRDs and Compositions are not in this repository.** They live in
[`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration)
and ship as a Crossplane `Configuration` package; this repository only pins
a version:

```yaml
# infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml
spec:
  package: ghcr.io/smana/crossplane-configuration-aws:v0.4.5
```

`gcp-0` serves the same claims from its own package,
`ghcr.io/smana/crossplane-configuration-gcp:v0.4.5`, pinned in
`infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml`
— both clusters currently pin the same release.

What stays here: `functions.yaml` (the KCL function runtime, version-pinned
rather than resolved by the package's `dependsOn`), `environmentconfig.yaml`
(region/cluster values the KCL reads at render time), and the provider
config. Everything that decides what a claim renders — the KCL, the XRD
schemas, the CEL validation — is authored, tested, and released from the
other repository. This is the single most common source of confusion about
this repository: a change to how `App` behaves is never a PR here.
{{< /callout >}}

![One App claim expanding into a whole application: the composition always renders a Deployment, Service and ServiceAccount, adds an HTTPRoute, autoscaler, PodDisruptionBudget, CiliumNetworkPolicy, ExternalSecret and VictoriaMetrics scrape and rule objects for each spec field that is set, and renders three nested claims — SQLInstance, KVStore and EPI — that expand again into a CloudNativePG cluster, a Valkey release, and an IAM role bound to the ServiceAccount by Pod Identity](/images/diagrams/app-claim-expansion.svg)

## What is an App

An `App` is a single small YAML document — a *claim* — that describes a
workload at a high level: which container image to run, whether it is a web
service, a background worker, or a scheduled job, and which extras it needs
(a database, a cache, object storage, routing, autoscaling, and so on).

A developer applies that one claim, and the platform expands it into all the
underlying Kubernetes objects — a Deployment (or CronJob), a Service,
routes, a database, network policies, a service account with cloud
permissions — with security hardening baked in (non-root, read-only root
filesystem, dropped Linux capabilities, seccomp). Nobody hand-writes
Deployments, Services, PVCs, HTTPRoutes, or IAM policies for an app on this
platform. This is [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})'s
rule in practice: `App` is the cloud-neutral, developer-facing side of the
platform — the same claim shape is the goal on every cloud this platform
runs on, even though the AWS resources it renders today (`Bucket`, IAM
`Role`, EKS Pod Identity) are specific to this cluster.

```
                       ┌─────────────────────────────┐
                       │   Your App claim (one YAML)  │
                       │                              │
                       │   kind: App                  │
                       │   spec:                      │
                       │     image: ...                │
                       │     type: web                │
                       │     route: {...}             │
                       │     sqlInstance: {...}       │
                       └──────────────┬───────────────┘
                                      │  kubectl apply
                                      ▼
                       ┌─────────────────────────────┐
                       │      Platform expands it     │
                       └──────────────┬───────────────┘
                                      │
        ┌───────────────┬────────────┼────────────┬───────────────┐
        ▼               ▼            ▼             ▼               ▼
  Deployment /      Service      HTTPRoute /   ServiceAccount   SQLInstance /
   CronJob         (web only)     Gateway      (+ Pod Identity)  Valkey / S3
        │                            │
        ▼                            ▼
   HPA, PDB, PVC              CiliumNetworkPolicy,
   (as requested)            VMServiceScrape, VMRule
```

The only required field is `image.repository`; everything else has a safe
default. A claim is namespaced, so a developer deploys into their own
namespace and manages it with normal `kubectl` and GitOps — see
[Claim]({{< relref "/docs/reference/glossary.md" >}}) in the glossary for how
that maps to the underlying Crossplane objects.

### Workload types

An App has one of three shapes, set by `spec.type` (default `web`):

| `type`   | Renders            | Service? | Route? | Probes by default | Autoscaling / PDB |
|----------|---------------------|----------|--------|--------------------|--------------------|
| `web`    | Deployment          | yes      | yes    | HTTP liveness/readiness | yes |
| `worker` | Deployment          | no       | no     | none               | yes |
| `cron`   | CronJob             | no       | no     | none               | no (forbidden) |

Pick `web` for HTTP services, `worker` for queue consumers and background
processors, and `cron` for recurring scheduled tasks. Deploy your first one
in [Get Started → First Application]({{< relref "/docs/get-started/first-app.md" >}}) —
that page covers the minimal `web` claim end to end; this section covers
everything past it.

{{< cards >}}
  {{< card link="/docs/platform/developer-platform/app/" title="The App claim" icon="cube" subtitle="Workers, cron, config and secrets, sidecars, storage, probes, routing, autoscaling, and observability." >}}
  {{< card link="/docs/platform/developer-platform/app-field-reference/" title="App field reference" icon="table" subtitle="Every spec field, type, and default — the exhaustive reference behind the pages above." >}}
  {{< card link="/docs/platform/developer-platform/data-services/" title="Data services" icon="database" subtitle="PostgreSQL, Valkey, and S3 — provisioned inline with an App claim, wired automatically." >}}
  {{< card link="/docs/platform/developer-platform/app-wizard/" title="App Wizard" icon="sparkles" subtitle="A guided form that opens the same PR a hand-written claim would, with live validation and a render preview." >}}
{{< /cards >}}
