---
title: Cilium
weight: 10
description: The eBPF data plane that replaces the CNI and kube-proxy, its non-default IPAM and encryption settings, and the startup trap that silently disables Gateway API.
lastVerified: 2026-08-20
---

Cilium is this platform's CNI, its kube-proxy replacement, and the Gateway
API data plane — one component doing all three jobs. It installs in Stage 2
of the [EKS bootstrap]({{< relref "/docs/platform/foundations/aws.md#why-eks-bootstrap-is-two-opentofu-stacks" >}}),
after Stage 1's temporary VPC-CNI and kube-proxy have already gotten the
nodes to `Ready`. None of what follows has a source document anywhere else
in the repository — it lives only in `CLAUDE.md`, Helm values comments, and
OpenTofu resource comments, and every item here has cost real debugging time
at least once.

## Replacing the CNI and kube-proxy

Stage 1 (`opentofu/aws/eks/init/main.tf`) installs the `vpc-cni` and `kube-proxy`
EKS addons with `before_compute = true` purely to get nodes `Ready` quickly;
both are already scheduled for replacement. One detail matters beyond that:
`vpc-cni` is configured with `WARM_ENI_TARGET=0` —

```hcl
vpc-cni = {
  before_compute = true
  most_recent    = true
  configuration_values = jsonencode({
    env = {
      WARM_ENI_TARGET = "0"
      WARM_IP_TARGET  = "1"
    }
  })
}
```

— because without it, VPC-CNI pre-warms secondary ENIs in the primary
`10.0.x.x` subnets, and Cilium reuses those instead of creating fresh ENIs in
the `100.64.x.x` pod subnets once it takes over.

Stage 2 (`opentofu/aws/eks/configure/main.tf`) then does three things in order,
each patching a DaemonSet's `nodeSelector` to an impossible label rather than
deleting the EKS addon — declarative, no `local-exec`:

1. `disable_vpc_cni` patches `aws-node` so it schedules on no nodes.
2. `helm_release.cilium` installs Cilium with `kubeProxyReplacement: true` —
   eBPF-based service routing replaces `kube-proxy` outright.
3. `disable_kube_proxy` patches the `kube-proxy` DaemonSet the same way.

Cilium's `operator.unmanagedPodWatcher` then restarts any pod not managed by
Cilium (CoreDNS, the EBS CSI driver, …) automatically, so no manual restart
step is needed after the CNI swap.

## IPAM: prefix delegation on the secondary CIDR

Pods draw their IPs from the secondary CIDR `100.64.0.0/16`, not from the
VPC's primary range, via AWS prefix delegation:

```yaml
# opentofu/aws/eks/init/helm_values/cilium.yaml
eni:
  enabled: true
  subnetTagsFilter:
    - "cilium.io/pod-subnet=true"
  awsEnablePrefixDelegation: true
ipam:
  mode: eni
routingMode: native
```

`subnetTagsFilter` is how Cilium finds the right subnets, and the tagging
rule is a hard trap: the `100.64.x.x` subnets **must not** carry the
`kubernetes.io/role/cni` tag —

```hcl
# opentofu/aws/network/network.tf
# NOTE: Do NOT add "kubernetes.io/role/cni" tag here!
"cilium.io/pod-subnet" = "true" # For future use when Cilium bug #43493 is fixed
```

— because VPC-CNI uses that tag for its own subnet discovery during Stage 1
bootstrap. Tag the pod subnets with it and VPC-CNI claims them too, creating
orphan ENIs the moment Cilium takes over in Stage 2. `cilium.io/pod-subnet=true`
is the only tag these subnets should carry.

Prefix delegation only benefits nodes **created after** Cilium is running.
Stage 1 bootstrap nodes predate it, so their ENIs get individually-allocated
secondary IPs and never convert — a permanent ceiling of roughly 42 pod IPs
per node. Prefix delegation gives a Karpenter-provisioned node several hundred
instead, comfortably more than the 100 pods its `EC2NodeClass` allows, so
there the `maxPods` limit binds first and IP supply never does. On a bootstrap
node the IPs run out well below that. See
[AWS Foundations]({{< relref "/docs/platform/foundations/aws.md#why-eks-bootstrap-is-two-opentofu-stacks" >}})
for the recycle step that works around it.

### The CNI ConfigMap and its manual `cniVersion`

Cilium reads its ENI settings (`first-interface-index`, `subnet-tags`,
`disable-prefix-delegation`) from a ConfigMap the platform owns,
`opentofu/aws/eks/configure/cilium-cni-config.tf`, referenced from the chart via
`cni.configMap: cilium-cni-configuration`. That has a consequence: **setting
`cni.configMap` means the chart's own `cniVersion` default never applies** —
this repository's ConfigMap is authoritative, so `cniVersion` has to be
bumped by hand on every Cilium minor that changes the CNI standard version
(Cilium 1.20 moved it `0.3.1` → `1.0.0`):

```hcl
"cni-config" = jsonencode({
  cniVersion = "1.0.0"
  name       = "cilium"
  plugins = [{
    cniVersion = "1.0.0"
    type       = "cilium-cni"
    eni = {
      "first-interface-index"     = 1
      "subnet-tags"               = { "cilium.io/pod-subnet" = "true" }
      "disable-prefix-delegation" = false
    }
  }]
})
```

There's no automated check for this drift — it's a line to remember on every
Cilium minor upgrade, not something CI catches.

## WireGuard is load-bearing, not an optimisation

{{< callout type="warning" >}}
Do not disable `encryption.type: wireguard`, and do not replace it with
ztunnel transparent encryption, while
[cilium#43493](https://github.com/cilium/cilium/issues/43493) is open. It is
the workaround for a routing bug, not a security nice-to-have.
{{< /callout >}}

```yaml
# opentofu/aws/eks/init/helm_values/cilium.yaml
encryption:
  enabled: true
  type: wireguard
```

Under native routing with ENI-mode prefix delegation, the BPF ipcache sets
the `hastunnel` flag incorrectly for remote pods — the Gateway API L7 proxy
(Envoy) then fails on cross-node backend connections. WireGuard's
node-to-node tunnels bypass that faulty routing logic; that's the actual
fix, and it's why encryption is enabled here for correctness, not primarily
for defense in depth.

This is AWS-specific. [ADR-0005]({{< relref "/docs/decisions/0005-gke-standard-self-managed-cilium.md" >}})
rescopes it for the GKE port: with `ipam.mode=kubernetes` there instead of
`eni`, the code path #43493 lives in is never taken, so WireGuard is expected
to be unnecessary there — pending the empirical cross-node L7 test that
confirms it.

## The Gateway API CRD startup-probe trap

`cilium-operator` probes for the Gateway API CRDs **exactly once, at
startup**. If any are missing, it logs `Required GatewayAPI resources are
not found`, permanently disables its Gateway API controller, and never
retries — no crash, no alert. Every `GatewayClass` then sits at
`Accepted=Unknown` ("Waiting for controller"), every `Gateway` stays
unprogrammed, `HTTPRoute`s get no `status.parents`, and any `App` claim that
owns a route is stuck `READY=False` — a failure that reads as a broken app,
not a missing CRD.

This isn't hypothetical: on 2026-08-19, Cilium 1.20's new requirement for
`backendtlspolicies` broke Gateway API on a rebuild because
`gateway_api_crds_urls` in `opentofu/aws/eks/configure/locals.tf` didn't have it
yet, and Flux's own CRD directory applied it two seconds too late for the
operator's one-shot probe to see.

**Recover**: `kubectl rollout restart -n kube-system deployment/cilium-operator`
reruns the probe. **Fix durably**: add the missing CRD's URL to
`gateway_api_crds_urls`. That list is append-only — the `count` index of the
existing entries must not shift, or `tofu` destroys and recreates every live
CRD, taking every Gateway and HTTPRoute with it. See
[Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}}) for
the resource model these CRDs back.

## Other gotchas worth knowing

- **`devices: "eth+ pod-id-link+"`** — explicit device list, so Cilium
  doesn't pick up `tailscale0`'s MTU by scanning all interfaces.
- **`socketLB.hostNamespaceOnly: true`** — required for Tailscale pods to
  work. When `false`, Cilium's socket load-balancer intercepts DNS inside
  pod network namespaces, which breaks anything that manipulates its own
  networking the way Tailscale does ([tailscale/tailscale#15478](https://github.com/tailscale/tailscale/issues/15478)).
- **`envoy.xdsMode` is deliberately left unset** so Cilium ≥ 1.20 picks its
  new default, `ads`, instead of the legacy `split` mode. Setting
  `upgradeCompatibility: "1.19"` anywhere would silently pin it back.

## Related

- [AWS Foundations]({{< relref "/docs/platform/foundations/aws.md" >}}) — the
  two-stage bootstrap this section assumes, and the node-recycle step for the
  prefix-delegation ceiling.
- [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}}) —
  the routing model Cilium implements as `io.cilium/gateway-controller`.
- [Private Access]({{< relref "/docs/platform/networking/private-access.md" >}}) —
  Tailscale's own interaction with this data plane.
