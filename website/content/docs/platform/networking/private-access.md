---
title: Private Access
weight: 30
description: The two Tailscale-backed Gateways, the ACL model that separates them, and the steps for exposing a new private service.
lastVerified: 2026-09-02
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

The rules live in `opentofu/shared/tailscale/main.tf` — a tailnet-wide
singleton stack, not a per-cloud one: there is exactly one ACL per tailnet,
and when it lived in the AWS network stack a second `tailscale_acl` anywhere
else would have silently overwritten it. They apply via the `tailscale_acl`
resource (default-deny — only what's listed here is permitted), with
`group:admin` populated from `var.admin_users`:

```hcl
acls = [
  { action = "accept", src = ["group:admin"],       dst = ["tag:admin:*"] },
  { action = "accept", src = ["autogroup:member"],  dst = ["tag:k8s:*"] },
  { action = "accept", src = ["tag:k8s-operator"],  dst = ["tag:k8s:*", "tag:admin:*"] },
  # plus: CI-tagged devices, one generated subnet-route accept rule per
  # cloud (below), and member-to-member — see the file for the full set.
]

tagOwners = {
  "tag:ci"           = [var.tailnet]
  "tag:k8s"          = ["tag:k8s-operator"]
  "tag:k8s-operator" = [var.tailnet]
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
    tailscale.com/hostname: "gateway-general-priv-${cluster_name}" # or gateway-admin-priv-${cluster_name}
    tailscale.com/tags: "tag:k8s"                                  # or tag:admin
    tailscale.com/funnel: "false"
```

The `-${cluster_name}` suffix is required, not decorative: the tailnet is
shared between `aws-0` and `gcp-0`, and a Tailscale hostname is
tailnet-unique. Two clusters claiming the same hostname doesn't error —
Tailscale silently suffixes the second device, so its MagicDNS name stops
being the one anything expects. `cluster_name` comes from each cluster's
Flux vars `ConfigMap`, substituted by `postBuild.substituteFrom` at reconcile
time — never hardcode a hostname here.

Both carry the `external-dns: enabled` label so ExternalDNS picks them up —
see [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md#externaldns" >}})
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

Back in the shared ACL stack, `var.advertised_routes` maps each cloud to its
CIDRs, and `opentofu/shared/tailscale/main.tf` generates from it both the
`autoApprovers.routes` entries that auto-approve each advertisement and one
`autogroup:member` accept rule per cloud (AWS and GCP alike), so any tailnet
member can route through either cloud's subnet router once its routes are
approved.

## Egress: a cluster reaching the other cloud's OpenBao

Pods are not tailnet devices, so a cluster consuming the *other* cloud's OpenBao
uses the Tailscale operator's **cluster egress**: an `ExternalName` Service
annotated `tailscale.com/tailnet-ip` with the active OpenBao's fixed NLB address
and `tailscale.com/proxy-group: ts-proxies` (`security/base/openbao-endpoint/remote`).
The operator rewrites the Service to its egress `ProxyGroup`, whose pods carry
the connection over the tailnet to the other cloud's subnet router. The ACL
admits `tag:k8s` to the advertised CIDRs on port 8200 for exactly this
(`opentofu/shared/tailscale/main.tf`). See
[OpenBao cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).

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
