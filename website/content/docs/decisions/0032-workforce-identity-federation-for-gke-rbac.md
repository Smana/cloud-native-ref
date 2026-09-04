---
title: Workforce Identity Federation restores per-user Kubernetes RBAC on GKE
linkTitle: 0032 · Workforce identity federation
weight: 320
description: A token-exchange shim between oauth2-proxy and Headlamp trades a ZITADEL id_token for a Google Workforce Identity Federation access token, so gcp-0's API server sees the real user again instead of a single shared ServiceAccount. Supersedes ADR-0026, whose rejection of this option assumed Headlamp itself had to perform the STS exchange — it does not.
lastVerified: 2026-09-02
---

**Status**: Accepted
**Date**: 2026-09-02
**Deciders**: Platform Team

---

## Context

[ADR-0026](0026-headlamp-auth-proxy-on-gke.md) accepted that `gcp-0` would run
Headlamp with `unsafeUseServiceAccountToken: true`: every admitted user reaches
the API server as the single `headlamp` ServiceAccount, and the only
authorisation control is `allowed-group: admin` on oauth2-proxy — an
all-or-nothing gate in front of a shared, privileged identity. `aws-0` has none
of this problem: EKS is told to trust ZITADEL directly
(`identity_providers` in `opentofu/aws/eks/init/variables.tfvars`), Headlamp
forwards the user's `id_token`, and `security/base/rbac/admin.yaml` binds
`Group: admin` to `cluster-admin` per user.

ADR-0026 considered Workforce Identity Federation and dismissed it in one
sentence:

> Headlamp cannot forward a ZITADEL `id_token` into it. It solves human
> `kubectl` access, not this.

**That dismissal rested on an unstated assumption: that Headlamp itself had to
perform the STS token exchange.** It does not. Headlamp's
`-proxy-auth-token-header` flag makes it forward whatever bearer token an
upstream proxy hands it — Headlamp only needs to receive a token that works,
not to mint one. That means the exchange can happen entirely in front of
Headlamp, in a small dedicated proxy, and Headlamp never has to speak Google's
STS protocol at all. The first half of ADR-0026's sentence is still true; the
second half is the premise this record corrects.

---

## Decision Drivers

- **Restore per-user Kubernetes RBAC on `gcp-0`**, matching the model `aws-0`
  already has, rather than living with a single shared identity indefinitely.
- **No new standing GCP IAM authority for a Headlamp user.** Whatever
  authenticates the user to the cluster must not also become a general GCP
  credential.
- **Reuse the existing ZITADEL groups pipeline.** `groups-from-roles.js`
  already produces the claim `aws-0`'s RBAC consumes; the GKE side should
  consume the same claim rather than stand up a second authorisation source.
- **Minimal new moving parts**, for a cluster that is torn down and rebuilt
  routinely — a heavyweight standing component is a cost paid on every
  rebuild, not once.

---

## Considered Options

### Option 1: Workforce Identity Federation + a token-exchange shim

An IAM-only GCP feature (no in-cluster component, no fleet registration, no
Connect gateway) exchanges a ZITADEL `id_token` for a short-lived Google
access token scoped to a workforce pool. A small proxy (`token-exchange-proxy`,
provider-neutral, RFC 8693) sits between oauth2-proxy and Headlamp: it reads
the `id_token` oauth2-proxy forwards, exchanges it at Google STS, and injects
the result as `X-Gke-Token`. Headlamp forwards that header verbatim
(`-proxy-auth-token-header=X-Gke-Token`) as the bearer token to the API
server, which resolves it to a `principal://…/workforcePools/<pool>/subject/<sub>`
identity and a `principalSet://…/group/<role>` group — an ordinary
ClusterRoleBinding on that group authorises exactly as `Group: admin` does on
`aws-0`.

**Pros**:
- No in-cluster component beyond one small, provider-neutral shim; no fleet
  registration, no Connect gateway, no GCP IAM roles granted to the principal.
- Reuses the ZITADEL `groups` claim already driving `aws-0`'s RBAC — same
  role, same `cluster-admin`, different spelling.
- The federated token is inert in GCP itself (measured: `403` on Resource
  Manager and Cloud Storage) — compromising it does not hand out a cloud
  credential, only cluster access scoped by Kubernetes RBAC.

**Cons**:
- One new component to own: a small Go proxy, in this repo's threat model, that
  briefly holds user tokens in memory.
- A new organisation-level GCP resource (the workforce pool) whose name is
  effectively permanent — renaming is delete-and-recreate with a 30-day
  soft-delete window, and every RBAC group string embeds the name.

### Option 2: Pinniped Concierge (impersonation-proxy mode)

ADR-0026's originally-named upgrade path. Apache-2.0, no licence cost, GKE
explicitly supported, and the impersonation-proxy strategy exists precisely
because managed control planes take no `--oidc-issuer-url` flag. It would
preserve per-user RBAC and keep `gcp-0` structurally identical to `aws-0`.

**Pros**:
- Purpose-built for exactly this gap; would make `gcp-0` and `aws-0` use the
  same authentication model, not two different ones.
- No GCP-specific IAM resource to own.

**Cons**:
- Needs a Concierge (and a Supervisor to federate ZITADEL) as new standing
  in-cluster infrastructure, plus a LoadBalancer/ClusterIP with its own
  certificates — for a cluster that is deleted after every validation run.
- Per Tremolo's own comparison, Pinniped has no story for a non-OIDC-native
  client like Headlamp: it would still need an impersonating proxy in front of
  it, which is Option 3 below layered on top rather than instead of it.

### Option 3: An impersonating proxy in front of Headlamp (kube-oidc-proxy and forks)

oauth2-proxy authenticates the human as today, then hands off to an
impersonating reverse proxy (kube-oidc-proxy, or a maintained fork —
TremoloSecurity, banyansecurity, sspreitzer, or OpenUnison's bundled one) that
sets `Impersonate-User` / `Impersonate-Group` against the real API server.
Kubernetes RBAC would see the real user, with no GCP-side component at all.

**Pros**:
- Keeps Kubernetes RBAC and needs no GCP org changes — the smallest change on
  the GCP side of any option considered.

**Cons**:
- **Cannot work with in-cluster Headlamp at all.** An impersonating proxy must
  sit *behind* Headlamp — Headlamp itself needs to forward `Impersonate-*`
  headers to the API server it talks to — but Headlamp cannot be pointed at a
  different in-cluster API endpoint
  ([kubernetes-sigs/headlamp#1460](https://github.com/kubernetes-sigs/headlamp/issues/1460),
  open since October 2023), and its OIDC mode does not emit impersonation
  headers either
  ([#4198](https://github.com/kubernetes-sigs/headlamp/issues/4198)). This is a
  structural blocker, not a configuration gap.

### Option 4: Google Workspace identities + Google Groups for RBAC

Authenticate operators as real Google Workspace humans and bind Google Groups
in Kubernetes RBAC — natively supported by GKE, no shim, no workforce pool.

**Pros**:
- Zero custom code; GKE's own documented path for Google-identity RBAC.

**Cons**:
- GKE demands a `cloud-platform`-scoped token to authenticate at all
  (measured: `userinfo.email` scope alone is rejected with `401`). For a real
  Workspace human that scope is a full, general-purpose GCP credential — not
  the inert token Option 1 produces — verified: the same scope returns `HTTP
  200` against Resource Manager for a real user.
- Moves group membership and identity out of ZITADEL for this one cloud,
  splitting the group source of truth the two clouds already share.

---

## Decision Outcome

**Chosen option**: "Option 1 — Workforce Identity Federation + a
token-exchange shim"

**Rationale**: Option 3 is not actually available — it cannot work with
Headlamp's in-cluster deployment mode, full stop. Option 2 does not remove the
need for something like Option 3's proxy in front of Headlamp, so it does not
avoid that blocker either; it only adds Pinniped's own standing infrastructure
on top. Option 4 works but hands every logged-in operator a general
`cloud-platform` GCP credential to reach a Kubernetes dashboard, which is a
strictly worse blast radius than Option 1's inert federated token. Option 1 is
the only option that is both **available** (measured working end-to-end
against a live cluster) and **least-privileged** (the credential it produces
can do nothing in GCP itself).

The following was measured against a live `gcp-0` on 2026-09-02, then torn
down; the design rests on this evidence rather than on the product
documentation alone:

| Claim | Result |
|---|---|
| GKE accepts a Google **id_token** | ✗ `HTTP 401` |
| GKE accepts a Google **access token** | ✓ `HTTP 200` |
| GKE accepts a `userinfo.email`-scoped token | ✗ `HTTP 401` |
| GKE accepts a `cloud-platform`-scoped token | ✓ `HTTP 200` |
| ZITADEL `id_token` → Google STS exchange | ✓ 1h token, no GCP credentials needed to request it |
| Federated token → `gcp-0` API server | ✓ `HTTP 200` |
| Identity the API server resolves | `principal://…/workforcePools/<pool>/subject/<zitadel-sub>` |
| ZITADEL `groups: ['admin']` → Kubernetes group | ✓ `principalSet://…/workforcePools/<pool>/group/admin` |
| A plain ClusterRoleBinding on that group | ✓ authorises — 46 pods listed |
| RBAC still scopes down (negative control) | ✓ `secrets` denied |
| GCP IAM roles required on the principal | none |
| Fleet registration / Connect gateway required | no |
| Federated token's power **in** GCP (not the cluster) | `403` on Resource Manager **and** Cloud Storage |

The last row is the one that makes Option 1 preferable to Option 4 on its
own: the token is requested with `cloud-platform` **scope**, which reads as
broad, but a workforce principal starts with zero IAM role bindings, and scope
is not authority. The token authenticates to the cluster and can do nothing
in Google Cloud. A Workspace human's equivalent token (Option 4) carries
whatever that person can do in the organisation.

Architecture:

```
browser
  │
  ▼
oauth2-proxy ──── OIDC authorization-code against ZITADEL
  │               emits X-Forwarded-Groups; forwards the raw id_token upstream
  ▼
token-exchange shim  (new, ~40 lines, provider-neutral, no GCP defaults compiled in)
  │  POST https://sts.googleapis.com/v1/token
  │    subject_token = the ZITADEL id_token
  │    audience      = //iam.googleapis.com/…/workforcePools/<pool>/providers/zitadel
  │  ← short-lived Google federated access token (1h)
  │  sets X-Gke-Token, strips Authorization
  ▼
Headlamp ──── -proxy-auth-token-header=X-Gke-Token
  │           forwards it as Authorization: Bearer, never validates it itself
  ▼
GKE API server
  authenticates → principal://…/subject/<zitadel-sub>
  groups        → principalSet://…/group/admin
  authorises    → ClusterRoleBinding in Git (security/gcp-0/rbac/admin.yaml)
```

Nothing Google-hosted sits in the request path to the cluster; the only
outbound call is the shim's own STS exchange, and it is unauthenticated — it
presents the user's token and needs no service account of its own.

---

## Consequences

### Positive

- Per-user Kubernetes RBAC is restored on `gcp-0`: the API server can tell
  users apart again, and `security/gcp-0/rbac/admin.yaml` authorises the same
  way `security/base/rbac/admin.yaml` does on `aws-0` — same ZITADEL role,
  same `cluster-admin`, a `principalSet://` group instead of a bare group name.
- `allowed-group: admin` on oauth2-proxy becomes defence in depth rather than
  the whole authorisation model, and the `headlamp` ServiceAccount's own
  ClusterRoleBinding was reduced off `cluster-admin` in the same change —
  the blast radius of a Headlamp compromise is now one user's RBAC for up to
  an hour, not everything the shared SA could do indefinitely.
- No GCP IAM role is granted anywhere in this design; the federated token is
  provably inert outside the cluster.

### Negative

- A workforce pool is an organisation-level GCP resource with a soft-deleted,
  effectively-permanent name — every RBAC group string embeds it, so renaming
  is a coordinated break-and-fix across `security/gcp-0/rbac/*`, not a config
  edit.
  - *Mitigation*: named once, documented as permanent in
    `opentofu/gcp/workforce-identity/variables.tfvars`, and pinned by the
    `workforce-pool-id` doc claim (see Implementation Notes) so the docs
    cannot drift from it silently.
- The audience the workforce pool provider trusts is the whole ZITADEL
  **project**, not one OIDC client — any token ZITADEL issues in that project
  can be exchanged. This is acceptable because exchange only establishes
  identity; a user without the `admin` role still gets a token that
  authenticates and authorises nothing.
- A new component (the shim) briefly holds user tokens in memory, which is
  why it runs default-deny CiliumNetworkPolicy, restricted PSS, and a
  never-log-a-token rule.

### Neutral

- `aws-0` is untouched. It keeps trusting ZITADEL directly at the EKS control
  plane; the two clouds now reach the same RBAC outcome by genuinely
  different mechanisms; ADR-0007's cloud-abstraction stance treats that as
  acceptable divergence rather than something to unify.

---

## Implementation Notes

- `opentofu/gcp/workforce-identity/` — new stack, organisation-scoped (a
  second GCP cluster would share the pool), creates
  `google_iam_workforce_pool.zitadel` and its OIDC provider. The pool id is
  `workforce_pool_id = "ogenki-zitadel"` — permanent by construction (see
  Consequences), so treat a change to that value as a breaking rename, not a
  config edit.
- `workforce_pool_id` is threaded into `gke/configure`'s `flux_cluster_vars`
  (`opentofu/gcp/gke/configure/kubernetes.tf`) so
  `security/gcp-0/rbac/admin.yaml` can substitute it into the
  `principalSet://` group name; `scripts/flux-schema/check-substitution.py`
  fails the build if that wiring is missing, rather than letting Flux
  silently substitute an empty string.
- `tooling/gcp-0/headlamp/token-exchange.yaml` — the shim Deployment +
  Service.
- `tooling/gcp-0/headlamp/oauth2-proxy.yaml` — upstream points at the shim;
  `pass-authorization-header: true` forwards the id_token to it.
- `tooling/gcp-0/headlamp/headlamp-proxy-auth.yaml` —
  `unsafeUseServiceAccountToken: false`; `-proxy-auth-token-header=X-Gke-Token`
  added; the chart's default `clusterRoleName: cluster-admin` on the
  `headlamp` ServiceAccount's own ClusterRoleBinding reduced to `view`.

---

## References

- [ADR-0026](0026-headlamp-auth-proxy-on-gke.md) — the record this supersedes
- [ADR-0024](0024-identity-provider-per-cloud.md) — where ZITADEL runs; this
  record is about what GKE's API server will trust, which ADR-0024 does not
  cover
- [ADR-0027](0027-primary-cloud-provider.md) — the per-cloud/singleton
  classification this design follows: the workforce pool is a `gcp-0`-owned
  resource, not a cross-cloud one
- [ADR-0002](0002-eks-pod-identity-over-irsa.md) — the AWS identity model this
  diverges from
- `docs/superpowers/specs/2026-09-02-gke-rbac-headlamp-design.md` — the full
  design, including the shim's failure-handling rules and the false-trail
  writeup on an earlier, wrong RBAC-scoping conclusion
