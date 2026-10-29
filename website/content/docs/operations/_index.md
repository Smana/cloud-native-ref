---
title: Operations
weight: 55
description: Point-in-time health views for the running platform — the Flux health report and its Grafana panel.
lastVerified: 2026-10-28
---

The reference and guides sections describe how the repository is built. This
section is for the moments in between: something feels wrong, and you need to
know *right now* whether Flux is keeping the cluster honest.

Each page pairs a one-shot command you can run from a laptop with the standing
Grafana view of the same signal, so the two never drift apart.

{{< cards >}}
  {{< card link="flux-health" title="Flux health" subtitle="Which Kustomizations and HelmReleases are not Ready, from a script or from the dashboard." >}}
  {{< card link="certificate-expiry" title="Certificate expiry" subtitle="Which cert-manager certificates are expiring or not Ready — script, dashboard and alerts." >}}
{{< /cards >}}
