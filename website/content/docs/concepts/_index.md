---
title: Concepts
weight: 30
description: The ideas the platform demonstrates — GitOps, progressive complexity, zero trust — independent of the configuration that implements them.
lastVerified: 2026-08-20
---

The ideas this repository demonstrates, separated from the YAML that
implements them: GitOps as a dependency hierarchy rather than a slogan,
progressive complexity in a platform API, and zero trust that is enforced by
policy rather than asserted in a README.

Each page here explains *why* the platform is shaped a particular way and
links to [Platform]({{< relref "/docs/platform/_index.md" >}}) for how it is
wired. If you will never deploy this, these are the pages still worth
reading.

{{< cards >}}
  {{< card link="architecture" title="Architecture" subtitle="The platform in three bands, and where the boundary between clouds falls." >}}
  {{< card link="progressive-complexity" title="Progressive complexity" subtitle="One API that starts at an image and a port and grows to a production application." >}}
  {{< card link="gitops-model" title="The GitOps model" subtitle="Why reconciliation beats deployment, and why the dependency graph is the design." >}}
  {{< card link="zero-trust" title="Zero trust" subtitle="Default-deny at the network, no ambient credentials — and where the model is relaxed." >}}
  {{< card link="how-this-is-built" title="How this is built" subtitle="The design method, the gates that enforce it, and where the process is expensive." >}}
{{< /cards >}}
