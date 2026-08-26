---
title: Progressive complexity
weight: 20
description: One API that starts at an image and a port, and grows to a production application without ever changing shape.
lastVerified: 2026-08-20
---

Most platform abstractions fail in one of two directions. Either they are so
simple that the first real requirement forces you out of them and back into
raw YAML, or they are so complete that the smallest possible use still
demands fifty lines of configuration.

The `App` composition is an attempt at the third option: an API whose
simplest form is genuinely simple, and which grows by *adding* fields rather
than by being abandoned.

## The shortest useful claim

A container image and a port:

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: App
metadata:
  name: xplane-podinfo
  namespace: apps
spec:
  image:
    repository: stefanprodan/podinfo
    tag: "6.14.1"
  service:
    port: 9898
```

That renders a Deployment, a Service, and a ServiceAccount — with the
security context the [platform
constitution]({{< relref "/docs/reference/platform-constitution.md" >}})
requires, because the composition applies it rather than trusting the author
to remember.

## What each rung adds

Nothing below replaces what came before; each is an additional block on the
same claim.

| Add | And you get |
|---|---|
| `route` | An HTTPRoute on the shared private gateway, with DNS and a certificate |
| `sqlInstance` | A CloudNativePG cluster, and `DATABASE_URL` wired into the pod |
| `kvStore` | A Valkey instance, and `REDIS_URL` wired in |
| `objectStore` | A bucket (S3 on `aws-0`, GCS on `gcp-0`) plus the IAM role / Workload Identity association to reach it |
| `autoscaling` | An HPA, and a PodDisruptionBudget to make scaling safe |

The wiring is the point. A developer who asks for a database does not then
have to discover the connection-string format, create a Secret, and mount
it — the composition connects the two things it just created.

## Why this shape

**The escape hatch is the abstraction failing.** If a platform API's answer
to "I need X" is "drop down to raw manifests", then it is a scaffold, not a
platform. Every rung above is a case that would otherwise have sent someone
to write a Deployment by hand.

**Defaults carry the policy.** Security context, resource limits, network
policy, probes — these are not optional fields a developer might set. They
are what the composition emits regardless, which is how a constitution
becomes enforcement rather than aspiration.

**The claim stays portable.** `App` is developer-facing, so it is
deliberately cloud-neutral: the same claim means the same thing on either
cloud, even though the S3 bucket and the IAM role underneath it do not. That
is no longer hypothetical — the same `App` claim renders an S3 bucket plus an
`EPI` on `aws-0`, and a GCS bucket plus a `GCPWorkloadIdentity` on `gcp-0`.
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
draws that line explicitly, and
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}})
shows where it held and where it is still owed work.

## The cost

Abstractions are not free, and this one has a real price:

- **A composition is a program.** When a claim does not render what you
  expected, the debugging surface is KCL and a Crossplane pipeline, not the
  manifest in front of you.
- **The field set is finite.** A capability nobody has added yet is not
  available, and adding it means changing a composition that every
  application shares.
- **Version coupling is real.** The compositions ship as a package this
  repository pins, so a claim's behaviour depends on which version is
  pinned — not only on what the claim says.

## Reading on

- [Developer platform]({{< relref "/docs/platform/developer-platform/_index.md" >}})
  — what each field actually renders
- [Deploy your first app]({{< relref "/docs/get-started/first-app.md" >}})
  — the shortest path to a running claim
