---
title: Gateway API
weight: 20
description: The GatewayClass/Gateway/HTTPRoute model this platform routes with, the three Gateways it runs, and how TLS and DNS attach to them.
lastVerified: 2026-08-20
---

Every request into this platform — public or private — goes through Gateway
API, never a Kubernetes `Ingress`. Cilium implements the controller
(`io.cilium/gateway-controller`, see [Cilium]({{< relref "/docs/platform/networking/cilium.md" >}}));
this page covers the resource model and the three Gateways built on it.
Where certificates come from is [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}) —
this page only covers how they attach at the listener.

## The resource model

Three roles, three resources:

- **`GatewayClass`** — which controller handles a Gateway. Two exist in this
  platform: `cilium`, created automatically once `gatewayAPI.enabled: true`
  is set in the Cilium Helm values (no manifest for it in-repo), and
  `cilium-tailscale`, hand-authored in `infrastructure/base/gapi/tailscale-gatewayclass.yaml`
  because it needs a `parametersRef` to a `CiliumGatewayClassConfig`. A third
  class, `envoy-ai-gateway`, coexists for the opt-in LLM platform's own
  data plane and is out of scope here.
- **`Gateway`** — listeners, hostnames, and TLS, owned by the platform.
  Every Gateway in this repository lives in the `infrastructure` namespace
  and is defined under `infrastructure/base/gapi/`.
- **`HTTPRoute`** — routing rules, owned by whatever creates the backend
  Service. `HTTPRoute`s attach to a Gateway via `parentRefs` and only take
  effect if the Gateway's `allowedRoutes` permits the route's namespace.

## The three Gateways

| Gateway | `GatewayClass` | Purpose |
|---|---|---|
| `platform-tailscale-general` | `cilium-tailscale` | Private services open to every Tailscale member — see [Private Access]({{< relref "/docs/platform/networking/private-access.md" >}}) |
| `platform-tailscale-admin` | `cilium-tailscale` | Private services restricted to `group:admin` — see [Private Access]({{< relref "/docs/platform/networking/private-access.md" >}}) |
| `platform-public` | `cilium` | The few endpoints that must be internet-reachable |

`platform-public` (`infrastructure/base/gapi/platform-public-gateway.yaml`)
is deliberately narrow, not a general-purpose public entry point. Today its
only consumer is `runlore`'s Slack interactivity callback — Slack posts
button clicks from Slack's own servers, so a private Tailscale gateway can't
carry them. The exposure is bounded by construction: `allowedRoutes`
restricts attachment to the `runlore` namespace only, the `HTTPRoute` itself
matches exactly one path and method, and every request that reaches the app
is HMAC-verified against the Slack signing secret. TLS terminates from
`cert-manager`'s `letsencrypt-prod` `ClusterIssuer` (a public CA — this is
the one Gateway that does **not** use OpenBao's private PKI), and the AWS
Load Balancer annotations on `infrastructure.annotations` make it an
internet-facing NLB rather than the Tailscale `loadBalancerClass` the other
two use.

### `allowedRoutes` is a namespace allowlist — and a real trap

Both Tailscale Gateways restrict `allowedRoutes` to a `matchExpressions`
namespace selector, not a wildcard:

```yaml
# infrastructure/base/gapi/platform-tailscale-general-gateway.yaml
allowedRoutes:
  namespaces:
    from: Selector
    selector:
      matchExpressions:
        - key: kubernetes.io/metadata.name
          operator: In
          values:
            - apps
            - demo
            - envoy-ai-gateway-system
            - envoy-gateway-system
            - observability
            - tooling
```

Every namespace an `App` claim can target must be listed here, or its
`HTTPRoute` is rejected `NotAllowedByListeners` and the `App` XR never goes
`Ready` — the workload itself runs fine, only the route is refused, so it
reads as a broken application rather than a Gateway ACL. This list has to
stay in lockstep with wherever claims actually land; there is no automation
that keeps them in sync today.

## TLS termination

A Gateway listener references a `Secret` that `cert-manager` keeps
populated — it doesn't request or manage certificates itself:

```yaml
listeners:
  - name: https
    port: 443
    protocol: HTTPS
    tls:
      mode: Terminate
      certificateRefs:
        - name: private-gateway-tls
```

Both Tailscale Gateways share the same wildcard `Secret`
(`private-gateway-tls`, from the `Certificate` in
`infrastructure/base/gapi/platform-private-gateway-certificate.yaml`), so
when `cert-manager` renews it, both Gateways pick up the new certificate
without a redeploy — no coordination needed between them. See
[PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}})
for the certificate chain, the `ClusterIssuer`, and rotation.

## ExternalDNS and Route53

ExternalDNS watches Gateways and `HTTPRoute`s (`sources: [service, ingress,
gateway-httproute]` in `infrastructure/base/external-dns/helmrelease.yaml`)
and creates matching Route53 records automatically — no manual DNS step for
a new hostname. Two settings keep it scoped correctly:

- `--gateway-label-filter=external-dns=enabled` — only Gateways carrying
  the `external-dns: enabled` label are watched, which is why every Gateway
  manifest in this repository sets that label.
- `zoneMatchParent: false` — prefers the more specific hosted zone, so a
  `*.priv.aws.ogenki.io` hostname lands in the private zone rather than
  the public `cloud.ogenki.io` parent zone it would otherwise also match.

`policy: sync` means ExternalDNS also **deletes** records when their
`HTTPRoute` is deleted, not just creates them. IAM comes from EKS Pod
Identity, per the [platform constitution]({{< relref "/docs/reference/platform-constitution.md#4-iam-conventions" >}}) —
no static AWS credentials.

## Routing rules

Beyond a plain `PathPrefix` match, `HTTPRoute` supports header matching and
weighted `backendRefs` for canary-style traffic splits — standard Gateway
API capability, not something this repository extends. Nothing here is
platform-specific enough to be worth its own example; see the
[Gateway API HTTPRoute reference](https://gateway-api.sigs.k8s.io/api-types/httproute/)
for the full matching and weighting syntax.

## Troubleshooting

**Gateway stuck `Waiting for controller` / `GatewayClass ACCEPTED=Unknown`**
— almost always the Cilium operator's one-shot Gateway API CRD probe; see
[Cilium]({{< relref "/docs/platform/networking/cilium.md#the-gateway-api-crd-startup-probe-trap" >}}).

**`HTTPRoute` has no `status.parents`, or shows `NotAllowedByListeners`** —
the route's namespace isn't in the parent Gateway's `allowedRoutes` selector
(see above), or the hostname doesn't match a listener's `hostname` pattern.

**503 `upstream connect error ... connection timeout` from a service behind
a Gateway** — the Cilium Gateway API L7 proxy (Envoy) connects to backend
pods using the `reserved:ingress` identity, which a standard
`CiliumNetworkPolicy` cannot select via `podSelector`/`namespaceSelector`.
A namespace with its own default-deny policy (`flux-system`, `runlore` today)
needs an explicit `fromEntities: [ingress]` allow —
`infrastructure/base/gapi/allow-gateway-l7-proxy.yaml` is that policy, scoped
by namespace rather than `endpointSelector: {}` so it doesn't also open up
unrelated pods like Kyverno's admission webhook. See
[Policies]({{< relref "/docs/platform/security/policies.md" >}}) for the
default-deny model this works around.

**Certificate not issued / Gateway has no TLS** — see
[PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}).

## Related

- [Cilium]({{< relref "/docs/platform/networking/cilium.md" >}}) — the
  controller implementing all of this.
- [Private Access]({{< relref "/docs/platform/networking/private-access.md" >}}) —
  how the two Tailscale Gateways enforce access control.
- [PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md" >}}) —
  where the certificates these listeners reference come from.
