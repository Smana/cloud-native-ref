---
title: Repository Structure
weight: 20
description: How Flux actually assembles what it applies — the ArtifactGenerator/ExternalArtifact split and controller sharding.
lastVerified: 2026-08-30
---

[Repository Layout]({{< relref "/docs/reference/repository-layout.md" >}})
covers the full directory tree and the base/overlay pattern. This page is
narrower: two GitOps-specific mechanisms that decide *what Flux actually
reconciles from* and *which controller reconciles it* — neither obvious from
the directory tree alone.

## One `GitRepository`, sliced into `ExternalArtifact`s

Every domain Kustomization under `clusters/aws-0/` and `clusters/gcp-0/` — `infrastructure`,
`security`, `observability`, `tooling`, `apps`, the `flux/*` self-management
Kustomizations, `crds`, `namespaces` — sources from an `ExternalArtifact`,
not from the `flux-system` `GitRepository` directly. All of them are produced
by one `ArtifactGenerator`, `flux/artifact-generators/monorepo-split.yaml`:

```yaml
apiVersion: source.extensions.fluxcd.io/v1beta1
kind: ArtifactGenerator
metadata:
  name: monorepo-split
spec:
  sources:
    - alias: repo
      kind: GitRepository
      name: flux-system
  artifacts:
    - name: infra-artifact
      copy:
        - from: "@repo/infrastructure/**"
          to: "@artifact/infrastructure/"
    # one entry per domain: security, observability, tooling, apps,
    # flux, crds, namespaces
```

It re-slices the one `GitRepository` artifact (the whole repository, fetched
once) into one narrower `ExternalArtifact` per top-level domain directory.
Every domain Kustomization then points `sourceRef` at its own slice —
`infrastructure.yaml` at `infra-artifact`, `security.yaml` at
`security-artifact`, and so on — instead of at the full repository.

Two Kustomizations are the exception, necessarily: `flux-artifact-generators`
(which applies the `ArtifactGenerator` above, so it has to read the
`GitRepository` directly — the `ExternalArtifact`s don't exist until it
runs) and the opt-in `llm-platform` umbrellas, whose paths
(`clusters/aws-0-llm-platform/`, `clusters/gcp-0-llm-platform/`) fall outside
every `copy.from` glob above.

The `from: "@repo/<dir>/**"` / `to: "@artifact/<dir>/"` shape matters: a
trailing `/` on the source instead of `/**` copies `<dir>/` into
`<artifact>/<dir>/` — one level of double-nesting — rather than the
directory's contents into the artifact root.

## Controller sharding: `apps` vs default

The `FluxInstance` (`opentofu/shared/helm_values/flux-instance.yaml.tftpl`,
rendered by both clouds) configures one extra shard:

```yaml
sharding:
  key: "sharding.fluxcd.io/key"
  shards:
    - "apps"
```

Three Kustomizations — `tooling`, `apps`, and the opt-in `apps-llm` — carry
`labels: sharding.fluxcd.io/key: apps` and propagate it to what they create
via `spec.commonMetadata.labels`; everything else reconciles on the default,
unsharded controller set. The isolation has one sharp edge: a `GitRepository`
or `HelmRepository` `Source` placed under an app-owned directory would
inherit that label the same way any other resource there does, and the
*default* shard's `source-controller`/`helm-controller` cannot see a
`HelmChart` whose `GitRepository` is only visible to the `apps` shard — it
reconciles fine as `Ready`, and a completely unrelated `HelmRelease` on the
default shard fails with "source not found", far from the actual cause.
`flux/sources/` carries no shard label for exactly this reason: every
`GitRepository`/`HelmRepository` in this repository lives there, never under
an app-owned directory.
