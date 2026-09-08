---
title: Use Gateway API rather than Ingress
linkTitle: 0015 · Gateway API
weight: 150
description: Routing uses Gateway API rather than ingress-nginx, separating platform-owned Gateways from application-owned HTTPRoutes and serving public and Tailscale-private ingress from one CRD set — at the cost of version lockstep with Cilium.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow
**Related**: [ADR-0009](0009-cilium-over-vpc-cni.md) — Cilium is the
GatewayClass implementation this decision routes through

---

## Context

Every request into this platform, public or private, goes through Gateway
API — `GatewayClass`, `Gateway`, `HTTPRoute` — never a Kubernetes
`Ingress`. There is no `kind: Ingress` manifest anywhere in this
repository, and Cilium's own Ingress controller
(`ingressController.enabled`) is not turned on in
`opentofu/aws/eks/init/helm_values/cilium.yaml`; only `gatewayAPI.enabled:
true` is set. **Update (2026-08-30):** the one literal `ingress-nginx`
reference this record used to cite — a subchart toggle set to `enabled: false`
in the OnCall HelmRelease — is gone along
with the rest of the Grafana OnCall estate, removed 2026-08-29
([ADR-0029](0029-runlore-over-grafana-oncall.md)). Zero literal `ingress-nginx`
references remain anywhere in this repository's manifests.

[ADR-0009](0009-cilium-over-vpc-cni.md) already decided that Cilium
replaces the VPC CNI, kube-proxy, and the NetworkPolicy engine, and named
"implements the Gateway API `GatewayClass` this platform's Tailscale and
public ingress already depend on" as one of its reasons. That ADR's
Option 2 (`ingress-nginx`) was rejected mainly on CNI-consolidation
grounds — running a fifth component just for `NetworkPolicy`. This record
exists to state the routing-model choice on its own terms and name the
cost that choice carries by itself, independent of the CNI decision:
Gateway API's version is not free to move independently of Cilium's.

Three resource roles carry the model
([Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}})):
`GatewayClass` selects the controller, `Gateway` owns listeners,
hostnames, and TLS, and `HTTPRoute` owns routing rules and attaches to a
`Gateway` via `parentRefs`. The platform authors every `Gateway` under
`infrastructure/base/gapi/` (the AWS-only public Gateway lives in
`infrastructure/aws-0/gapi/` instead — see Implementation Notes); applications
own their `HTTPRoute` through
the `App` Crossplane claim. An `Ingress` has no equivalent split — one
object carries both concerns, disambiguated only by vendor-specific
annotations.

---

## Decision Drivers

- **Role separation.** The platform should own listener/TLS/hostname
  configuration; applications should own routing rules. Mixing both into
  one `Ingress` object, disambiguated by annotations, does not offer that
  split.
- **One mechanism for both public and private ingress.** The two
  Tailscale-private Gateways (`platform-tailscale-general`,
  `platform-tailscale-admin`) need `loadBalancerClass: tailscale` on the
  Service Cilium creates for them — a `CiliumGatewayClassConfig`
  `parametersRef` on the `GatewayClass`. Reaching the same outcome through
  `Ingress` would need a second mechanism, since Cilium's own Ingress
  controller is not enabled here at all.
- **No new controller.** [ADR-0009](0009-cilium-over-vpc-cni.md) already
  requires Cilium as the CNI and `CiliumNetworkPolicy` engine; adopting
  Gateway API turns Cilium's existing `gatewayAPI.enabled: true` setting
  into the ingress mechanism too, rather than installing a separate
  controller alongside it.
- **Native ExternalDNS integration.** ExternalDNS's `gateway-httproute`
  source watches `HTTPRoute` objects directly
  (`infrastructure/base/external-dns/helmrelease.yaml`), so a new hostname
  needs no separate annotation convention.

---

## Considered Options

### Option 1: Gateway API with Cilium as the GatewayClass implementation

Two `GatewayClass`es back three `Gateway`s. `cilium` is created
automatically once `gatewayAPI.enabled: true` is set in the Cilium Helm
values (no manifest for it in this repository); `cilium-tailscale` is
hand-authored in `infrastructure/base/gapi/tailscale-gatewayclass.yaml`
with a `parametersRef` to a `CiliumGatewayClassConfig`. `platform-public`
uses `cilium`; `platform-tailscale-general` and `platform-tailscale-admin`
use `cilium-tailscale`.

**Pros**:
- Platform-owned `Gateway`, application-owned `HTTPRoute` — no per-app
  vendor annotations to keep aligned with a shared object.
- One CRD family covers both the internet-facing gateway and the two
  Tailscale-private gateways; only the `GatewayClass` differs.
- Cilium already runs as the CNI and `NetworkPolicy` engine
  ([ADR-0009](0009-cilium-over-vpc-cni.md)); turning on `gatewayAPI`
  adds no separate controller.
- ExternalDNS's `gateway-httproute` source watches `HTTPRoute` natively.

**Cons**:
- The Gateway API CRD version cannot move independently of the Cilium
  minor installed — see Consequences.
- `cilium-operator` only detects new Gateway API CRDs at its own startup
  — see Consequences.
- Smaller ecosystem than `Ingress`: fewer worked examples, and some
  upstream charts still ship only an `ingress:` values stanza with no
  Gateway API templates (the since-removed OnCall HelmRelease —
  [ADR-0029](0029-runlore-over-grafana-oncall.md) — disabled both `ingress`
  and a bundled `ingress-nginx` subchart it shipped with no alternative).

### Option 2: ingress-nginx

The mature, widely deployed `Ingress` controller
[ADR-0009](0009-cilium-over-vpc-cni.md) already considered and rejected
as its Option 2.

**Pros** (per ADR-0009's Option 2):
- Fully community-supported, large install base.

**Cons**:
- Speaks `Ingress`, not `GatewayClass` — does not satisfy this platform's
  Gateway-API-only routing model without a shim
  ([ADR-0009](0009-cilium-over-vpc-cni.md) Option 2).
- No mechanism comparable to `CiliumGatewayClassConfig`'s
  `loadBalancerClass: tailscale` for the two private gateways; reaching
  them through `Ingress` would need a second, ingress-nginx-specific
  path, not the one CRD family Option 1 uses for all three Gateways.

### Option 3: AWS Load Balancer Controller `Ingress`

The AWS Load Balancer Controller does run in this repository
(`infrastructure/base/aws-load-balancer-controller/helmrelease.yaml`,
chart `aws-load-balancer-controller`), but not as an `Ingress`
controller: no manifest under `infrastructure/`, `tooling/`,
`observability/`, `security/`, or `apps/` sets `ingressClassName` or an
`alb.ingress.kubernetes.io/*` annotation, and no `kind: Ingress` object
exists anywhere in the repository. Its actual job is provisioning the AWS
NLB behind the one internet-facing `Gateway`, `platform-public`, whose
`service.beta.kubernetes.io/aws-load-balancer-*` annotations sit under
`Gateway.spec.infrastructure.annotations`
(`infrastructure/aws-0/gapi/platform-public-gateway.yaml`) rather than on
an `Ingress` object.

**Pros**:
- Deep AWS integration for the load balancer itself (NLB target type,
  scheme, naming) — already used today, just attached to a `Gateway`
  instead of an `Ingress`.

**Cons**:
- Running it as an `Ingress` controller reintroduces the same
  role-separation loss as Option 2: listener and routing configuration
  merge into one object, disambiguated by `alb.ingress.kubernetes.io/*`
  annotations instead of Cilium/Tailscale ones.
- Still no equivalent to `CiliumGatewayClassConfig`'s
  `loadBalancerClass: tailscale` for the two private gateways — AWS LBC
  provisions AWS load balancers, not Tailscale-backed Services, so the
  Tailscale gateways would still need a wholly separate mechanism.

---

## Decision Outcome

**Chosen option**: "Option 1 — Gateway API with Cilium as the
GatewayClass implementation"

**Rationale**: Cilium is already required for the CNI, kube-proxy
replacement, and `NetworkPolicy` engine
([ADR-0009](0009-cilium-over-vpc-cni.md)), and it already ships a
`GatewayClass` implementation gated by one Helm value. Adopting Gateway
API is therefore not a new component, it is switching on a capability
Cilium already has, while Option 2 and Option 3 would each add one.
Gateway API's role split also lets `CiliumGatewayClassConfig` carry the
`loadBalancerClass: tailscale` setting the two private Gateways depend
on, through the same `GatewayClass`/`Gateway`/`HTTPRoute` triple used for
the public Gateway — neither `ingress-nginx` nor AWS Load Balancer
Controller's `Ingress` mode has a comparable path to that outcome without
a second, ingress-specific mechanism bolted on for the private case. The
cost is real and is not shared with the CNI decision: this platform's
Gateway API CRD version is now pinned to what the installed Cilium minor
can run, not chosen freely.

---

## Consequences

### Positive

- The platform owns every `Gateway` (`infrastructure/base/gapi/`, plus the
  AWS-only `platform-public` Gateway in `infrastructure/aws-0/gapi/`);
  applications own their `HTTPRoute` through the `App` claim — no vendor
  annotations on a shared object to keep in sync.
- One CRD family serves all three Gateways: `platform-public` (internet
  facing, `cilium`), `platform-tailscale-general` and
  `platform-tailscale-admin` (Tailscale-private, `cilium-tailscale`).
- No separate ingress controller to operate — Cilium implements
  `GatewayClass` as part of the component
  [ADR-0009](0009-cilium-over-vpc-cni.md) already requires.
- ExternalDNS's `gateway-httproute` source
  (`infrastructure/base/external-dns/helmrelease.yaml`) watches
  `HTTPRoute` directly and, with `policy: sync`, removes Route53 records
  when a route is deleted — no manual DNS step.

### Negative

- **Version lockstep with Cilium.** Cilium is the `GatewayClass`
  implementation, so the Gateway API CRD version cannot move
  independently of it: Cilium ≤1.19.4 crashes on Gateway API ≥v1.5.0
  (TLSRoute-v1, [cilium#45139](https://github.com/cilium/cilium/issues/45139),
  fixed in 1.19.5). `gateway_api_version` lives beside `cilium_version` in
  `opentofu/config.tm.hcl`'s `globals` and is passed to both clouds'
  `configure` stacks by `-var`, so the two clusters cannot diverge. It must
  equal the tag `flux/sources/gitrepo-gateway-api.yaml` pins Flux's
  `GitRepository` to — both currently `v1.6.2` — while the installed
  `cilium_version` (also `opentofu/config.tm.hcl`, currently `1.20.1`) must
  stay at or above the 1.19.5 floor.
  - *Mitigation*: those two pins are checked against each other by the
    `gateway-api-version` claim in `.doc-claims.yaml`
    (`./scripts/validate-doc-claims.sh`), so a bump that misses one fails
    CI. The Cilium floor is still a manual check on every upgrade of either
    component.
- **CRDs must exist before `cilium-operator` starts.** It probes for the
  Gateway API CRDs exactly once, at startup, and permanently disables its
  Gateway API controller for the process lifetime if any is missing — no
  crash, no alert. Every `GatewayClass` then sits at `Accepted=Unknown`,
  every `Gateway` stays unprogrammed, every `HTTPRoute` gets no
  `status.parents`, and any `App` claim that owns a route is stuck
  `READY=False` (`CLAUDE.md`, "Gateways stuck `Waiting for controller`").
  This already happened once: `backendtlspolicies` was absent from the
  hand-written CRD list and broke Gateway API on the 2026-08-19 rebuild. The
  list, and the comment that recorded the incident, are both gone — see
  `opentofu/shared/modules/gateway-api-crds/main.tf`.
  - *Mitigation*: `kubectl rollout restart -n kube-system
    deployment/cilium-operator` reruns the probe immediately. Durably, that
    enumeration was retired — both clouds install the whole
    experimental-channel bundle via `opentofu/shared/modules/gateway-api-crds`,
    so the installed set cannot be a subset of what Cilium probes for.
- **Smaller ecosystem than `Ingress`.** Fewer worked examples exist for
  Gateway API than for `Ingress`, and some upstream charts still ship
  only an `ingress:` values stanza with no Gateway API template —
  the OnCall HelmRelease (removed 2026-08-29 with the estate,
  [ADR-0029](0029-runlore-over-grafana-oncall.md)) turned off both an
  `ingress:` stanza and a bundled `ingress-nginx` subchart the chart
  offered as its only routing option.
  - *Mitigation*: none beyond authoring a standalone `HTTPRoute` next to
    such a chart, as `tooling/base/homepage/httproute.yaml` already does.

### Neutral

- Moving from `Ingress` to Gateway API did not remove the AWS Load
  Balancer Controller from the platform. `platform-public` still gets its
  internet-facing NLB from `aws-load-balancer-controller`
  (`infrastructure/base/aws-load-balancer-controller/helmrelease.yaml`);
  only the object carrying the AWS annotations changed, from an
  `Ingress` to `Gateway.spec.infrastructure.annotations`.

---

## Implementation Notes

`infrastructure/base/gapi/` holds the `GatewayClass`/`CiliumGatewayClassConfig`
plumbing and the two Tailscale `Gateway` manifests:
`tailscale-gatewayclass.yaml` (the `cilium-tailscale` `GatewayClass`),
`tailscale-gatewayclass-config.yaml` (the `CiliumGatewayClassConfig`
setting `service.type: LoadBalancer`, `loadBalancerClass: tailscale`, and
JSON Envoy access logs via `spec.telemetry.accessLogs`), and the two
Tailscale `Gateway` manifests, which restrict `allowedRoutes` to a namespace
allowlist that has to be kept in sync by hand.
**Update (2026-08-30):** the third `Gateway`, `platform-public-gateway.yaml`,
moved to `infrastructure/aws-0/gapi/` on 2026-08-27 — it carries
`service.beta.kubernetes.io/aws-load-balancer-*` annotations and a
`${domain_name}`-built hostname that a GCP cluster's vars ConfigMap does not
define, so leaving it in `base/` risked both clusters referencing it and GCP
silently rendering an empty hostname. It still restricts `allowedRoutes` to
the `runlore` namespace and carries the AWS NLB annotations, unchanged from
what this record originally described.

Cilium's Gateway API support is turned on entirely through Helm values in
`opentofu/aws/eks/init/helm_values/cilium.yaml`: `gatewayAPI.enabled: true`
and `envoy.enabled: true` (the L7 proxy). `ingressController` is not set,
so Cilium's own `Ingress` support stays off.

The Gateway API CRDs themselves are not chart-managed: `flux/sources/gitrepo-gateway-api.yaml`
pins a `GitRepository` to `kubernetes-sigs/gateway-api` tag `v1.6.2`, and
`opentofu/shared/modules/gateway-api-crds` installs the same-versioned
experimental-channel bundle — every CRD in the release, `backendtlspolicies` and
`listenersets` included — before Cilium's Stage 2 install, so
`cilium-operator`'s startup probe finds them. Both clouds use that one module,
so the two clusters cannot present Cilium with different Gateway API surfaces.

---

## References

- [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}})
  — the resource model, the three Gateways, TLS, and ExternalDNS
  integration this ADR summarizes
- [ADR-0009](0009-cilium-over-vpc-cni.md) — Cilium as the CNI and
  `GatewayClass` implementation this decision depends on
- [CLAUDE.md](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md)
  — "Gateways stuck `Waiting for controller`" troubleshooting entry
- `opentofu/shared/modules/gateway-api-crds` — the bundle install both
  clouds use, and the `backendtlspolicies` incident that motivated it
- `opentofu/aws/eks/configure/variables.tf` — `gateway_api_version`
- `flux/sources/gitrepo-gateway-api.yaml` — the Flux `GitRepository` pin
  that must match `gateway_api_version`
- `opentofu/aws/eks/init/helm_values/cilium.yaml` — `gatewayAPI.enabled`,
  `envoy.enabled`
- `infrastructure/base/gapi/` — every `GatewayClass`,
  `CiliumGatewayClassConfig`, and the two Tailscale `Gateway` manifests
- `infrastructure/aws-0/gapi/` — `platform-public-gateway.yaml`, moved out of
  `base/` 2026-08-27 for carrying AWS-only annotations
- `infrastructure/base/external-dns/helmrelease.yaml` — the
  `gateway-httproute` source and `policy: sync`
- [cilium#45139](https://github.com/cilium/cilium/issues/45139) — the
  Cilium ≤1.19.4 crash on Gateway API ≥v1.5.0 behind the version lockstep
