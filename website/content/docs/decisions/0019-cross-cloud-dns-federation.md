---
title: Cross-cloud DNS federation — GKE workloads assume an AWS role for Route53
linkTitle: 0019 · Cross-cloud DNS federation
weight: 190
description: gcp-0's cert-manager and external-dns authenticate to the Route53 zone cloud.ogenki.io is hosted in via AWS IAM OIDC federation on a projected ServiceAccount token, rather than a static access key, a delegated Cloud DNS subdomain, or moving the zone.
lastVerified: 2026-08-25
---

**Status**: Accepted
**Date**: 2026-08-25
**Deciders**: Platform Team
**Related Design**: GCP public ingress design, in the repository at
`docs/superpowers/specs/2026-08-25-gcp-public-ingress-design.md` (design docs are not published
to this site, so this is a repo path rather than a link)

---

## Context

Workstream 10 built `gcp-0`'s private ingress and stopped at the public boundary, recording
why: DNS-01 has nothing to solve against on GCP. `opentofu/gcp/network/dns.tf` creates a
**private** Cloud DNS zone, `cloud.ogenki.io` is a Route53 hosted zone
(`Z002027037R5RFCG05YY6`) this repository does not manage, and Let's Encrypt must resolve the
`_acme-challenge` TXT record **publicly**. Three ways out were named and none chosen at the
time.

This design revisits that boundary because one of the three stopped being the credential
liability the earlier note assumed. cert-manager v1.21.1 — the version this repo pins —
supports `spec.acme.solvers[].dns01.route53.auth.kubernetes`: Kubernetes authenticates to
Route53 using `AssumeRoleWithWebIdentity` with a **bound ServiceAccount token**, the same
identity-by-token model the platform already uses on both clouds (EKS Pod Identity, GKE
Workload Identity) extended across the cloud boundary. No access key, no secret placed in GCP
Secret Manager, nothing to rotate.

## Decision Drivers

- **No static AWS credentials.** Whatever gcp-0 uses to reach Route53 must not be a long-lived
  access key sitting in GCP Secret Manager.
- **Cloud-agnostic public names.** [ADR-0017](../0017-multi-cloud-dns-naming.md) already
  decided public names carry no cloud label, so a service can move between clouds without a
  DNS rename. *Amended below*: gcp-0's own default wildcard turned out to need a per-cloud name
  after all, for a reason ADR-0017 did not anticipate — see the note under Decision Outcome and
  the Consequences.
- **One Gateway implementation per cluster**, consistent with
  [ADR-0005](../0005-gke-standard-self-managed-cilium.md)'s reasoning against a second
  Gateway controller on GKE.
- **No deletion permissions on stateful services** the platform constitution already commits
  to, applied here to a Route53 zone this repository does not own.
- **Minimal blast radius** of whatever crosses the cloud boundary — scoped to record changes
  in one zone, not zone management.

## Considered Options

### Option A: Route53 stays authoritative, GCP federates (chosen)

One public zone, names stay cloud-agnostic. Cost: an AWS IAM OIDC provider trusting the GKE
issuer, and GCP's public certificate issuance depends on Route53 being reachable. The
dependency is real, but with the OIDC/bound-token model it is a *credential-less* dependency on
a DNS zone — not a shared secret and not a shared control plane, which is what the parent
design's earlier objection to this option ("reintroduces exactly the cross-cloud dependency
option A was rejected for") assumed it would be.

### Option B: Delegate a subdomain to a public Cloud DNS zone

No AWS dependency at all, which is genuinely attractive. Rejected because the delegated name
would have to be cloud-labelled — `gcp.cloud.ogenki.io` — and
[ADR-0017](../0017-multi-cloud-dns-naming.md) rejects exactly that: *"A public endpoint has no
such constraint, and encoding the cloud into it converts a deployment detail into a permanent
contract."* Public names are cloud-agnostic so a service can move between clouds; a per-cloud
public zone forecloses that. It also needs a parent-zone (NS delegation) change on the existing
Route53 zone.

### Option C: Move `cloud.ogenki.io` wholesale to Cloud DNS

Keeps names cloud-agnostic and removes GCP's dependency on AWS — but inverts it: `aws-0` would
then need federated access to Cloud DNS for its own certificates and records. A symmetric
problem, a larger migration, and it moves a live public zone that this repository does not even
manage today.

### Option D: Tailscale Funnel

Both private Gateways already carry `tailscale.com/funnel: "false"`, so enabling it is one
annotation away, and it would need no load balancer, no DNS-01 and no public zone at all. It is
excluded by a hard constraint rather than a trade-off: Funnel serves a certificate for
`<machine>.<tailnet>.ts.net` and **cannot serve one for a custom domain**. A CNAME from
`cloud.ogenki.io` to it fails TLS. Funnel is the right tool when the hostname does not matter;
here it does.

## Decision Outcome

**Chosen option**: Option A. Route53 stays the single authoritative public zone. AWS gets an
IAM OIDC identity provider trusting the GKE cluster's issuer
(`https://container.googleapis.com/v1/projects/<project>/locations/<location>/clusters/gcp-0`)
and one role, `gcp-0-route53-dns`, assumable only by the named ServiceAccount subjects
`security/cert-manager` and `kube-system/external-dns-public`, scoped to:

- `route53:ChangeResourceRecordSets` / `route53:ListResourceRecordSets` on the one hosted zone
- `route53:GetChange` (required by the ACME polling flow; not scopable to a zone — an AWS API
  limitation, not an oversight)
- `route53:ListHostedZonesByName` / `route53:ListHostedZones` for external-dns's zone discovery

No zone-management permission is granted. The role can change records in one zone; it cannot
create, delete or reconfigure zones — consistent with the constitution's "no deletion
permissions for stateful services".

On the GCP side there is **nothing**: no `GCPWorkloadIdentity` claim, no Google service
account, no secret. The projected ServiceAccount token is the credential, and AWS validates it
against the OIDC provider. This is the one place in the platform where a workload authenticates
to the *other* cloud, and it does so with no material at rest.

The federation lives in `opentofu/shared/`, not `opentofu/aws/`: it is an AWS resource that
exists solely to couple the two clouds, which is what `shared/` already means here —
`opentofu/shared/tailscale` holds the tailnet for the same reason. Filing it under `aws/` would
present a federation point as AWS's own concern and hide it from anyone reading the GCP tree.

**gcp-0's public name is `gcp.cloud.ogenki.io`, not `cloud.ogenki.io`.** Caught in the
whole-branch final review, not in the original design: `aws-0` already runs a live wildcard
Certificate for `*.cloud.ogenki.io`. A `gcp-0` Gateway and Certificate requesting that identical
identifier set would share Let's Encrypt's Duplicate Certificate limit (5 per week for an
identical hostname set, counted across accounts and **not** exempted for renewals) with `aws-0`'s
production renewal, and both clusters' cert-managers would race to write the same
`_acme-challenge.cloud.ogenki.io` TXT record. No delegation is created to fix this — records for
`*.gcp.cloud.ogenki.io` still live in the same `cloud.ogenki.io` hosted zone
(`Z002027037R5RFCG05YY6`), so the IAM scoping above is unaffected; only the *name* gcp-0 requests
within that zone changed. This mirrors a split this repo already made for private domains
(`priv.aws.ogenki.io` vs `priv.gcp.ogenki.io`) — the public name was the one that had collided,
not the zone.

## Consequences

### Positive

- No static AWS credential anywhere on GCP — no access key, no secret in GCP Secret Manager.
- Public names stay cloud-agnostic at the **zone** level — `cloud.ogenki.io` remains one shared
  Route53 zone, not split per cloud. See Negative for the one place this does not extend to
  gcp-0's own default wildcard.
- The trust is minimal and explicit: two named ServiceAccount subjects, one audience, one zone,
  no delete permissions.
- The stack is independent of GCP stacks existing — the issuer URL is a deterministic string
  from project/location/cluster name, not a value read from a live cluster, so
  `opentofu/shared/aws-gcp-federation` has no `after` dependency on GCP.

### Negative

- **GCP's public certificate issuance and public DNS records now depend on Route53 being
  reachable.** An AWS-side Route53 outage stalls new certificate issuance and DNS record
  changes for gcp-0's public services, though already-issued certificates and already-published
  records are unaffected until the next renewal or change.
- **The OIDC issuer URL is derived, not verified, at write time.** `data "tls_certificate"`
  fetches the certificate of the shared `container.googleapis.com` host, which succeeds even
  when the cluster-specific path in the URL is wrong — a misconfigured project, location or
  cluster name would not fail the apply. See the comment above `data.tls_certificate.gke_oidc`
  in `main.tf`, and the verification step this pushes into Task 5 (deploy-time, against a live
  `gcp-0`).
- Renaming `gcp-0`, moving it to another zone, or moving GCP projects changes the issuer URL and
  requires the OIDC provider to be recreated — the federation is pinned to the cluster's
  identity, not just its existence.
- **gcp-0's public Gateway and Certificate carry a cloud label after all** (`gcp.cloud.ogenki.io`),
  which the "cloud-agnostic public names" driver did not anticipate needing. Any HTTPRoute
  attached to that Gateway inherits a `gcp.`-prefixed hostname by construction — Gateway API
  requires listener/route hostname intersection — so a public service on gcp-0 cannot get a
  cloud-agnostic name from this Gateway alone. Accepted because the alternative (the identical
  `*.cloud.ogenki.io` identifier set aws-0 already holds) is a live production hazard, not a
  style preference — see Decision Outcome.

### Neutral

- `aws-0` is unaffected by the IAM federation itself — it already authenticates to Route53
  directly (same account, no federation needed) and this ADR adds no dependency in that
  direction. It was **not** unaffected by the certificate as originally specified: requesting
  the identical `*.cloud.ogenki.io` identifier set on gcp-0 would have shared a Let's Encrypt
  rate limit and a DNS-01 challenge record with `aws-0`'s live production certificate. Fixed by
  giving gcp-0 its own name — see Decision Outcome.

## Implementation Notes

- Stack: `opentofu/shared/aws-gcp-federation/` — `aws_iam_openid_connect_provider.gke`,
  `aws_iam_role.route53`, and the policy scoping it to `Z002027037R5RFCG05YY6`. State in the
  shared S3 backend, same as `opentofu/shared/tailscale` (see
  [ADR-0018](../0018-per-cloud-opentofu-state.md) for why `shared/` stays in S3 while the GCP
  tree moved to GCS).
- Output `route53_role_arn` (`arn:aws:iam::396740644681:role/gcp-0-route53-dns`) is what the
  `letsencrypt-prod` ClusterIssuer's `dns01.route53.role` and external-dns-public's
  `AWS_ROLE_ARN` consume on the GCP side.
- The stack is not tagged `opt-in`: nothing in it depends on GCP infrastructure existing, so
  there is no reason to skip it by default the way the GCP stacks are. Its `destroy` script
  carries its own guard instead — see `opentofu/shared/aws-gcp-federation/workflows.tm.hcl`.

## References

- `opentofu/shared/aws-gcp-federation/main.tf` — the OIDC provider, role and policy
- [ADR-0005 · GKE Standard with self-managed Cilium]({{< relref "0005-gke-standard-self-managed-cilium.md" >}})
- [ADR-0017 · Multi-cloud DNS naming]({{< relref "0017-multi-cloud-dns-naming.md" >}})
- [ADR-0018 · Per-cloud OpenTofu state]({{< relref "0018-per-cloud-opentofu-state.md" >}})
