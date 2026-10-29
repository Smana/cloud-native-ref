---
title: AI Platform
weight: 50
description: "Model serving and Maku, published on their own site: airef.ogenki.io. This platform hosts them as an opt-in layer."
---

Two halves, one platform. **Serving** runs open-weights models on the cluster's own GPUs behind an
OpenAI-compatible gateway. **Agents** put models to work: a labelled issue becomes a sandboxed agent
run that opens a pull request, under its own identity.

{{< callout type="info" >}}
**The AI platform has its own repository and site.** Its manifests, ADRs, runbooks and docs live in
[`Smana/ai-native-ref`](https://github.com/Smana/ai-native-ref) and publish on
[airef.ogenki.io](https://airef.ogenki.io/docs/platform/ai-platform/). This platform pulls it as one
signed, version-pinned Flux artifact ([ADR-0057](https://airef.ogenki.io/docs/decisions/0057-ai-platform-own-repository/)).
{{< /callout >}}

## What runs where

The source ships suspended (`flux/sources/ocirepo-ai-native-ref.yaml`); each cluster decides what to resume.
Maku's factory runs on `gcp-0`, the one live cluster: `aws-0` is torn down, and the ownership
fence `.github/agent-factory.yaml` (`factory: gcp-0`) names the only factory allowed to act on this
repository.

| Umbrella | `aws-0` (torn down; Git state) | `gcp-0` |
|---|---|---|
| `OCIRepository` `ai-native-ref` | live | live |
| `ai-gateway` (CPU; the others depend on it) | live | live |
| `agent-platform` (Maku) | live, fenced out | live |
| `llm-platform` (GPU serving) | suspended | suspended |

To turn it on for a cluster, un-suspend the source with a patch in its
`clusters/<cluster>/flux/flux-sources.yaml` (as both clusters do), then set `spec.suspend: false` in
`clusters/<cluster>/<umbrella>.yaml`, `ai-gateway` first. A `flux resume` alone lasts only until the
next sync sets Git's value back.

What this platform guarantees the AI platform (Flux names, substitution variables, Gateways,
namespaces, OpenBao mounts) is the [host contract](https://airef.ogenki.io/docs/host-contract/).

{{< cards >}}
  {{< card link="https://airef.ogenki.io/docs/platform/ai-platform/" title="AI platform docs ↗" icon="external-link" subtitle="Serving, gateways, Maku, status and roadmap." >}}
  {{< card link="https://airef.ogenki.io/docs/decisions/" title="AI decisions ↗" icon="external-link" subtitle="The AI ADRs, numbers unchanged." >}}
  {{< card link="https://github.com/Smana/ai-native-ref" title="ai-native-ref ↗" icon="github" subtitle="Manifests, runbooks, specs and plans." >}}
{{< /cards >}}
