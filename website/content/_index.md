---
title: Cloud Native Reference
layout: hextra-home
description: "An opinionated, production-ready Kubernetes platform reference. GitOps with Flux, infrastructure from Kubernetes with Crossplane, zero-trust networking with Cilium, a private PKI with OpenBao — on AWS EKS today, designed for a second cloud."
---

{{< hextra/hero-badge >}}
  Open source · Apache-2.0 · runs on your own AWS account
{{< /hextra/hero-badge >}}

{{< hextra/hero-headline >}}
  An opinionated, production-ready Kubernetes platform, built on GitOps
{{< /hextra/hero-headline >}}

{{< hextra/hero-subtitle >}}
  Infrastructure as code with OpenTofu and Crossplane, continuous delivery with
  Flux, a private PKI and zero-trust networking, and a developer abstraction
  that turns one small YAML claim into a whole application. Deploy it into your
  own AWS account in about thirty minutes.
{{< /hextra/hero-subtitle >}}

{{< hextra/hero-button text="Deploy in 30 minutes" link="docs/get-started/" >}}
{{< hextra/hero-button text="View on GitHub" link="https://github.com/Smana/cloud-native-ref" style="background:transparent;border:1px solid rgba(148,163,184,0.45);color:inherit" >}}

<p class="cnref-eyebrow" style="margin-top:3rem">The whole platform, on one page</p>

![Platform architecture: AWS managed services, the EKS cluster in four tiers, and the applications and data stores on top](/images/diagrams/platform-overview.svg)

<h2 class="cnref-section-title">What's here</h2>

{{< hextra/feature-grid cols="3" >}}
  {{< hextra/feature-card link="docs/get-started/" icon="play" title="Get Started"
    subtitle="Three sequential stages — network, secrets, Kubernetes — driven by OpenTofu and Terramate. One command per stage, and the cluster comes up with Cilium, Flux and Karpenter already running." >}}
  {{< hextra/feature-card link="docs/platform/" icon="server" title="Platform"
    subtitle="Cilium, Flux, Crossplane, OpenBao, VictoriaMetrics, Gateway API, Karpenter, KEDA — each with what it actually buys you here, and what it cost to adopt." >}}
  {{< hextra/feature-card link="docs/concepts/" icon="light-bulb" title="Concepts"
    subtitle="GitOps as a dependency hierarchy rather than a slogan. Progressive complexity in a platform API. Zero trust that is enforced by policy, not asserted in a README." >}}
  {{< hextra/feature-card link="docs/guides/" icon="map" title="Guides"
    subtitle="Fork and adapt, add an application, add a cloud provider, troubleshoot — including what to strip out and roughly what it costs to run." >}}
  {{< hextra/feature-card link="docs/reference/" icon="book-open" title="Reference"
    subtitle="Repository layout, the technology stack and what each piece is responsible for, commands, CI, the platform constitution." >}}
  {{< hextra/feature-card link="docs/decisions/" icon="scale" title="Decisions"
    subtitle="Sixteen architecture decision records — what was chosen, what it was chosen over, and the cost that came with it." >}}
{{< /hextra/feature-grid >}}

{{< stack-strip >}}

<p class="cnref-strip-more" style="margin-top:2.5rem">
Runs on <strong>AWS EKS</strong> today. A second cloud is designed but not yet
implemented — see <a href="{{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}">ADR-0007</a>
for where the platform draws its cloud boundary.
</p>
