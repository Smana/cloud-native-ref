---
title: Zero trust
weight: 40
description: Default-deny at the network, no ambient credentials, no static secrets — enforced by policy rather than asserted.
lastVerified: 2026-08-30
---

"Zero trust" is easy to claim and hard to check. The useful version of the
idea is narrow: **being inside the perimeter grants nothing.** A pod on the
cluster network cannot reach another pod because it is on the network; an
application cannot reach a cloud API because it is running in the right
account.

What makes that real is whether each grant is enforced somewhere a reader
can go and inspect.

## Where trust is denied by default

**The network.** Every workload that runs a pod is expected to carry a
CiliumNetworkPolicy: default-deny, with explicit allows. The
[constitution]({{< relref "/docs/reference/platform-constitution.md" >}})
requires it, and the `App` composition emits one so that applications get it
without asking.

**Identity.** Workloads reach AWS through EKS Pod Identity, never IRSA and
never static keys — the reasoning is in
[ADR-0002]({{< relref "/docs/decisions/0002-eks-pod-identity-over-irsa.md" >}}).
On `gcp-0` the same binding runs through GKE Workload Identity, via the
sibling `GCPWorkloadIdentity` XRD
([ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}})).
Policies are scoped to `xplane-*` resources. On `aws-0`, deletion is
explicitly denied for the platform's own critical buckets — Harbor, OpenBao
snapshots, CNPG backups — carved out of an otherwise broad `s3:*` grant, so a
compromised controller cannot destroy those three; nothing else gets that
carve-out, and `gcp-0` grants `storage.buckets.delete` with no equivalent
deny at all.

**Secrets.** Nothing sensitive is committed. External Secrets Operator pulls
from the cloud's managed secret store — AWS Secrets Manager on `aws-0`,
Google Secret Manager on `gcp-0` — into Kubernetes Secrets at runtime;
OpenBao is scoped to the private PKI, not application secrets
([ADR-0025]({{< relref "/docs/decisions/0025-cloud-managed-secret-stores.md" >}})).

**Ingress.** The cluster API endpoint is private and platform services are
reachable only over Tailscale — on both clouds — and the two private gateways
are separated by ACL tag so that admin-only services are not merely unlisted
but unreachable for non-admins.

**Certificates.** A private PKI issues every internal certificate through
cert-manager, so TLS is not something applications opt into.

## Enforced, not documented

The distinction that matters is between a rule written down and a rule that
fails a build. In this repository:

- Kyverno rejects non-compliant workloads at admission
- `./scripts/validate-manifests.sh` audits the *rendered* bundle for
  privilege escalation, capabilities and image tags before anything merges
- the `App` composition emits the security context rather than trusting
  each author to include it

A rule that lives only in a document is a hope. Each of the above turns one
into a gate.

## Where the platform is honest about its gaps

A zero-trust claim is only worth reading if it also says where the model is
relaxed. Two examples this repository documents rather than hides:

- **The root CA private key is present in the live OpenBao mount**, because
  the intermediate is signed inside OpenBao to keep the deploy unattended.
  Accepted for a reference platform; explicitly not to be carried into a
  deployment where the root CA matters. See
  [PKI and secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}).
- **Network policy coverage is uneven.** The constitution requires a
  CiliumNetworkPolicy on every pod-running workload; the observability stack
  does not yet meet that bar. See
  [Observability]({{< relref "/docs/platform/observability/_index.md" >}}).

Both are the kind of thing a security page is tempted to omit. Omitting them
would make the page less useful, not more convincing — a reader evaluating
this platform needs to know which properties are enforced and which are
aspirations with a known exception.

## Reading on

- [Security]({{< relref "/docs/platform/security/_index.md" >}}) — the PKI
  chain, secret flow and policy engine as implemented
- [Networking]({{< relref "/docs/platform/networking/_index.md" >}}) — how
  traffic reaches an application, and what stops it
