---
title: The AI platform moves to its own repository, consumed by cloud-native-ref as a pinned artifact
linkTitle: 0057 · AI platform repository
weight: 570
description: Serving and the agent factory move to Smana/ai-native-ref, pulled by cloud-native-ref as one signed, digest-pinned OCI artifact behind a written host contract, chosen over keeping them here, an in-repo boundary only, merging them into agent-platform, or a repository that owns its own clusters.
lastVerified: 2026-10-12
---

**Status**: Accepted
**Date**: 2026-10-12
**Deciders**: Smana (Platform Owner)
**Related Spec**: [AI platform split: `ai-native-ref` and its host contract](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-12-ai-platform-split-design.md)

---

## Context

`cloud-native-ref` is a reference for a cloud-native platform. The AI platform grew inside it:
about 210 manifest, image and doc files across 21 paths, six cluster umbrella directories, 38 of
the 106 design and plan documents (the largest in the repository) and fourteen ADRs, serving's included. AI is not the
repository's first use case, yet it dominates its size, its CI and its docs.

The seam already exists. Serving and the factory ship as three suspended Flux umbrellas per
cluster (`ai-gateway`, `llm-platform`, `agent-platform`) whose children depend on the host only
through Kustomization names, substitution variables, Gateways, OpenBao paths and Crossplane
compositions. The factory's code already lives elsewhere (`agent-platform`, `crossplane-configuration`),
so v2 does not wait for the split; the split is about what this repository reads as.

---

## Decision Drivers

- `cloud-native-ref` should read as a platform, with AI one workload on it
- Showing a vertical hosted from another repository, without a fork, is itself a reference pattern
- A default deploy stays AI-free and does not depend on a second repository being reachable
- The factory's target-repository controls stay with the repository they protect
- No extra hop for the most frequent change, a runtime fix, which never passes through the AI manifests

---

## Considered Options

### Option 1: Keep everything in `cloud-native-ref`

**Pros**:
- One repository, one CI, one docs site; no contract to keep

**Cons**:
- The size and focus problem stays and grows with v2
- The boundary is implicit: nothing stops a host path from depending on an AI path

### Option 2: An in-repo boundary only

Move the AI paths under one tree with its own `AGENTS.md`, CODEOWNERS and CI path filters.

**Pros**:
- Cheap; no new repository or release

**Cons**:
- Every path moves now and again at a later split
- The repository stays as large; the reader's problem is unsolved

### Option 3: `ai-native-ref`, pulled as a pinned artifact behind a host contract

The AI manifests, docs and their CI move to a new repository. The host defines one cosign-verified
`OCIRepository` and retargets the three umbrellas to it.

**Pros**:
- `cloud-native-ref` shrinks to the platform; AI has its own ADRs, CI and docs site
  (`ainref.ogenki.io`, built like `cnref.ogenki.io` in its own colour, the two linked both ways)
- The same consumption pattern as `crossplane-configuration` and the factory chart: digest pin,
  signature, Renovate
- The factory's config leaves the repository agents work on: its gate paths become the pin, beside
  the host paths that define agent authority (OpenBao policies, JWT roles, the AI namespaces)

**Cons**:
- A host contract to keep true in two repositories
- One more hop for an AI manifest change (a runtime fix keeps today's chain), and cross-repository `dependsOn` that fails
  at reconcile rather than render

### Option 4: Merge the manifests into `agent-platform`

**Pros**:
- No new repository; code and deployment together

**Cons**:
- Mixes a code repository's releases with deployment config for two clouds
- Serving is not `agent-platform`'s concern

### Option 5: `ai-native-ref` owns its own clusters

**Pros**:
- Fully independent

**Cons**:
- Duplicates the host (OpenTofu, OpenBao, ZITADEL, Cilium) or forks it, which is what a reference
  platform exists to avoid

---

## Decision Outcome

**Chosen option**: "Option 3", accepted.

**Rationale**: It solves the reader's problem, keeps a default deploy AI-free, and reuses a
consumption pattern the platform already runs. The extra hop falls only on AI manifest changes; a
runtime fix still goes `agent-platform`, `crossplane-configuration`, the host pin, and moving the
harness image to `agent-platform` first takes its build out of this repository.

---

## Consequences

### Positive

- `cloud-native-ref` keeps OpenTofu, clusters and the shared platform; AI changes stop touching it
  except to bump the pin
- The host contract makes every dependency explicit and testable

### Negative

| Cost | Mitigation |
|---|---|
| Two repositories for one maintainer | Same tooling: `mise`, `task check`, Renovate, the skills |
| A host change can break AI silently | Each side's CI renders against the other: the host renders the pinned artifact, `ai-native-ref` renders against a host profile |
| Docs and history move | `git filter-repo` keeps paths; the host keeps an overview page and an index row per moved ADR, linked to the AI site |
| Cross-site links escape Hugo's `relref` check | Few of them, each fetched after deploy |

### Neutral

- The factory keeps working on `cloud-native-ref`. Working on `ai-native-ref` too is the v2
  "second repository" gate, unchanged by this decision.
- `.policy.yml`, the `agent-*` rulesets and trust policies, and the `factory-handoff` skill stay
  here: they protect this repository as a factory target.

---

## Implementation Notes

Steps S0 to S4, their gates and the full host contract are in the
[design](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-12-ai-platform-split-design.md).
The creation of `ai-native-ref` (S2) waits for the v1 hardening milestone to close.

---

## References

- [Status and roadmap]({{< relref "/docs/platform/ai-platform/status.md#v2-roadmap" >}})
- [Agent factory v1 review](https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-10-12-agent-factory-v1-review.md)
