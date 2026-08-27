---
title: One identity provider across both clouds, hosted on AWS and named by a variable
linkTitle: 0022 · Single identity provider
weight: 220
description: ZITADEL runs as a single instance on aws-0 and serves both clusters, addressed through an `identity_provider_url` variable rather than each cluster assuming the IdP is local — because two instances would be two unfederated identity domains, and a hardcoded hostname made "which cloud hosts it" unanswerable from configuration.
lastVerified: 2026-08-27
---

**Status**: Accepted
**Date**: 2026-08-27
**Deciders**: Platform Team

---

## Context

ZITADEL is exposed at `auth.${public_domain_name}`, and `public_domain_name` is
a **per-cluster** value: `cloud.ogenki.io` on `aws-0`, `gcp.cloud.ogenki.io` on
`gcp-0` ([ADR-0019](0019-cross-cloud-dns-federation.md) amended
[ADR-0017](0017-multi-cloud-dns-naming.md) to make the public wildcard per-cloud
after all).

The reassuring half of that: deploying `security/base/zitadel` on both clusters
would **not** collide. One would answer at `auth.cloud.ogenki.io`, the other at
`auth.gcp.cloud.ogenki.io`, and the two external-dns instances would never fight
over a record.

The unresolved half is what it would *mean*. Two hostnames is two independent
ZITADEL instances: two user directories, two session stores, two sets of OIDC
clients, and no federation between them. A user provisioned on one is unknown to
the other. For an identity provider that is almost always the wrong outcome —
and it would have been reached **by default**, as a side effect of a naming rule
written for a different purpose, rather than by decision.

Two things forced the question now:

1. **Consumers hardcoded the host.** `apps/base/openwebui/app.yaml` pointed its
   OIDC discovery at `https://auth.cloud.ogenki.io`, and
   `tooling/base/homepage/helmrelease.yaml` linked to the same literal. Both
   live in `base/`, shared by both clusters. On `gcp-0` those literals happen to
   resolve to the right place — but by accident, not design, and nothing in
   configuration recorded which cloud was supposed to host the IdP.
2. **It cannot run on `gcp-0` today anyway.** `security/base/zitadel` declares a
   `SQLInstance`, and until recently that claim had no GCP implementation. The
   constraint is lifting, so the choice had to be made deliberately before it
   was made accidentally.

## Decision Drivers

- **One identity domain.** Users, sessions and OIDC clients should exist once.
- **No accidental topology.** Which cluster hosts a singleton must be a stated
  value, not an emergent property of which overlay happens to include it.
- **Consistent with the DNS precedent.** The platform already accepted one
  authoritative service reachable across the cloud boundary
  ([ADR-0019](0019-cross-cloud-dns-federation.md)); a second such dependency
  should be argued in the same terms, not smuggled in.
- **Movable.** Whichever cloud hosts it today, moving it should be a
  configuration change with a written procedure, not a code change.

## Considered Options

### Option A: One instance on `aws-0`, addressed by variable (chosen)

`security/base/zitadel` is included by exactly one cluster's overlay. Every
consumer reads `${identity_provider_url}` instead of a literal. `aws-0` derives
that value from its own public domain, because a cluster that hosts the IdP is
by definition reachable at `auth.<its own domain>`. `gcp-0` sets the same key to
a literal pointing back at `aws-0`.

**Cost, stated plainly**: `gcp-0` depends on `aws-0` for login. If `aws-0` is
down, `gcp-0`'s OIDC-authenticated services cannot authenticate new sessions.
This is the platform's **second** deliberate cross-cloud dependency, after
public DNS.

It is the same *class* of dependency as ADR-0019's, and weaker in one respect
and stronger in another. Weaker: DNS federation is credential-less, whereas this
is a runtime service dependency on the request path for logins. Stronger: it
fails visibly and locally — a login that does not work — rather than as a
certificate that silently never issues.

### Option B: Two independent instances

What the current naming produces by default. Operationally simple, no
cross-cloud dependency, and each cluster survives the other's outage.

Rejected because two identity domains is not a smaller version of one identity
domain — it is a different product. Every user exists twice, roles are assigned
twice and drift, and "log in with your platform account" stops having a single
meaning. Nothing in this platform wants that, and nobody would choose it
deliberately; it would only ever be arrived at by not choosing.

### Option C: An external or managed identity provider

Hosted by neither cloud, so neither depends on the other.

Rejected for this repository specifically: the point of running ZITADEL here is
to demonstrate a self-hosted PKI-and-identity stack. Outsourcing it removes the
thing being demonstrated. It remains the right answer for a production platform
that does not have that goal, and this ADR is not an argument against it there.

## Decision Outcome

**Option A.** One ZITADEL, on `aws-0`, addressed through
`${identity_provider_url}`.

The variable is set in both clusters' vars ConfigMaps:

| Cluster | Value | Why that form |
|---|---|---|
| `aws-0` | `"https://auth.${var.public_domain_name}"` — **derived** | It hosts the IdP, so its own domain is the right answer by construction |
| `gcp-0` | `var.identity_provider_url`, defaulting to `https://auth.cloud.ogenki.io` — **literal** | It consumes the IdP. Deriving would yield `auth.gcp.cloud.ogenki.io`, which nothing serves |

That asymmetry is deliberate and is the whole mechanism: **a cluster can derive
this URL only when it is itself the host.** The literal on the consuming side is
what makes the topology visible in configuration.

### Moving the identity provider

Three things change together, and nothing enforces that they agree:

1. Which cluster's overlay includes `security/base/zitadel`.
2. `identity_provider_url` on the **new host** — switch it to the derived form.
3. `identity_provider_url` on the **old host** — switch it to a literal naming
   the new one.

Get (1) right and (2)/(3) wrong and the symptom is an OIDC discovery fetch
against a hostname that does not resolve, reported by the *consumer* — OpenWebUI
failing to start a login — with nothing naming the IdP move as the cause.

## Consequences

**Good**

- One identity domain, which is what an IdP is for.
- The hosting decision is now a value in configuration rather than an accident
  of overlay membership.
- Consumers are cloud-agnostic: `base/` manifests no longer name a cloud.
- Moving the IdP is a documented configuration change.

**Bad**

- `gcp-0` cannot authenticate users when `aws-0` is unavailable. Accepted for a
  reference platform where both clusters are torn down routinely; it would need
  revisiting for anything with an availability target.
- Three values must agree on a move, checked by nobody. Written down above
  because it cannot be enforced by the current substitution model — Flux
  `postBuild` substitutes strings and cannot compute one value from another.

**Neutral**

- ZITADEL's own manifests keep using `auth.${public_domain_name}` for their
  Gateway and Certificate. That stays correct: those render only on the cluster
  that hosts it, where the local domain *is* the right answer.

## Related

- [ADR-0017](0017-multi-cloud-dns-naming.md) — why public names are per-cloud,
  the rule that created this question
- [ADR-0019](0019-cross-cloud-dns-federation.md) — the first deliberate
  cross-cloud dependency, and the template for arguing this one
- [ADR-0007](0007-cloud-abstraction-boundaries.md) — platform-facing APIs stay
  cloud-shaped; this is a platform-facing decision made explicit rather than
  abstracted away
