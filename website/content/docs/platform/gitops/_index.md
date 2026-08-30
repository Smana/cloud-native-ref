---
title: GitOps
weight: 20
description: What GitOps means here, the Flux resources this repository actually uses, the tree Flux reconciles, and the dependency graph re-derived from the manifests.
lastVerified: 2026-08-30
---

Once [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}})
hands off a cluster with Flux installed and reconciling, everything else in
this repository — infrastructure, security, observability, tooling,
applications — is described in Git and applied by Flux, never by a human or
a CI job running `kubectl apply`.

## What GitOps means here

- **Git is the source of truth.** The desired state of the cluster is
  whatever is committed to `main`, not whatever is currently running.
- **Controllers reconcile continuously**, not on a one-shot deploy — drift
  gets corrected on the next sync interval, not just noticed.
- **Declarative, not imperative.** Manifests describe the end state; nothing
  in this repository is a step-by-step script for reaching it.
- **The audit trail is Git history** — every change to the cluster has a
  commit, an author, and (via required PR review) an approval.
- **Disaster recovery is pointing a fresh cluster's Flux at the same Git
  path** — not replaying a runbook.

## Why Flux

- **Kubernetes-native** — CRDs and controllers, not an external service
  polling the cluster from outside.
- **Built-in dependency management** (`dependsOn`) and health checking — a
  Kustomization can wait for another to actually be healthy, not just applied.
- **GitHub App authentication** rather than a long-lived personal access
  token for pulling this repository.
- **CNCF project**, actively developed, with the Flux Operator this repository
  uses for lifecycle management of Flux itself.

## The Flux resource model

Flux is not one controller reading one directory. Seven kinds do the work
here, and each one is a real file in this repository:

| Resource | What it does here | Where |
|---|---|---|
| `FluxInstance` | The Flux Operator manages Flux's own installation and upgrades from this one object — which controllers run, how they are sharded, how they are tuned | `opentofu/shared/helm_values/flux-instance.yaml.tftpl` — one template both clouds render, applied in Stage 2 |
| `GitRepository` | The `flux-system` source: this repository, authenticated as a GitHub App. Eleven more point at external repositories | created by the `FluxInstance`; the rest in `flux/sources/` |
| `ArtifactGenerator` → `ExternalArtifact` | Re-slices the one fetched repository artifact into a narrower artifact per domain, so a change under `security/` does not re-trigger `observability/` | `flux/artifact-generators/monorepo-split.yaml` |
| `Kustomization` | Applies one domain's overlay, in dependency order, and reports whether it is healthy | `clusters/aws-0/`, `clusters/gcp-0/` |
| `HelmRelease` with `HelmRepository` / `OCIRepository` | Every upstream chart. Twenty-four Helm repositories and eight OCI repositories back them | `flux/sources/`, releases under each domain's `base/` |
| `Alert` + `Provider` | Reconciliation failures out to Slack, GitHub commit statuses and OTel traces — three `Alert`s, three `Provider`s | `flux/notifications/` (all three `Alert`s, two of the three `Provider`s — the third, `otel-traces`, is `flux/observability/otel-provider.yaml`) |
| `ResourceSet` + `ResourceSetInputProvider` | Preview environments generated per pull request | `flux/previews/` |

### What makes a Kustomization keep things true

`clusters/aws-0/security/security.yaml` is a compact example of every
property that matters:

```yaml
spec:
  prune: true              # a resource deleted from Git is deleted from the cluster
  interval: 4m0s           # re-apply every 4 minutes even if Git has not changed —
                           # this is what corrects drift rather than merely detecting it
  retryInterval: 30s       # on failure, retry faster than the healthy interval
  timeout: 8m0s            # how long health checks may take before this is Failed
  sourceRef:
    kind: ExternalArtifact # the domain's slice, not the whole repository
    name: security-artifact
  path: ./security/aws-0
  postBuild:
    substituteFrom:        # cluster-specific values injected at apply time
      - kind: ConfigMap
        name: eks-aws-0-vars
  dependsOn:
    - name: eks-pod-identities
  healthChecks:            # "applied" is not "ready" — this is the difference
    - apiVersion: helm.toolkit.fluxcd.io/v2
      kind: HelmRelease
      name: cert-manager
      namespace: security
    # ... kyverno, external-secrets
```

`healthChecks` combined with `dependsOn` is the whole ordering mechanism:
nothing that depends on `security` reconciles until cert-manager, Kyverno and
External Secrets are all genuinely Ready — not merely created.

### How Flux itself is tuned

The `FluxInstance` runs five controllers — `source-controller`,
`kustomize-controller`, `helm-controller`, `notification-controller` and
`source-watcher`. The image-automation pair is deliberately left commented
out; this repository pins versions explicitly and Renovate proposes the bumps.

Three non-default settings are load-bearing:

- **Sharding.** One extra shard, `apps`, keyed on `sharding.fluxcd.io/key`.
  Its sharp edge is documented in
  [Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}}) —
  it is why every source in this repository lives under `flux/sources/`.
- **Concurrency.** `source-controller` runs `--concurrent=10` and
  `kustomize-controller` `--concurrent=6`, with `--requeue-dependency=10s` so
  a Kustomization blocked on a dependency re-checks every ten seconds rather
  than waiting out its full interval.
- **`CancelHealthCheckOnNewRevision`** on both the kustomize- and
  helm-controller: when a new commit lands mid-health-check, the stale check
  is abandoned instead of running to its timeout. It is the difference
  between a fix landing in seconds and waiting out an eight-minute timeout on
  the broken revision it replaces.

## The repository, as Flux sees it

Each top-level directory maps to a Kustomization, or to the OpenTofu half
that runs before Kubernetes exists:

{{< repo-tree depth="1" >}}

[Repository Layout]({{< relref "/docs/reference/repository-layout.md" >}}) has
the full tree with sub-directories, and
[Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}})
explains the `ArtifactGenerator` slicing and the sharding trap.

## The dependency hierarchy

![The Flux dependency graph as the manifests declare it: namespaces feeds crds, which feeds both the Crossplane chain and karpenter; crossplane-configuration feeds eks-pod-identities, which feeds security and joins karpenter at infrastructure; observability and infrastructure both gate tooling, which gates apps; the llm-platform Kustomization is suspended and reconciles nothing](/images/diagrams/flux-dependency-tree.svg)

This graph is re-derived from `spec.dependsOn` in every
`clusters/aws-0/**/*.yaml`, not carried over from an earlier
description of it — the shape has changed more than once.

**The spine**, one Kustomization deep at each step:

```
namespaces → crds → crossplane-controller → crossplane-providers
           → crossplane-configuration → eks-pod-identities → security
```

Four things about the graph are not obvious from that line:

- **`karpenter` branches off `crds`, not off Crossplane.** Its IAM Pod
  Identity is created by OpenTofu in
  [Foundations]({{< relref "/docs/platform/foundations/_index.md" >}}), not by
  Crossplane's `EKSPodIdentity` composition, so it has nothing to wait for.
  `karpenter-nodepools` hangs off it and is a leaf.
- **`infrastructure` does not depend on `security`.** Its `dependsOn` is
  `karpenter` and `eks-pod-identities` — it needs Crossplane's EPIs for their
  IAM roles, not Security's External Secrets, cert-manager and Kyverno. It
  simply becomes ready around the same time.
- **`flux-artifact-generators` and `flux-sources` have no `dependsOn` at
  all.** `flux-artifact-generators` sources from the `GitRepository`
  directly — it has to, since it is what creates the `ExternalArtifact`s
  everything else sources from. Both still run first in practice, because
  Flux waits for a Kustomization's `sourceRef` artifact to exist.
- **The opt-in `llm-platform` umbrella sits outside the graph entirely**,
  suspended, and also sources from the `GitRepository` directly — its path
  falls outside every `ArtifactGenerator` glob.

`security` is where the graph forks. Five Kustomizations become eligible once
it is healthy, though not all at the same hop: two depend on `security`
directly, and three depend on `security-openbao` — itself one hop downstream
of `security` — instead:

| Kustomization | Depends on | What it does after |
|---|---|---|
| `observability-victoria-metrics-k8s-stack` | `security-openbao` | forks into `observability-victoria-traces` (a dead end) and `observability-grafana-operator` → `observability` |
| `flux-operator` | `security-openbao` | Flux's own operator lifecycle management |
| `flux-observability` | `security` | Flux's metrics and dashboards wiring |
| `flux-notifications` | `security-openbao` | Alertmanager and Slack notification wiring |
| `flux-previews` | `security` | Flux preview-environment wiring |
| `infrastructure` | `karpenter`, `eks-pod-identities` — **not** `security` | Cilium policies, Gateway API, External DNS, the AWS Load Balancer Controller, EFS CSI, KEDA |

`zitadel` depends on `infrastructure`, `security-openbao` and
`security-public-certs` directly — it needs a database, OpenBao's secrets, and
the Let's Encrypt issuer. Everything converges at the bottom: `tooling`
depends on `observability` and `infrastructure`; `apps` — the tenant-facing
`App` claims — depends only on `tooling`.

This is `aws-0`'s graph. `gcp-0` reconciles the same domains but not the same
edges: `security` depends on `crds` rather than `eks-pod-identities`, and
there is no `karpenter`, `eks-pod-identities` or `flux-previews` at all — see
[Cloud support]({{< relref "/docs/platform/foundations/cloud-support.md" >}}).

## Observing and operating

Reconciliation is only useful if you can watch it. The Flux CLI pinned in
`mise.toml` is the primary interface:

```bash
# Everything, with its current state and last-applied revision
flux get all -A

# Why is this Kustomization not ready? Walk what it created.
flux tree kustomization infrastructure

# What just happened, in order — the first thing to run on a failure
flux events --for Kustomization/security

# Pull the latest commit and re-apply immediately instead of waiting out the interval
flux reconcile kustomization apps --with-source

# Stop reconciling while debugging by hand — and remember to undo it
flux suspend kustomization tooling
flux resume kustomization tooling
```

`flux suspend` is the one command that breaks the GitOps contract on purpose:
while a Kustomization is suspended the cluster can drift from Git and nothing
will correct it. That is also exactly how the opt-in LLM platform ships —
suspended by default, see
[AI Platform]({{< relref "/docs/platform/ai-platform/_index.md" >}}).

Flux also reports on itself: `flux/observability/` ships its Grafana
dashboards and alert rules, and `flux/notifications/` sends reconciliation
failures to Slack, so a Kustomization that goes Failed at 3am is a message
rather than a surprise the next morning. For walking the full Flux →
Kubernetes → Crossplane chain on a live cluster, see
[Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}).

## Validation before any of this applies

Every manifest above is rendered and gated before it reaches `main` — see
[Validation]({{< relref "/docs/platform/gitops/validation.md" >}}).
