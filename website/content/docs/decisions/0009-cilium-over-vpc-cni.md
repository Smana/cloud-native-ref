---
title: Use Cilium instead of the AWS VPC CNI
linkTitle: 0009 · Cilium over VPC CNI
weight: 90
description: Cilium replaces the VPC CNI, kube-proxy, the NetworkPolicy engine and the ingress controller with one eBPF datapath — at the cost of a load-bearing WireGuard workaround and a manual CNI-version bump per minor release.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow
**Related**: [ADR-0015](0015-gateway-api-over-ingress-nginx.md) — the
Gateway API decision that routes through this ADR's `GatewayClass`

---

## Context

A default EKS cluster ships four networking concerns as four separate
pieces: the VPC CNI for pod IPs, kube-proxy for Service routing, no
NetworkPolicy enforcement at all unless a policy engine is bolted on, and
no ingress mechanism beyond whatever load balancer controller gets
installed on top. This platform needs all four, and needs them to satisfy
constraints the default stack does not: Gateway API as the only ingress
mechanism (no `Ingress` objects anywhere), default-deny
`CiliumNetworkPolicy` on every pod-running workload as a constitution
requirement, and enough pod IP headroom per node to run production
workloads without exhausting the primary ENI's address space.

The EKS bootstrap already has to be two OpenTofu stages for an unrelated
reason (the Helm provider needs a live cluster endpoint at plan time), so
whichever CNI is chosen installs in Stage 2, after Stage 1's temporary
VPC-CNI and kube-proxy have already gotten the nodes to `Ready`. That
sequencing is not this decision's cost — it exists regardless of which CNI
Stage 2 installs. What is this decision is *which* component takes over
from there, and how much of the rest of the networking stack it can absorb
in the same move.

---

## Decision Drivers

- **One eBPF datapath instead of four stacked components** — CNI,
  kube-proxy, NetworkPolicy enforcement, and the Gateway API/ingress
  controller each bolted on separately multiplies the number of moving
  parts and the surface between them that can drift out of sync.
- **Gateway API as the platform's only ingress mechanism**, which needs a
  `GatewayClass` implementation, not just a `Service`-routing CNI.
- **Default-deny `CiliumNetworkPolicy` on every pod-running workload** is a
  platform constitution requirement, not optional hardening.
- **Flow-level network observability** for debugging GitOps-reconciled
  workloads without SSH access to nodes.
- **Pod IP headroom per node** at the density this platform's node groups
  and Karpenter-provisioned nodes actually run.

---

## Considered Options

### Option 1: Cilium

eBPF-based CNI, kube-proxy replacement, NetworkPolicy engine, and Gateway
API `GatewayClass` implementation, installed as a `helm_release` in Stage
2 after Stage 1's VPC-CNI and kube-proxy are patched out.

**Pros**:
- Replaces four separately-operated components — VPC CNI, kube-proxy, a
  NetworkPolicy engine, and an ingress controller — with one eBPF
  datapath and one Helm release to operate.
- Native routing with pod IPs drawn from a secondary CIDR via AWS prefix
  delegation, decoupling pod density from the primary ENI's address
  space.
- Hubble gives flow-level observability the VPC CNI has no equivalent
  for — `hubble observe` against live traffic, without shelling into a
  node.
- Implements the Gateway API `GatewayClass` this platform's Tailscale and
  public ingress already depend on.

**Cons**:
- eBPF native routing under AWS ENI-mode prefix delegation carries an
  open upstream bug affecting the Gateway API L7 proxy — see
  Consequences.
- The platform now owns a CNI ConfigMap that has to be tracked by hand
  against Cilium's own release notes.

### Option 2: AWS VPC CNI + kube-proxy + ingress-nginx

The default EKS networking stack, left as-is, with a conventional ingress
controller added on top for north-south traffic.

**Pros**:
- Fully AWS-supported CNI and Service routing; no platform-owned CNI
  ConfigMap to track.
- ingress-nginx is a mature, widely deployed ingress controller with a
  large community.

**Cons**:
- No NetworkPolicy enforcement out of the box — a fifth component would
  be needed to satisfy the constitution's default-deny requirement.
- ingress-nginx speaks `Ingress`, not `GatewayClass` — it does not
  satisfy the platform's Gateway-API-only ingress model without a
  Gateway API shim, and has no comparable relationship to the
  `CiliumGatewayClassConfig`/Tailscale `loadBalancerClass` mechanism this
  platform's private access depends on.
- No flow-level observability equivalent to Hubble; debugging falls back
  to VPC Flow Logs and node-level tooling.

### Option 3: VPC CNI with Cilium in chaining mode

Cilium layered on top of the VPC CNI for NetworkPolicy enforcement only,
leaving IP address management and Service routing to the VPC CNI and
kube-proxy.

**Pros**:
- Narrower blast radius: Cilium owns only policy enforcement, so a
  Cilium misconfiguration cannot take down pod networking outright.
- No prefix-delegation IPAM to reason about — IP assignment stays fully
  on the VPC CNI's existing path.

**Cons**:
- Still runs kube-proxy and the VPC CNI as separate, separately-upgraded
  components — none of the operational consolidation Option 1 buys.
- Chaining mode does not provide the Gateway API `GatewayClass`
  implementation this platform's ingress model requires; a fourth
  component would still be needed for that.
- Two IPAM-adjacent code paths (VPC CNI's own ENI management plus
  Cilium's policy layer watching the same pods) is a wider debugging
  surface than either component alone.

---

## Decision Outcome

**Chosen option**: "Option 1 — Cilium"

**Rationale**: This platform's ingress model (Gateway API only, two
Tailscale-backed private Gateways with ACL separation) and its security
model (default-deny `CiliumNetworkPolicy` everywhere) both assume Cilium
is present — neither Option 2 nor Option 3 delivers the `GatewayClass`
implementation those Gateways attach to. Once Cilium is required for
ingress and policy anyway, letting it also replace the VPC CNI and
kube-proxy removes two more components rather than running Cilium
alongside them. That consolidation is real, but it is not free: it moves
an open upstream routing bug, a manually-tracked CNI config version, and a
node-density ceiling with a sharp edge onto this platform's own operating
surface. Those costs are recorded in full below, not glossed over — this
is the highest-blast-radius infrastructure choice in the platform, and the
one most tempting to write up as a pure win.

---

## Consequences

### Positive

- One eBPF datapath replaces four separately-operated pieces: the VPC
  CNI, kube-proxy, a NetworkPolicy engine, and the ingress controller
  (as the Gateway API `GatewayClass` implementation).
- Native routing with pod IPs drawn from the secondary CIDR
  `100.64.0.0/16` via AWS prefix delegation, instead of consuming the
  primary ENI's address space.
- Hubble gives flow-level network observability — `hubble observe`
  against live traffic — that the VPC CNI has no equivalent for.
- `CiliumNetworkPolicy` backs the constitution's default-deny requirement
  with identity-aware L3–L7 enforcement, not just IP/port matching.

### Negative

- **A known upstream bug makes WireGuard load-bearing, not optional.**
  Cilium issue #43493 (still open) breaks the Gateway API L7 proxy on
  cross-node traffic under ENI-mode prefix delegation: the BPF ipcache
  sets the `hastunnel` flag incorrectly for remote pods under native
  routing, and Envoy fails to reach backend pods on another node. The
  workaround is `encryption.type: wireguard` — node-to-node WireGuard
  tunnels bypass the faulty routing logic. WireGuard is therefore enabled
  here as a workaround for this bug, not chosen for its encryption
  properties, and it cannot be disabled or swapped for an alternative
  such as ztunnel transparent encryption while #43493 stays open.
  - *Mitigation*: none beyond keeping the workaround in place; tracked as
    a standing constraint on future Cilium encryption changes, not a
    one-off note.
- **The CNI ConfigMap's `cniVersion` has to be bumped by hand on every
  Cilium minor that changes the CNI standard version.** Because the
  platform sets `cni.configMap` to its own ConfigMap, Cilium's chart
  default for `cniVersion` never applies — this repository's value is
  authoritative and can silently drift from what the installed Cilium
  minor expects. Cilium 1.20 moved the value from `0.3.1` to `1.0.0`.
  - *Mitigation*: none automated today; it is a line to remember on every
    Cilium minor upgrade, not something CI catches.
- **Prefix delegation does not apply to the node-group nodes created
  during bootstrap.** Those nodes exist from Stage 1, before Cilium is
  running in Stage 2, so Cilium hands them individually-allocated
  secondary IPs instead of prefixes and never converts them afterward —
  a permanent ceiling of roughly 42 pod IPs per node instead of the
  ~240 a Karpenter-provisioned node gets with prefix delegation. The
  failure surfaces far from the cause: a DaemonSet pod stuck unable to
  get an IP keeps its rollout in progress, which times out an unrelated
  `HelmRelease`'s `--wait` and reports that HelmRelease `InstallFailed`.
  - *Mitigation*: the deploy script recycles node-group nodes after
    Cilium is healthy, so their replacements come up with Cilium already
    running and do get prefixes; the recycle step is idempotent and a
    no-op on every deploy after the first.
- **`cilium-operator` probes for the Gateway API CRDs exactly once, at
  startup, and permanently disables its Gateway API controller if any are
  missing — no crash, no alert.** See
  [ADR-0015](0015-gateway-api-over-ingress-nginx.md).

### Neutral

- The pod subnets (`100.64.x.x`) must **not** carry the
  `kubernetes.io/role/cni` tag. The VPC CNI uses that tag for its own
  subnet discovery during Stage 1 bootstrap, and tagging the pod subnets
  with it makes VPC-CNI claim them too, creating orphan ENIs the moment
  Cilium takes over in Stage 2. `cilium.io/pod-subnet=true` is the only
  tag these subnets should carry.

---

## Implementation Notes

Stage 2 (`opentofu/aws/eks/configure/main.tf`) performs the CNI swap as three
ordered steps, each patching a DaemonSet's `nodeSelector` to an impossible
label rather than deleting the EKS addon, so the stage stays declarative
with no `local-exec` step: patch `aws-node` (VPC-CNI) to schedule on no
nodes, install Cilium with `kubeProxyReplacement: true`, then patch
`kube-proxy` the same way. Cilium's `operator.unmanagedPodWatcher`
restarts any pod not managed by Cilium (CoreDNS, the EBS CSI driver, …)
automatically afterward, so no manual restart step follows the swap.

Cilium's ENI IPAM settings (`ipam.mode: eni`, `routingMode: native`,
`eni.awsEnablePrefixDelegation: true`) live in
`opentofu/aws/eks/init/helm_values/cilium.yaml`. The CNI ConfigMap referenced
via `cni.configMap: cilium-cni-configuration` is
`opentofu/aws/eks/configure/cilium-cni-config.tf`, which owns
`first-interface-index`, `subnet-tags`, and the `cniVersion` covered
above. `gatewayAPI.enabled: true` and `envoy.enabled: true` turn on the
Gateway API controller and its Envoy L7 proxy; `hubble.relay.enabled` and
`hubble.ui.enabled` turn on flow observability.

---

## References

- [Cilium]({{< relref "/docs/platform/networking/cilium.md" >}}) — the
  full technical writeup this decision summarizes, including the
  gotchas list this ADR's Negative section draws from
- [Gateway API]({{< relref "/docs/platform/networking/gateway-api.md" >}})
  — the `GatewayClass`/`Gateway`/`HTTPRoute` model Cilium implements
- [Policies]({{< relref "/docs/platform/security/policies.md" >}}) — the
  default-deny `CiliumNetworkPolicy` model this decision backs
- [AWS Foundations]({{< relref "/docs/platform/foundations/aws.md" >}}) —
  the two-stage EKS bootstrap and the node-recycle step for the
  prefix-delegation ceiling
- [ADR-0005](0005-gke-standard-self-managed-cilium.md) — the GCP
  counterpart, where `ipam.mode=kubernetes` means the WireGuard
  workaround above is expected to be unnecessary
- [CLAUDE.md](https://github.com/Smana/cloud-native-ref/blob/main/CLAUDE.md)
  — "Cilium Prefix Delegation", "Pod Subnet Tagging", and the Gateway API
  CRD startup-probe entry under Troubleshooting
- [`.claude/rules/cilium-network-policies.md`](https://github.com/Smana/cloud-native-ref/blob/main/.claude/rules/cilium-network-policies.md)
  — `CiliumNetworkPolicy` authoring traps and the Hubble-based diagnostic
  order
- `opentofu/aws/eks/configure/cilium-cni-config.tf` — the CNI ConfigMap and
  its manually-tracked `cniVersion`
- `opentofu/aws/eks/init/helm_values/cilium.yaml` — `kubeProxyReplacement`,
  ENI IPAM, WireGuard, Gateway API, and Hubble settings
- [cilium#43493](https://github.com/cilium/cilium/issues/43493) — the
  ENI-mode L7 proxy bug behind the WireGuard workaround
