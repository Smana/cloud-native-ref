---
title: Foundations
weight: 10
description: Why OpenTofu and Terramate, and the three-stage model every cloud lane implements before Flux takes over.
lastVerified: 2026-08-27
---

Everything a Kubernetes API server needs to exist *before* Flux can reconcile
anything — the network, the secrets and PKI layer, and the cluster itself —
is provisioned with [OpenTofu](https://opentofu.org/) stacks orchestrated by
[Terramate](https://terramate.io/). This page is the model: why these two
tools, and why three stages rather than one. For the commands and what each
stage actually creates, see [Get Started]({{< relref "/docs/get-started/_index.md" >}})
and this section's cloud-specific page.

![Five OpenTofu stacks running in Terramate's dependency order: network creates the VPC, pod subnets, Route53 zones and the Tailscale subnet router; openbao/cluster and openbao/management then build the secrets and PKI layer; eks/init creates the cluster on a temporary VPC-CNI; eks/configure deletes that CNI, installs Cilium and Flux, and hands the rest of the platform to GitOps](/images/diagrams/bootstrap-stages.svg)

## Why OpenTofu

OpenTofu is the open-source fork of Terraform, created after HashiCorp moved
Terraform off an OSI-approved license. It is now a Linux Foundation project
with community governance, and it stayed compatible with existing Terraform
configuration and providers — so adopting it cost nothing beyond the tool
name in CI and `mise.toml`.

## Why Terramate

A platform with five-plus independent lifecycles (network, secrets, cluster
bootstrap split into two internal stages, an opt-in LLM platform) doesn't fit
one OpenTofu root module. Terramate turns the separate stacks into one graph:

- **Ordering** — each stack declares the stacks it runs `after` in its
  `stack.tm.hcl`. Terramate topologically sorts the graph instead of a human
  remembering to `cd` into five directories in the right sequence.
- **Drift detection** — `terramate script run drift detect` plans every
  stack and reports divergence without applying anything.
- **DRY configuration** — `opentofu/config.tm.hcl` holds the globals every
  stack reads (region, cluster name, chart versions) instead of five copies
  of the same variable.
- **Cloud selection** — one variable, `TM_CLOUD`, decides which lanes an
  invocation may touch (`aws` by default, or `gcp`, `aws,gcp`, `all`). It is
  enforced in `scripts/tm-provisioner.sh`, the wrapper every stack reaches
  OpenTofu through, so a single interception point covers the shared scripts and
  every per-stack override. The AWS `llm-platform` stack keeps its own
  `TM_LLM_PLATFORM_ENABLED` gate — that is a feature axis, not a cloud one.

The alternative — running `tofu apply` by hand in each stack directory —
still works; it just loses all four of the above and puts the ordering back
in a human's head.

## The three-stage model

Every cloud this platform targets provisions in the same three stages,
because the dependency between them is real, not a convention:

1. **Network** — VPC/subnets and whatever gives this machine private access
   to what gets built next. Nothing after this stage can reach anything
   built in the next two.
2. **Security** — a secrets and PKI layer, running before Kubernetes exists
   because Kubernetes bootstrap itself consumes it: on AWS, the second half
   of cluster bootstrap reads an AppRole credential this stage already
   created and seeds it into the cluster as a bootstrap Secret, so the
   Kubernetes stack's own `stack.tm.hcl` declares this stage in its `after`
   list.
3. **Kubernetes** — the cluster, plus enough of a CNI to make nodes `Ready`,
   with Flux installed and reconciling by the end of it. This is the handoff
   point: once Flux is running, [GitOps]({{< relref "/docs/platform/gitops/_index.md" >}})
   owns everything that happens next.

This page stays cloud-neutral on purpose, not because there is one "true"
shape underneath, but because the *model* — three stages, in this order, for
this reason — really is the same on every cloud, while the stacks that
implement it are not. Where a page can't be honestly neutral, it isn't:
[ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})
makes the same call for the Crossplane compositions — an API that only looks
cloud-neutral produces worse errors than one that is honestly cloud-shaped —
so the cloud-specific detail lives on [AWS]({{< relref "/docs/platform/foundations/aws.md" >}})
and [GCP]({{< relref "/docs/platform/foundations/gcp.md" >}}), not blended in
here. Where the two differ service by service —
and where they deliberately meet — is on
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}).
