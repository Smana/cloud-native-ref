---
title: Get Started
weight: 10
description: Deploy the platform into your own cloud account in about thirty minutes.
lastVerified: 2026-08-20
---

The platform deploys in three sequential stages: the network, then the secrets
and PKI layer, then Kubernetes. Each is a separate OpenTofu stack orchestrated
by Terramate, and each must complete before the next begins.

Pick your cloud to begin. AWS is implemented and maintained; GCP is designed but
not yet built.

{{< cards >}}
  {{< card link="/docs/get-started/prerequisites/" title="Prerequisites" icon="clipboard-check" subtitle="Accounts, access, and tools needed before the first deploy." >}}
  {{< card link="/docs/get-started/aws/" title="AWS" icon="cloud" subtitle="Three sequential stages, about thirty minutes." >}}
  {{< card link="/docs/get-started/gcp/" title="GCP" icon="beaker" subtitle="Designed, not yet implemented." >}}
  {{< card link="/docs/get-started/first-app/" title="First Application" icon="puzzle" subtitle="Deploy your first app with one small YAML claim." >}}
{{< /cards >}}
