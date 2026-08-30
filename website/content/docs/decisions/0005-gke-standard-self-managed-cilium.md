---
title: GKE Standard with self-managed Cilium (not Dataplane V2, not Autopilot)
linkTitle: 0005 · Cilium on GKE
weight: 50
description: GCP clusters run GKE Standard with self-managed Cilium rather than Dataplane V2 or Autopilot, to keep Gateway API, Tailscale ingress, and default-deny CiliumNetworkPolicy unchanged.
lastVerified: 2026-08-30
---

**Status**: Accepted
**Date**: 2026-08-18
**Deciders**: Smana (Platform Owner)
**Related Design**: [GCP Support — Dual-Cloud Platform Design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md)

---

## Context

The platform is adding GCP as a **second first-class cloud**, maintained in parallel with AWS
(see [ADR-0007](0007-cloud-abstraction-boundaries.md) for the abstraction strategy). The single
biggest technical fork is which GKE flavour to run, because it decides whether the components
this platform is built around survive the port or have to be replaced.

Three properties of the existing platform are load-bearing and constrain the choice:

1. **Gateway API is the only ingress mechanism.** All north-south traffic goes through
   `Gateway`/`HTTPRoute`, implemented by Cilium's `io.cilium/gateway-controller`.
2. **Tailscale is the only path to private services.** Both private gateways
   (`platform-tailscale-general`, `platform-tailscale-admin`) are `GatewayClass`es whose
   `parametersRef` points at a **`CiliumGatewayClassConfig`** setting
   `loadBalancerClass: tailscale`. ACL separation between `tag:k8s` and `tag:admin` is enforced
   by having two such Gateways.
3. **`CiliumNetworkPolicy` default-deny is a constitution requirement**
   ([platform constitution]({{< relref "/docs/reference/platform-constitution.md" >}})), and Envoy L7 access logs from
   `CiliumGatewayClassConfig.spec.telemetry.accessLogs` (Cilium >= 1.19.6) feed VictoriaLogs.

GKE offers three shapes, and only one preserves all three.

---

## Decision Drivers

- **Gateway API + Tailscale continuity** — the two private gateways must keep working with the
  same `GatewayClass` mechanism, or the whole private-access model is rebuilt.
- **Constitution compliance** — `CiliumNetworkPolicy` and the Envoy JSON access-log pipeline.
- **Port vs. replace** — how much of `infrastructure/base/` moves unchanged.
- **Number of implementations to maintain** — dual-cloud already doubles the surface; a second
  *Gateway* implementation on top of that is a multiplier, not an addition.
- **Reversibility** — GKE's datapath is a create-time property.

---

## Considered Options

### Option 1: GKE Standard + self-managed Cilium

`datapathProvider` left at its default (legacy). Cilium installed by the platform itself in a
stage-2 OpenTofu step, mirroring the existing EKS two-stage bootstrap.

**Pros**:
- `CiliumGatewayClassConfig`, `io.cilium/gateway-controller`, Hubble, `CiliumNetworkPolicy` and
  the Envoy access-log telemetry all work exactly as on AWS — both Tailscale gateways port
  essentially unchanged.
- Cilium version stays a single platform-wide variable (`opentofu/config.tm.hcl`
  `cilium_version`), so both clouds upgrade together.
- Most of `infrastructure/base/` is a port, not a rewrite.
- Current Cilium docs carry a working GKE recipe for exactly the pinned version (1.20.0) — see
  References.

**Cons**:
- Unblessed on both sides: Google will not support a cluster whose CNI it does not manage, and
  Cilium removed its dedicated GKE installation guide after 1.9 (2021).
- The platform owns CNI upgrades on GCP (it already does on AWS, so this is not new work,
  but it is now on a path with less community traffic).
- Requires nodes to carry `node.cilium.io/agent-not-ready=true:NoSchedule` so pods do not land
  before the agent is ready — including on autoscaled nodes
  (see [ADR-0006](0006-nap-computeclass-over-karpenter.md)).

### Option 2: GKE Standard + Dataplane V2

`datapathProvider: ADVANCED_DATAPATH`. Google-managed Cilium.

**Pros**:
- Supported, maintained, and upgraded by Google.
- `CiliumNetworkPolicy` (a subset) and GKE-flavoured Hubble are available.
- Node auto-provisioning is a blessed, well-trodden combination.

**Cons**:
- **No `CiliumGatewayClassConfig` CRD and no `io.cilium/gateway-controller`.** Both Tailscale
  gateways would be rebuilt on the GKE Gateway controller, and the `loadBalancerClass: tailscale`
  mechanism replaced with something else.
- Loses `spec.telemetry.accessLogs`, so the Envoy JSON -> VictoriaLogs pipeline needs a
  GCP-specific replacement.
- Two Gateway API implementations to maintain forever, diverging in features and bugs.
- No control over Cilium config: `kubeProxyReplacement`, `encryption`, and Hubble settings are
  Google's to choose.

### Option 3: GKE Autopilot

Fully managed nodes.

**Pros**:
- Lowest operational burden; no node management at all.
- Strong security posture by default.

**Cons**:
- Everything in Option 2's cons, plus: no self-managed CNI at all, no privileged pods
  (breaks the privileged `dagger-engine` Deployment and node-level exporter DaemonSets), and no
  node-level control for GPU workloads.
- Turns large parts of `infrastructure/base/` from a port into a replacement.

---

## Decision Outcome

**Chosen option**: "Option 1 — GKE Standard + self-managed Cilium"

**Rationale**: Gateway API and Tailscale are not incidental to this platform, they are how it
exposes everything. Option 1 is the only shape where the two private `GatewayClass`es, the
`loadBalancerClass: tailscale` mechanism, and the Envoy access-log pipeline survive the port
without a second Gateway implementation. The cost is running an unblessed path — real, but
bounded: the platform already owns Cilium's lifecycle on AWS, and current Cilium documentation
carries a working recipe for the exact pinned version. Option 2's support story is genuinely
better, but it buys that support by requiring a parallel ingress stack, which is the single
most expensive thing dual-cloud could ask for.

`--enable-dataplane-v2` is **opt-in** on Standard clusters (it is the default only on
Autopilot), and `gcloud container clusters create` carries no deprecation notice on the legacy
datapath as of 2026-08. So this is not "disable Dataplane V2" — it is "do not enable it".

---

## Consequences

### Positive

- Both Tailscale gateways, the Cilium Gateway API stack, Hubble, `CiliumNetworkPolicy`, and the
  Envoy JSON access logs port to GCP with configuration changes only.
- One Gateway API implementation, one CNI, one `cilium_version` across both clouds.
- Hubble-based network debugging (`hubble observe --verdict DROPPED`) works identically on both
  clouds, preserving the diagnostic order documented in
  [`.claude/rules/cilium-network-policies.md`](https://github.com/Smana/cloud-native-ref/blob/main/.claude/rules/cilium-network-policies.md).

### Negative

- **Not reversible in place.** Dataplane V2 can only be set at cluster creation; switching
  later means replacing the cluster.
  - *Mitigation*: the design validates this on a throwaway cluster before the platform depends
    on it — the first gate task is an explicit stop-and-revisit on this ADR.
- Unsupported by Google, and off Cilium's documented happy path.
  - *Mitigation*: pin `imageType` so kernel requirements are known; treat the CNI-displacement
    check as a permanent regression test rather than a one-off.
- The `node.cilium.io/agent-not-ready` taint must reach every node, including autoscaled ones.
  - *Mitigation*: `ComputeClass.nodePoolConfig.taints[]`, verified by the autoscaling slice.

### Neutral

- GCP Cilium values are **forked**, not merged with the AWS values file. With two clouds and
  roughly eight divergent keys, duplicating ~130 lines is cheaper and more legible than a merge
  mechanism that hides what Cilium actually receives. Revisit at cloud number three.
- `ipam.mode` diverges: `eni` on AWS, `kubernetes` on GCP (host-scope from `spec.podCIDR`, with
  GKE alias IP ranges providing native VPC routing). The AWS-only
  `opentofu/aws/eks/configure/cilium-cni-config.tf` prefix-delegation ConfigMap has no GCP
  counterpart.

---

## Implementation Notes

Cluster creation must include `--enable-ip-alias`, an explicit `--cluster-ipv4-cidr` and
`--services-ipv4-cidr`, and the agent-not-ready node taint. Cilium is then installed with
`ipam.mode=kubernetes`, keeping `routingMode: native`.

**`encryption.type: wireguard` is expected to be unnecessary on GCP.** CLAUDE.md currently
records WireGuard as load-bearing, but that is a workaround for
[cilium#43493](https://github.com/cilium/cilium/issues/43493), which is specifically the BPF
ipcache `hastunnel` flag under **ENI mode with prefix delegation**. With `ipam.mode=kubernetes`
that code path is not taken. The cross-node L7 success criterion tests this empirically; CLAUDE.md's note is
rescoped to AWS only once that criterion passes, and not before.

---

## References

- [Cilium GKE-to-GKE Clustermesh Preparation](https://docs.cilium.io/en/latest/network/clustermesh/gke-clustermesh-prep/) — current docs, working GKE + Cilium 1.20.0 recipe
- [Cilium GKE IPAM mode](https://docs.cilium.io/en/latest/network/concepts/ipam/gke/) — `ipam.mode=kubernetes`
- [GKE Dataplane V2](https://docs.cloud.google.com/kubernetes-engine/docs/concepts/dataplane-v2) — create-time only; default on Autopilot
- [gcloud container clusters create](https://docs.cloud.google.com/sdk/gcloud/reference/container/clusters/create) — `--enable-dataplane-v2` is opt-in
- [cilium#43493](https://github.com/cilium/cilium/issues/43493) — the ENI-mode L7 proxy bug behind the AWS WireGuard workaround
- Existing Cilium values: `opentofu/aws/eks/init/helm_values/cilium.yaml`
- Tailscale Gateway setup: [Platform → Networking → Private access]({{< relref "/docs/platform/networking/private-access.md" >}}), `infrastructure/base/gapi/`
