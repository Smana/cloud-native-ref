---
title: Platform
weight: 20
description: Every domain the platform runs — networking, security, GitOps, observability, and the developer-facing abstraction on top.
lastVerified: 2026-08-20
---

One section per domain: what runs, why it was chosen over the alternatives,
and how it is wired together. Foundations and GitOps first, then networking
and security, then the developer platform, observability, and the optional
self-hosted AI stack.

{{< cards >}}
  {{< card link="/docs/platform/foundations/" title="Foundations" icon="cube" subtitle="OpenTofu, Terramate, and the three-stage model that provisions everything before Flux takes over." >}}
  {{< card link="/docs/platform/gitops/" title="GitOps" icon="refresh" subtitle="Why Flux, the dependency hierarchy, and how manifests are validated before they merge." >}}
  {{< card link="/docs/platform/security/" title="Security" icon="lock-closed" subtitle="OpenBao's PKI and secrets engine, cert-manager and External Secrets, Kyverno and CiliumNetworkPolicy defaults." >}}
{{< /cards >}}
