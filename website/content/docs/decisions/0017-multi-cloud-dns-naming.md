---
title: Multi-cloud DNS naming — cloud-agnostic public, cloud-pinned private
linkTitle: 0017 · DNS naming
weight: 170
description: Public names stay cloud-agnostic under cloud.ogenki.io so a service can move or fail over between clouds, while private names are pinned per cloud under priv.<cloud>.ogenki.io because a private zone is bound to one VPC's resolver.
lastVerified: 2026-08-23
---

**Status**: Accepted
**Date**: 2026-08-23
**Deciders**: Platform Team
**Related Design**: GCP Support — Dual-Cloud Platform Design, in the repository at
`docs/superpowers/specs/2026-08-18-gcp-support-design.md` (design docs are not published to
this site, so this is a repo path rather than a link)

---

## Context

Adding GCP as a second maintained cloud forced a naming question that the single-cloud
platform never had to answer: **where does the cloud provider appear in a DNS name, and
when should it appear at all?**

The pre-existing scheme had no answer, because it had no second cloud:

| Zone | Purpose | Managed where |
|---|---|---|
| `cloud.ogenki.io` | public platform services | **not in this repo** — a `data` lookup of a zone created elsewhere |
| `priv.cloud.ogenki.io` | private services, Tailscale-only | `opentofu/aws/network/route53.tf`, VPC-attached |

The first GCP attempt inserted a provider label into the private name,
`priv.gcp.cloud.ogenki.io`, which produced two problems at once. It was long — 32 characters
before the service label — and, worse, it was *inconsistent on the axis order*. Read
right-to-left as DNS hierarchy:

- AWS: `ogenki.io` → `cloud` (platform) → `priv` (visibility). **No provider label at all.**
- GCP: `ogenki.io` → `cloud` → `gcp` (provider) → `priv` (visibility).

Two different hierarchies for one concept, plus the implicit rule *"absence of a provider
label means AWS"* — knowledge that holds only while AWS is the sole incumbent, and that
cloud number three silently inherits.

One constraint drives most of what follows and is not negotiable: **a private zone is bound
to one cloud's VPC resolver.** A Route53 private hosted zone resolves only from AWS VPCs
attached to it; GCP VMs cannot attach and cannot resolve it. Each cloud must therefore host
its own private zone regardless of which cloud is nominated "home". Public names carry no
such constraint.

---

## Decision Drivers

- **Portability of public endpoints.** A public name is a contract with browsers, OIDC
  redirect URIs, webhook registrations and TLS certificate SANs. Whatever it encodes becomes
  expensive to change.
- **The VPC-binding constraint.** Private zones are inherently per-cloud; the naming should
  reflect a real constraint rather than fight it.
- **Symmetry between clouds.** No cloud should be the unlabelled default.
- **Length.** Every private service inherits the zone name in its FQDN, its certificate SANs
  and every `HTTPRoute` hostname.
- **Future multi-cloud routing.** The scheme must not preclude a service that answers from
  either cloud.

---

## Considered Options

### Option 1: Provider label under the platform root, both clouds

`grafana.priv.aws.cloud.ogenki.io` / `grafana.priv.gcp.cloud.ogenki.io`

**Pros**:

- Symmetric; preserves the `cloud.` platform namespace exactly as-is.
- Smallest conceptual departure from what existed.

**Cons**:

- 32 characters before the service label — the original complaint, unaddressed.
- Stacks a provider label on top of a label already meaning "cloud", which reads as
  `priv.gcp.cloud` — "private, gcp, cloud".

### Option 2: Visibility first, provider second

`grafana.aws.priv.ogenki.io` / `grafana.gcp.priv.ogenki.io`

**Pros**:

- Symmetric and short (26 characters).
- A single private root, `priv.ogenki.io`, naturally parents both clouds' pinned names —
  useful for a cloud-agnostic private name (see *Multi-cloud routing* below).

**Cons**:

- Implies a shared `priv.ogenki.io` parent zone that does not meaningfully exist and would
  itself need a home, quietly reintroducing the cross-cloud coupling being avoided.
- Puts visibility — an *attribute* of a zone — above the cloud, which is its actual *owner*.

### Option 3: Provider first, visibility second (chosen)

`grafana.priv.aws.ogenki.io` / `grafana.priv.gcp.ogenki.io`

**Pros**:

- Symmetric and short (26 characters).
- The ownership boundary sits higher in the hierarchy than the attribute. AWS runs Route53
  with a VPC-attached private zone; GCP runs Cloud DNS with its own. Each cloud owns its
  entire subtree.
- `ogenki.io` delegates `aws.` and `gcp.` once each, should public per-cloud records ever
  be wanted.

**Cons**:

- A cloud-agnostic private root (`priv.ogenki.io`) becomes a structural *sibling* of the
  pinned names rather than their parent. Functionally identical under split-DNS, marginally
  less tidy.

### Option 4: Home cloud, no label on the incumbent

`grafana.priv.cloud.ogenki.io` (AWS, unchanged) / `grafana.priv.gcp.ogenki.io` (GCP)

**Pros**:

- Zero churn on the AWS side.
- Internally coherent: AWS is home, home needs no label.

**Cons**:

- Preserves *"absence of a label means AWS"* as load-bearing implicit knowledge.
- The two zones have structurally different shapes, failing the symmetry driver.

### Option 5: Per-cloud public zones

`harbor.aws.ogenki.io` / `harbor.gcp.ogenki.io`

**Pros**:

- Uniform treatment of public and private.

**Cons**:

- Encodes an implementation detail into a public contract. Moving a service between clouds
  breaks bookmarks, OIDC redirect URIs, webhook registrations and certificate SANs.
- Directly defeats one of the main reasons to run two clouds.

---

## Decision Outcome

**Chosen option**: Option 3 for private names; public names remain cloud-agnostic and unchanged.

| Name | Scope | Status |
|---|---|---|
| `<svc>.cloud.ogenki.io` | public, cloud-agnostic | unchanged |
| `<svc>.priv.aws.ogenki.io` | private, pinned to AWS | renamed from `priv.cloud.ogenki.io` |
| `<svc>.priv.gcp.ogenki.io` | private, pinned to GCP | renamed from `priv.gcp.cloud.ogenki.io` |
| `<svc>.priv.ogenki.io` | private, cloud-agnostic | **reserved, not yet implemented** |

**Rationale**: the asymmetry between public and private is principled rather than an
oversight. A private zone *cannot* be anything but cloud-specific, so its name reflects a
real constraint. A public endpoint has no such constraint, and encoding the cloud into it
converts a deployment detail into a permanent contract.

Label order follows ownership: the cloud owns the DNS infrastructure, visibility is an
attribute of a zone. The alternative ordering was rejected because it implies a parent zone
that would need a home of its own.

One argument used in discussion deserves an explicit correction, because it is intuitive and
wrong: per-cloud DNS *delegation* is largely irrelevant to private names. Private zones do
not resolve through the public DNS tree at all — Tailscale split-DNS maps a domain directly
to a resolver address, with no parent zone and no `NS` records. Delegation only matters if
public records are ever placed under a per-cloud label, which this ADR decides against.

---

## Consequences

### Positive

- Both clouds read identically; no cloud is the unlabelled default, and cloud number three
  slots in without inheriting implicit rules.
- Private FQDNs are shorter than before on both clouds (26 characters, from 28 on AWS and
  32 on GCP).
- Public endpoints stay movable between clouds, which is a prerequisite for the routing work
  described below.

### Negative

- A one-off rename touching 61 files, plus the OpenBao PKI `allowed_domains` list and the
  AWS Secrets Manager key paths (`certificates/<domain>/…`) which are derived from the
  domain rather than being hostnames.
- Four secrets are left orphaned at the old path
  (`certificates/priv.cloud.ogenki.io/{root-ca,intermediate-ca,vault,openbao}`). They hold
  CA key material; a rebuild generates a **new** root CA at the new path unless the existing
  material is copied across first.
- `.secrets.baseline` needed refreshing rather than pragma-annotation, because it hashes
  values and the changed SM key paths read as new findings.

### Neutral

- The rename was done while AWS had no cluster and empty state. On a running platform it
  would have required re-issuing every certificate, recreating the Route53 private zone and
  updating live `HTTPRoute` hostnames. That window is specific to this moment and is now closed.

---

## Multi-cloud routing

The naming above is deliberately shaped by a use case not yet built: **a service addressed
by one name that can answer from either cloud.**

### Public, north-south

`<svc>.cloud.ogenki.io` already supports this. Route53 weighted, latency or failover records
can point at an AWS load balancer and a GCP load balancer simultaneously, driven by health
checks; failover latency is bound by DNS TTL and client caching. A global load balancer
fronting both clouds gives per-request steering and faster failover at the cost of placing
the front door inside one cloud, reintroducing a home-cloud dependency in the data path.

### Private, east-west

Cilium ClusterMesh is the real primitive — a Service annotated
`service.cilium.io/global: "true"` load-balances across endpoints in both clusters, with the
tailnet as the L3 substrate. A cloud-agnostic private name (`<svc>.priv.ogenki.io`, reserved
above) is what such a service would be addressed by.

Already satisfied, and not by accident:

- **Non-overlapping pod CIDRs** — AWS `100.64.0.0/16`, GCP `100.65.0.0/16`. This is
  ClusterMesh's hardest prerequisite and the overlap check is recorded in
  `opentofu/gcp/network/variables.tfvars`.
- **Distinct cluster names** — `aws-mycluster-0`, `gcp-mycluster-0`.
- **A single tailnet** carrying both clouds' routes.

Known blockers, neither of which is visible until ClusterMesh is attempted:

1. **`cluster.id` is never set.** Both `eks/configure` and `gke/configure` set `cluster.name`
   but not the unique numeric ID (1–255) ClusterMesh requires. IDs must be assigned
   deliberately and never reused, since they are encoded into the identity of every endpoint.
2. **AWS does not advertise its pod CIDR into the tailnet.**
   `advertised_routes.aws = ["10.0.0.0/16"]` in `opentofu/shared/tailscale/variables.tfvars`
   omits `100.64.0.0/16`, while GCP does advertise `100.65.0.0/16`. Cross-cloud pod-to-pod
   traffic has no route today.

Unverified, and not to be designed around until tested: the two clusters run **different
Cilium IPAM modes** (`eni` on AWS, `kubernetes` on GCP) and **asymmetric encryption**
(WireGuard on AWS only, load-bearing for [cilium#43493](https://github.com/cilium/cilium/issues/43493)).
Whether ClusterMesh operates correctly across that combination should be established on
throwaway clusters before any design depends on it.

---

## Implementation Notes

Applied in one commit across 61 files. Public reference count was used as the control:
`cloud.ogenki.io` occurrences went from 320 to 173, exactly `320 − 137 − 10`, confirming that
only private references were rewritten.

Gates: `./scripts/validate-manifests.sh` → `Valid: 1187, Invalid: 0, Skipped: 0`;
`./scripts/validate-links.sh` → all relative links resolve; `tofu fmt` clean.

The `.drawio` diagram sources and their rendered `.svg` counterparts are both text and were
renamed together so they do not drift.

---

## References

- `docs/superpowers/specs/2026-08-18-gcp-support-design.md` — the dual-cloud design this
  decision came out of (in the repository; not published to this site)
- [ADR-0007](0007-cloud-abstraction-boundaries.md) — the same
  split-by-audience principle applied to APIs rather than names
- [ADR-0013](0013-tailscale-over-bastion.md) — the tailnet that makes
  split-DNS the private resolution mechanism
- [Cilium ClusterMesh](https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/)
