---
title: Cloud Native Reference
layout: hextra-home
description: "An opinionated, production-ready Kubernetes platform reference: bootstrap a complete platform on your own AWS or GCP account in about thirty minutes, built entirely from open-source cloud-native tools and following platform-engineering and security best practices."
---

{{< hextra/hero-badge >}}
  Open source · Apache-2.0 · runs on your own AWS or GCP account
{{< /hextra/hero-badge >}}

{{< hextra/hero-headline >}}
  An opinionated, production-ready Kubernetes platform, built on GitOps
{{< /hextra/hero-headline >}}

{{< hextra/hero-subtitle >}}
  Bootstrap a complete platform on your own AWS or GCP account in about thirty
  minutes — built entirely from open-source, cloud-native tools. It follows
  platform-engineering and security best practices from the first commit:
  everything as code and reconciled from Git, zero-trust networking,
  least-privilege identity, secrets never stored in the repository, and a paved
  road that takes developers from a few lines of YAML to a production-ready
  application.
{{< /hextra/hero-subtitle >}}

{{< hextra/hero-button text="Deploy in 30 minutes" link="docs/get-started/" >}}
{{< hextra/hero-button text="View on GitHub" link="https://github.com/Smana/cloud-native-ref" style="background:transparent;border:1px solid rgba(148,163,184,0.45);color:inherit" >}}

<p class="cnref-eyebrow" style="margin-top:3rem">The whole platform, on one page</p>

![Platform architecture: the cloud's managed services on the left with their AWS and GCP equivalents, the Kubernetes cluster in four tiers, and the applications and data stores on top](/images/diagrams/platform-overview.svg)

<h2 class="cnref-section-title">What's here</h2>

{{< hextra/feature-grid cols="3" >}}
  {{< hextra/feature-card link="docs/get-started/" icon="play" title="Get Started"
    subtitle="Three sequential stages — network, secrets, Kubernetes — driven by OpenTofu and Terramate. Two commands on either cloud, and the cluster comes up with Cilium and Flux already reconciling." >}}
  {{< hextra/feature-card link="docs/platform/" icon="server" title="Platform"
    subtitle="Cilium, Flux, Crossplane, OpenBao, VictoriaMetrics, Gateway API, Karpenter, KEDA — each with what it actually buys you here, and what it cost to adopt." >}}
  {{< hextra/feature-card link="docs/concepts/" icon="light-bulb" title="Concepts"
    subtitle="GitOps as a dependency hierarchy rather than a slogan. Progressive complexity in a platform API. Zero trust that is enforced by policy, not asserted in a README." >}}
  {{< hextra/feature-card link="docs/guides/" icon="map" title="Guides"
    subtitle="Fork and adapt, add an application, add a cloud provider, troubleshoot — including what to strip out and roughly what it costs to run." >}}
  {{< hextra/feature-card link="docs/reference/" icon="book-open" title="Reference"
    subtitle="Repository layout, the technology stack and what each piece is responsible for, commands, CI, the platform constitution." >}}
  {{< hextra/feature-card link="docs/decisions/" icon="scale" title="Decisions"
    subtitle="An architecture decision record for every consequential choice — what was chosen, what it was chosen over, and the cost that came with it." >}}
{{< /hextra/feature-grid >}}

{{< stack-strip >}}

<p class="cnref-strip-more" style="margin-top:2.5rem">
Runs on <strong>AWS EKS</strong> and <strong>GCP GKE</strong> from one repository
and one Flux tree — not a fork each. The two lanes share every Kubernetes-layer
component and diverge only where the clouds do; see
<a href="{{< relref "/docs/platform/foundations/cloud-support.md" >}}">Cloud support</a>
for the side-by-side, and
<a href="{{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}">ADR-0007</a>
for where the platform refuses to pretend they are the same.
</p>
