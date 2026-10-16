---
title: AI Platform
weight: 50
description: "Model serving and the agent factory, published on their own site: airef.ogenki.io. This platform hosts them, off by default."
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

## Turning it on

A default deploy is AI-free: the `OCIRepository` `ai-native-ref` and the three umbrella
Kustomizations are suspended. Resume the source, then the umbrellas (`ai-gateway` first, the other two
depend on it):

```bash
flux resume source oci ai-native-ref -n flux-system
flux resume kustomization ai-gateway -n flux-system
flux resume kustomization llm-platform -n flux-system
flux resume kustomization agent-platform -n flux-system
```

What this platform guarantees the AI platform (Flux names, substitution variables, Gateways,
namespaces, OpenBao mounts) is the
[host contract](https://github.com/Smana/ai-native-ref/blob/main/HOST-CONTRACT.md).

{{< cards >}}
  {{< card link="https://airef.ogenki.io/docs/platform/ai-platform/" title="AI platform docs ↗" icon="external-link" subtitle="Serving, gateways, the agent factory, status and roadmap." >}}
  {{< card link="https://airef.ogenki.io/docs/decisions/" title="AI decisions ↗" icon="external-link" subtitle="The AI ADRs, numbers unchanged." >}}
  {{< card link="https://github.com/Smana/ai-native-ref" title="ai-native-ref ↗" icon="github" subtitle="Manifests, runbooks, specs and plans." >}}
{{< /cards >}}
