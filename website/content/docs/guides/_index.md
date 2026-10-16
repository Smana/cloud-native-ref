---
title: Guides
weight: 40
description: Task-oriented walkthroughs — fork and adapt the repository, add an application, add a cloud provider, debug a failure.
lastVerified: 2026-09-02
---

Task-oriented rather than domain-oriented: each guide starts from something
you are trying to do — reuse this repository for your own platform, add an
application, add a cloud provider, or debug a failure — and walks the steps
end to end.

{{< cards >}}
  {{< card link="fork-and-adapt" title="Fork and adapt" subtitle="Every environment-specific value, what you can remove, and the shape of the running cost." >}}
  {{< card link="add-an-application" title="Add an application" subtitle="From an image to a running, routed, monitored app — via the wizard or by hand." >}}
  {{< card link="add-a-cloud-provider" title="Add a cloud provider" subtitle="What a new provider must implement, and which APIs must not change." >}}
  {{< card link="troubleshooting" title="Troubleshooting" subtitle="The failures specific to this platform — several of which fail silently." >}}
  {{< card link="restore-a-database" title="Restore a database" subtitle="Bootstrap a CloudNativePG cluster from a frozen backup, and prove the restore worked." >}}
  {{< card link="migrate-the-identity-provider" title="Migrate the identity provider" subtitle="Move ZITADEL between clouds with its seed, admin PAT and client secrets together." >}}
  {{< card link="openbao-cross-cloud-failover" title="OpenBao cross-cloud failover" subtitle="Bring the GCP standby up from the mirrored snapshot, repoint, and fail back." >}}
{{< /cards >}}
