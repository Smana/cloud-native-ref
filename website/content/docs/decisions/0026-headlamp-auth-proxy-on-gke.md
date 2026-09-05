---
title: Headlamp authenticates behind an auth proxy on GKE, not against the cluster
linkTitle: 0026 · Headlamp auth on GKE
weight: 260
description: GKE cannot be told to trust ZITADEL, so on gcp-0 Headlamp sits behind oauth2-proxy and talks to the API server as its own ServiceAccount — trading per-user Kubernetes RBAC for an authorisation gate at the proxy. aws-0 keeps real per-user OIDC. Superseded by ADR-0032.
lastVerified: 2026-09-02
---

**Status**: Superseded by [ADR-0032](0032-workforce-identity-federation-for-gke-rbac.md)
**Date**: 2026-08-28
**Deciders**: Platform Team

---

{{< callout type="warning" >}}
**Superseded 2026-09-02.** This record's dismissal of Workforce Identity
Federation assumed Headlamp itself had to perform the Google STS token
exchange; it does not — Headlamp's `-proxy-auth-token-header` flag lets an
upstream proxy do the exchange and hand it a working token. [ADR-0032](0032-workforce-identity-federation-for-gke-rbac.md)
uses exactly that, restoring per-user Kubernetes RBAC on `gcp-0`. The
context and alternatives below are otherwise still an accurate record of what
was known on 2026-08-28.
{{< /callout >}}

## Context

Headlamp runs `-in-cluster` with OIDC and forwards the user's `id_token` to the
Kubernetes API server. That only works if the API server trusts the issuer.

On `aws-0` it does, because the EKS cluster is told to:

```hcl
# opentofu/aws/eks/init/variables.tfvars
identity_providers = {
  zitadel = {
    issuer_url     = "https://auth.cloud.ogenki.io"
    username_claim = "email"
    groups_claim   = "groups"
  }
}
```

With that, `groups` from `zitadel-actions/groups-from-roles.js` become real
Kubernetes groups, and `security/base/rbac/admin.yaml` (Group `admin` →
`cluster-admin`) does the authorising.

**GKE exposes no equivalent.** The managed control plane takes no
`--oidc-issuer-url`. `gcp-0` therefore had a Headlamp that could authenticate a
human and then fail every API call, which is how the gap surfaced on 2026-08-28:
after fixing two unrelated ZITADEL bugs, login worked and nothing else did.

Three things were checked before choosing:

- **Identity Service for GKE**, the feature that used to provide the missing
  knob, is **deprecated as of 2026-07-01 and unsupported in GKE 1.37+**. The
  cluster runs 1.35, so it would work today and stop working on upgrade. Note
  the blocker is deprecation, not licensing — Google's docs state no GKE
  Enterprise requirement for it.
- **Workforce Identity Federation**, Google's named replacement, is an IAM
  feature needing no in-cluster components — but it authenticates a client
  *to Google*, via an STS token exchange. Headlamp cannot forward a ZITADEL
  `id_token` into it. It solves human `kubectl` access, not this.
- **Headlamp's own OIDC impersonation** would have sidestepped the whole problem
  by sending `Impersonate-User` instead of the raw token. It is
  [broken and open](https://github.com/kubernetes-sigs/headlamp/issues/4198)
  (v0.38.0, reported Nov 2025, no maintainer response).

## Decision

**On `gcp-0`, oauth2-proxy authenticates the user and Headlamp trusts its
headers.** Headlamp talks to the API server as its own ServiceAccount.

This is the upstream-documented answer for exactly this case: Headlamp's
identity-aware-proxy guide covers "in-cluster users who want to use OIDC based
authentication when the kubernetes cluster itself doesn't have OIDC
authentication". The chart's own flag for it is named `unsafeUseServiceAccountToken`,
and that name is accurate rather than alarmist.

`aws-0` is untouched and keeps per-user OIDC. The divergence lives in
`tooling/gcp-0/headlamp/`, not in `base/`.

Four pieces, none of which is optional:

| File | Role |
|---|---|
| `oauth2-proxy.yaml` | authenticates against ZITADEL, `--allowed-group=admin` |
| `headlamp-proxy-auth.yaml` | `-proxy-auth=true`, OIDC off, SA token on |
| `httproute-oauth2-proxy.yaml` | routes via the proxy **and strips spoofable headers** |
| `network-policy.yaml` | makes the proxy the only path to Headlamp |

## What this accepts

**Per-user Kubernetes RBAC is gone on `gcp-0`.** Every admitted user acts as the
`headlamp` ServiceAccount, so the API server cannot tell them apart — the
`admin` / `backend` / `frontend` / `data` tiers that `flux-ui` still distinguishes
collapse to one. Authorisation moves entirely to `--allowed-group=admin` on the proxy, which
is why that flag is load-bearing rather than defence in depth.

**Two things must both hold, or the model fails open.** Headlamp believes
`X-Forwarded-User`. So (1) the HTTPRoute removes every `X-Forwarded-*` and
`X-Auth-Request-*` header from inbound requests before the proxy sets its own,
and (2) a CiliumNetworkPolicy allows ingress to Headlamp only from the proxy.
Without (2) any pod in the cluster could call `headlamp:4466` claiming to be
anyone; the gateway filter alone is a fence with the gate open beside it.

This is acceptable **because these clusters are disposable and already behind
Tailscale** — reaching the hostname at all requires a `tag:k8s` device. It would
not be acceptable on a long-lived multi-tenant cluster; there, Pinniped below is
the answer.

## Alternatives considered

**Pinniped Concierge in impersonation-proxy mode.** Apache-2.0, no licence cost,
GKE explicitly supported, and the impersonation-proxy strategy exists precisely
because managed control planes take no API-server flags. It would **preserve
per-user RBAC** and keep `gcp-0` identical to `aws-0`'s model. Rejected for now
on weight: Concierge plus a Supervisor to federate ZITADEL, a LoadBalancer or
ClusterIP with its own certificates, for a cluster that is deleted after every
validation run — and it was not verified that Headlamp can target an
impersonation endpoint instead of `-in-cluster`. **This is the upgrade path** the
moment per-user RBAC matters on GCP.

**Identity Service for GKE.** Deprecated 2026-07-01, unsupported in 1.37+.
Adopting it would mean adopting a component with a known removal date.

**Workforce Identity Federation.** Not a substitute (see Context). Worth adopting
separately for human `kubectl` access to `gcp-0`.

**Do nothing and drop Headlamp from `gcp-0`.** Honest, and briefly tempting since
Grafana and Flux UI authenticate at the application layer and need nothing from
the API server. Rejected because "the cluster dashboard does not work on this
cloud" is exactly the kind of asymmetry this repository exists to remove.

## Consequences

- `gcp-0` gains a second ZITADEL OIDC client for the same hostname —
  `headlamp-proxy`, on `/oauth2/callback` — because the proxy, not Headlamp,
  now holds the client. `zitadel-oidc-clients.sh` creates it.
- The `headlamp-envvars` ExternalSecret still syncs on `gcp-0` and nothing reads
  it. Left in place rather than patched out of `base/`: it is inert, and removing
  it from the shared base would affect `aws-0`, which does read it.
- Widening the proxy's audience widens cluster-admin. `--allowed-group=admin` and
  the `headlamp` ServiceAccount's binding must be read together, and a reviewer
  changing one should look at the other.
- The `groups` claim now has a second consumer with different spelling.
  oauth2-proxy emits `X-Forwarded-Groups`; Headlamp's default is the singular
  `X-Forwarded-Group`, so the flag is set explicitly. Left at defaults the login
  succeeds with no groups and nothing logs an error.

## Related

- [ADR-0024](0024-identity-provider-per-cloud.md) — where ZITADEL *runs*; this
  record is about what the API server will *believe*, which ADR-0024 does not cover
- [ADR-0002](0002-eks-pod-identity-over-irsa.md) — the AWS identity model this
  diverges from
