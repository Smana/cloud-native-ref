---
title: Cloud Native Reference
layout: hextra-home
description: "An opinionated, production-ready Kubernetes platform reference. GitOps with Flux, infrastructure from Kubernetes with Crossplane, zero-trust networking with Cilium, a private PKI with OpenBao — on AWS EKS today, designed for a second cloud."
---

{{< hextra/hero-badge >}}
  Open source · Apache-2.0 · runs on your own AWS account
{{< /hextra/hero-badge >}}

{{< hextra/hero-headline >}}
  A production-ready platform you can actually deploy
{{< /hextra/hero-headline >}}

{{< hextra/hero-subtitle >}}
  Not a slide deck and not a toy cluster. Every component here runs, is
  reconciled by Flux, and is gated in CI — a private PKI, zero-trust networking,
  a developer-facing abstraction over managed infrastructure, and a full
  observability stack. Deploy it into your own account in about thirty minutes,
  or read how each piece was chosen.
{{< /hextra/hero-subtitle >}}

{{< hextra/hero-button text="Deploy in 30 minutes" link="docs/get-started/" >}}
{{< hextra/hero-button text="View on GitHub" link="https://github.com/Smana/cloud-native-ref" style="background:transparent;border:1px solid rgba(148,163,184,0.45);color:inherit" >}}

<p style="margin-top:3rem;margin-bottom:0.5rem;font-size:0.8125rem;text-transform:uppercase;letter-spacing:0.08em;color:var(--ogenki-external)">The whole platform, on one page</p>

![Platform architecture: AWS managed services, the EKS cluster in four tiers, and the applications and data stores on top](/images/diagrams/platform-overview.svg)

<h2 style="margin-top:3.5rem">What this repository is for</h2>

{{< hextra/feature-grid cols="2" >}}
  {{< hextra/feature-card link="docs/get-started/" icon="lightning-bolt" title="Bootstrap a platform"
    subtitle="Three sequential stages — network, secrets, Kubernetes — driven by OpenTofu and Terramate. One command per stage, and the cluster comes up with Cilium, Flux and Karpenter already running." >}}
  {{< hextra/feature-card link="docs/concepts/" icon="academic-cap" title="Learn the concepts"
    subtitle="GitOps as a dependency hierarchy rather than a slogan. Progressive complexity in a platform API. Zero trust that is enforced by policy, not asserted in a README." >}}
  {{< hextra/feature-card link="docs/platform/" icon="cube-transparent" title="Evaluate the tools"
    subtitle="Cilium, Flux, Crossplane, OpenBao, VictoriaMetrics, Gateway API, Karpenter, KEDA — each with what it actually buys you here, and what it cost to adopt." >}}
  {{< hextra/feature-card link="docs/guides/fork-and-adapt/" icon="template" title="Make it yours"
    subtitle="Which values are environment-specific, what to strip out, what the minimum viable subset is, and roughly what it costs to run." >}}
{{< /hextra/feature-grid >}}

<h2 style="margin-top:3.5rem">Browse the docs</h2>

{{< hextra/feature-grid cols="3" >}}
  {{< hextra/feature-card link="docs/get-started/" icon="play" title="Get Started" subtitle="Prerequisites, the deploy path, first application, teardown." >}}
  {{< hextra/feature-card link="docs/platform/" icon="server" title="Platform" subtitle="Every domain: foundations, GitOps, networking, security, developer platform, observability, AI." >}}
  {{< hextra/feature-card link="docs/concepts/" icon="light-bulb" title="Concepts" subtitle="The ideas the platform demonstrates, and how it is built." >}}
  {{< hextra/feature-card link="docs/guides/" icon="map" title="Guides" subtitle="Fork and adapt, add an application, add a cloud provider, troubleshoot." >}}
  {{< hextra/feature-card link="docs/reference/" icon="book-open" title="Reference" subtitle="Repository layout, technology stack, commands, CI, the platform constitution." >}}
  {{< hextra/feature-card link="docs/decisions/" icon="scale" title="Decisions" subtitle="Architecture decision records — what was chosen, and what it was chosen over." >}}
{{< /hextra/feature-grid >}}

<p style="margin-top:3.5rem;font-size:0.9375rem;color:var(--ogenki-external)">
Runs on <strong>AWS EKS</strong> today. A second cloud is designed but not yet
implemented — see <a href="{{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}">ADR-0007</a>
for where the platform draws its cloud boundary.
</p>
