---
title: Private Access
weight: 30
description: The two Tailscale-backed Gateways, the ACL model that separates them, and the steps for exposing a new private service.
lastVerified: 2026-08-20
---

Every private service in this platform (`*.priv.aws.ogenki.io`) is reached
through one of two [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}})
`Gateway`s backed by Tailscale — no bastion host, no public IP with an
allowlist. Access control is enforced by **Tailscale ACLs**, evaluated
outside Kubernetes entirely, not by anything a claim or an `HTTPRoute` can
change. This page covers that ACL model, how it wires into the two Gateways,
and how to expose a new service through them.

## Two gateways, one ACL model

- **`platform-tailscale-general`** (`tag:k8s`) — reachable by every member
  of the tailnet.
- **`platform-tailscale-admin`** (`tag:admin`) — reachable only by
  `group:admin`.

The rules live in `opentofu/aws/network/tailscale.tf`, applied via the
`tailscale_acl` resource (default-deny — only what's listed here is
permitted):

```hcl
acls = [
  { action = "accept", src = ["group:admin"],        dst = ["tag:admin:*"] },
  { action = "accept", src = ["autogroup:member"],    dst = ["tag:k8s:*"] },
  { action = "accept", src = ["tag:k8s-operator"],    dst = ["tag:k8s:*", "tag:admin:*"] },
  # plus: CI-tagged devices, VPC access via the subnet router (below), and
  # member-to-member — see the file for the full set.
]

tagOwners = {
  "tag:k8s"          = ["tag:k8s-operator"]
  "tag:k8s-operator" = [var.tailscale_config.tailnet]
  "tag:admin"        = ["tag:k8s-operator"]
}
```

`tagOwners` is what actually enforces the split: both `tag:k8s` and
`tag:admin` can only be applied by `tag:k8s-operator` — the Tailscale
Kubernetes Operator. No human, and no other automation, can self-tag a
device into either group; the operator is the sole authority deciding which
Gateway a device becomes.

## Wiring: from ACL tag to Gateway

A `CiliumGatewayClassConfig` sets the LoadBalancer type both Gateways share:

```yaml
# infrastructure/base/gapi/tailscale-gatewayclass-config.yaml
spec:
  service:
    type: LoadBalancer
    loadBalancerClass: tailscale
  telemetry:
    accessLogs:
      - format: JSON
        targets: ["HTTP"]
```

(`telemetry.accessLogs` needs Cilium ≥ 1.19.6; it's what feeds the
Gateways' Envoy access logs into VictoriaLogs.) The `cilium-tailscale`
`GatewayClass` references this config via `parametersRef`, and each Gateway
sets its own Tailscale tag directly through `infrastructure.annotations`:

```yaml
# platform-tailscale-general-gateway.yaml / platform-tailscale-admin-gateway.yaml
infrastructure:
  annotations:
    tailscale.com/hostname: "gateway-general-priv" # or gateway-admin-priv
    tailscale.com/tags: "tag:k8s"                  # or tag:admin
    tailscale.com/funnel: "false"
```

Both carry the `external-dns: enabled` label so ExternalDNS picks them up —
see [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md#externaldns-and-route53" >}})
for that mechanism. What differs between them beyond the tag is
`allowedRoutes`, which namespace-scopes what can attach:

| Gateway | Namespaces allowed |
|---|---|
| `platform-tailscale-general` | `apps`, `demo`, `envoy-ai-gateway-system`, `envoy-gateway-system`, `observability`, `tooling` |
| `platform-tailscale-admin` | `kube-system`, `observability`, `flux-system` |

`kube-system` on the admin list is why Hubble UI — a plain `Service` in
`kube-system` — reaches `hubble-ui-<cluster>.priv.aws.ogenki.io` through a
normal `HTTPRoute` parented to `platform-tailscale-admin`
(`infrastructure/base/cilium/hubble-ui-httproute.yaml`), rather than through
its own dedicated Tailscale device. That's the pattern for everything behind
these two Gateways now — a per-service `tailscale.com/expose`d `Service`
with its own Tailscale device isn't used anywhere in this repository.
Getting the namespace list wrong rejects the route entirely; see
[Gateway API's `allowedRoutes` trap]({{< relref "/docs/platform/networking/gateway-api.md#allowedroutes-is-a-namespace-allowlist--and-a-real-trap" >}}).

## Adding a new private service

1. Decide general or admin by sensitivity — general for anything any
   tailnet member should reach, admin for operational tooling.
2. Create an `HTTPRoute` in a namespace the target Gateway already allows
   (see the table above):

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: HTTPRoute
   metadata:
     name: myapp
     namespace: apps
   spec:
     parentRefs:
       - name: platform-tailscale-general
         namespace: infrastructure
     hostnames:
       - "myapp.priv.aws.ogenki.io"
     rules:
       - backendRefs:
           - name: myapp
             port: 8080
   ```

3. DNS is automatic — ExternalDNS creates the Route53 record within its
   sync interval, no manual step.
4. Verify from a Tailscale-connected device: `curl -v https://myapp.priv.aws.ogenki.io`.

If the namespace isn't in the Gateway's `allowedRoutes` selector yet, this
fails `NotAllowedByListeners` and needs the Gateway manifest updated first.

## The subnet router: reaching the VPC itself

The two Gateways expose Kubernetes services. Reaching the VPC directly —
`kubectl` against the private EKS API endpoint, `bao` against OpenBao's
Raft peers — goes through a separate mechanism: a Tailscale subnet router,
an EC2 instance provisioned by `opentofu/aws/network/tailscale.tf` via the
`Smana/tailscale-subnet-router/aws` module, advertising the VPC CIDR:

```hcl
module "tailscale_subnet_router" {
  source            = "Smana/tailscale-subnet-router/aws"
  advertise_routes  = [module.vpc.vpc_cidr_block]
  tailscale_ssh_enabled = true
  # t3.micro: deliberate, not the module's t3a.micro default — see the
  # module block's comment for the capacity reasoning.
}
```

The ACL's `autoApprovers.routes` entry auto-approves that advertisement for
the tailnet, and `autogroup:member -> 10.0.0.0/16:*` is the accept rule that
lets any tailnet member actually route through it once approved.

## Verification

```bash
# Both Gateways PROGRAMMED=True with Tailscale addresses
kubectl get gateway -n infrastructure

# HTTPRoutes attached to a given Gateway
kubectl get httproute -A -o json | \
  jq -r '.items[] | select(.spec.parentRefs[]? | select(.name == "platform-tailscale-admin")) |
  "\(.metadata.namespace)/\(.metadata.name): \(.spec.hostnames[])"'
```

## Troubleshooting

**Gateway never gets a Tailscale address** — check the operator itself:
`kubectl get pods -n tailscale`. If it's running and the Gateway still has
no address, check the `cilium-tailscale` `GatewayClass` status — this is
often the [Cilium Gateway API CRD startup trap]({{< relref "/docs/platform/networking/cilium.md#the-gateway-api-crd-startup-probe-trap" >}})
rather than anything Tailscale-specific.

**Can't reach a private hostname at all** — confirm the device is actually
on the tailnet (`tailscale status`) and that its ACL tag matches the
Gateway: a `tag:k8s`-only device cannot reach `platform-tailscale-admin`
services regardless of DNS resolving correctly, by design.

**`HTTPRoute` created but traffic doesn't reach it** — see
[Gateway API's troubleshooting section]({{< relref "/docs/platform/networking/gateway-api.md#troubleshooting" >}})
for `allowedRoutes` and L7-proxy network-policy causes.

## Related

- [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}}) —
  the `HTTPRoute`/`allowedRoutes` model these Gateways enforce.
- [Cilium]({{< relref "/docs/platform/networking/cilium.md" >}}) — why
  WireGuard has to stay enabled for the Gateways' cross-node routing to work.
