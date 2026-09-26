---
title: Coding agents run in agent-sandbox Sandboxes under gVisor, on AL2023 spot nodes, with OpenHands as the harness profile
linkTitle: 0041 · Agent sandbox runtime
weight: 410
description: Every agent run is a bare agent-sandbox Sandbox on a dedicated Karpenter AL2023 spot pool where runsc is installed at boot, because Bottlerocket ships no runsc. The harness is OpenHands agent-server, selected by a platform profile the claim cannot override. Kata, OpenHands Enterprise, Coder and hosted sandboxes were rejected.
lastVerified: 2026-09-26
---

**Status**: Accepted
**Date**: 2026-09-26
**Deciders**: Smana (Platform Owner)
**Related Spec**: [SP1 — Agent runtime & identity](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-09-23-agent-runtime-identity-design.md)

---

## Context

Autonomous coding agents (Agent Factory programme) execute model-written code with a shell. A
container boundary alone is not enough for that: a kernel exploit from one run would reach the node,
its IAM role and every co-located run. The platform's nodes run Bottlerocket, which ships no gVisor
(`runsc`) and has no plan to ([bottlerocket#811](https://github.com/bottlerocket-os/bottlerocket/issues/811)).
AWS's own `ai-on-eks` blueprint runs agent-sandbox with gVisor on a Karpenter AL2023 pool.

---

## Decision Drivers

- A user-space kernel between agent code and the node kernel
- Open source first (programme D2), GitOps-managed like every other workload
- Identity per run, so the pod spec must be per run
- Test clusters are spot and cheapest
- No image choice in the claim: a claim must not be a supply-chain input

---

## Considered Options

### Option 1: agent-sandbox `Sandbox` + gVisor on a Karpenter AL2023 spot pool

The XR composes a bare `Sandbox` with `runtimeClassName: gvisor`. User-data installs a pinned,
sha256-checked gVisor tarball and registers `runsc` in containerd's v3 CRI table, on `systrap`. `oci-seccomp` stays off: runsc ignores
`errnoRet` ([gVisor #14688](https://github.com/google/gvisor/issues/14688)), which breaks glibc thread
creation under `RuntimeDefault`.

**Pros**:
- The same stack as AWS's blueprint; `Sandbox` reports `Ready` and `Finished`, so it fits a one-shot run
- No nested virtualisation
- Per-run pod spec: the ServiceAccount, audiences and CNP are composed with the run

**Cons**:
- An AL2023 pool is the one exception to the Bottlerocket rule
- `v1beta1` API, weekly releases: the tag is pinned and its CRDs enter the CI catalog
- gVisor costs file-I/O speed (measured by the phase-0 spike, SC-15)

### Option 2: Kata Containers / Firecracker

**Pros**:
- A hardware virtualisation boundary

**Cons**:
- Needs nested virtualisation or metal instances on EC2; AWS calls it the "future tier"

### Option 3: OpenHands Enterprise, Coder, or a hosted sandbox (E2B, Daytona)

**Pros**:
- Turnkey workspaces

**Cons**:
- Not open source, or SaaS: data and credentials leave the cluster (D2)
- OpenHands' own Kubernetes workspace is built on warm pools, whose pods already carry a
  ServiceAccount; claim-time identity is only *Planned* upstream

### Harness profile: OpenHands agent-server over headless Claude Code and kagent

agent-server is MIT, runs as UID 10001, speaks OpenAI-compatible HTTP to whatever base URL it is
given, and exposes the four local operations SP2's room bridge needs. Headless Claude Code is not
open source; kagent v1 is alpha. The claim names a **profile** (`openhands`), never an image; the
composition maps it to a digest.

---

## Decision Outcome

**Chosen option**: "agent-sandbox `Sandbox` + gVisor on a Karpenter AL2023 spot pool", with the
OpenHands agent-server profile.

**Rationale**: It is the only option that is open source, runs on EKS without nested
virtualisation, and lets identity be composed per run.

---

## Consequences

### Positive

- Kernel attack surface is gVisor's Sentry, not the node kernel
- Every run's identity, egress and resources are declared by one XR and die with it

### Negative

- A Sentry escape reaches the node's IAM role and co-located runs. Mitigations: dedicated tainted
  pool, IMDS hop limit 1, daily node replacement (`expireAfter: 24h`). Kata is the next tier
- `RuntimeDefault` seccomp is not enforced inside the sandbox until gVisor honours `errnoRet`, and
  NoNewPrivileges is not reliable under it. gVisor is the control
- Vector needs a toleration for the pool's taint to ship sandbox logs

### Neutral

- A harness bump is a release of the composition package, reviewed like any other

---

## Implementation Notes

`infrastructure/base/karpenter-nodepools-agents/`, `infrastructure/base/runtimeclass-gvisor/`,
`infrastructure/base/agent-sandbox/`, Kyverno `agents-pod-shape` in `security/base/agent-policies/`,
all behind the `agent-platform` umbrella. The XR is `AgentRun` in `Smana/crossplane-configuration`.
Spike results: the SP1 agent-runtime-identity spike notes (superpowers plan artifact, not yet merged).

---

## References

- [kubernetes-sigs/agent-sandbox v1.0.3](https://github.com/kubernetes-sigs/agent-sandbox/releases)
- [gVisor release-20260921.0](https://github.com/google/gvisor/releases/tag/release-20260921.0)
- [awslabs/ai-on-eks agent-sandbox](https://github.com/awslabs/ai-on-eks/tree/main/infra/agent-sandbox)
- [wso2/agent-manager#1891](https://github.com/wso2/agent-manager/issues/1891) (containerd v3 table)
- [OpenHands agent-server](https://docs.openhands.dev/sdk/arch/agent-server)
