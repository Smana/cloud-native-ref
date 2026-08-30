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

## One repository, two clusters

`aws-0` and `gcp-0` reconcile the same `infrastructure/base`, `security/base`
and `observability/base` trees. What differs between them — a region, a VPC
CIDR, a storage class, a domain — is not branched in the manifests. It arrives
at apply time through Flux's `postBuild` variable substitution, from one
ConfigMap per cluster:

| Cluster | ConfigMap | Written by |
|---|---|---|
| `aws-0` | `eks-aws-0-vars` | `opentofu/aws/eks/configure/kubernetes.tf` |
| `gcp-0` | `gke-gcp-0-vars` | `opentofu/gcp/gke/configure/kubernetes.tf` |

Both are created in Stage 2, before Flux starts reconciling, and both carry
`reconcile.fluxcd.io/watch: Enabled` — so changing a value re-triggers every
Kustomization that substitutes from it rather than waiting out an interval.
Sixty `substituteFrom` entries across `clusters/` name one of the two.

The most-substituted variables are the ones a manifest cannot hardcode without
picking a cloud: `${private_domain_name}`, `${region}`, `${cluster_name}`,
`${public_domain_name}` and `${storage_class}`, plus `${project_id}` on
`gcp-0` alone.

### The failure mode this creates

**Flux substitutes an undefined variable to an empty string.** It does not
fail, warn, or leave the placeholder behind. The manifest is still
schema-valid; it just has a hole in it.

That is not hypothetical here. `domain_name` used to be a third key holding the
same value as `public_domain_name` — a harmless-looking alias. `gcp-0`'s
ConfigMap never defined it, so every manifest reaching for `${domain_name}` was
AWS-only *by accident* rather than by design, and rendered a hostname with a
missing middle on GCP. `observability/base/runlore` was excluded from `gcp-0`
for that reason and no other. The key was deleted rather than aliased, and the
OpenTofu still carries the note explaining why.

The rendered-bundle gate cannot catch this: `render-bundle.py` substitutes its
fixtures unconditionally, so the bundle shows what Flux *would* render given a
correct ConfigMap — never whether the ConfigMap has the key, nor whether
`postBuild` is wired at all. So there is a separate check,
`scripts/flux-schema/check-substitution.py`, which reads the Kustomizations
under `clusters/` directly, builds each path with `kustomize build`, and fails
when a Kustomization applies a `${var}` its own cluster's ConfigMap does not
define — reading those keys out of the `flux_cluster_vars` resource in each
`configure` stack. It fails equally on a path that renders variables with no
`postBuild` at all, where Flux would apply the literal `${var}` text. It runs
first in [Validation]({{< relref "/docs/platform/gitops/validation.md" >}}),
before anything is rendered.

### Same key, different shape

Sharing a key name across clouds is only honest when both values are consumed
the same way. Two keys deliberately hold differently-shaped values:

- `${openbao_cidr}` — the whole VPC CIDR on AWS, where OpenBao's internal NLB
  lives; the node subnet on GCP, where its internal load balancer does. One
  `CiliumNetworkPolicy` (`security/base/openbao-snapshot/network-policy.yaml`)
  consumes it on both.
- `${openbao_snapshot_secret}` and `${llm_hf_token_secret}` — the *name of a
  secret in the cloud's own secret store*, not a path in this repository, and
  the two stores disagree on what a name may contain: slash-delimited on AWS
  Secrets Manager, flat and dash-separated on GCP, because GCP Secret Manager
  forbids `/` in a secret ID
  ([ADR-0023]({{< relref "/docs/decisions/0023-portable-secret-store-names.md" >}})).

Which is exactly why the manifest cannot hardcode either one.

### The one variable that comes from a Secret

`substituteFrom` accepts a `Secret` as well as a `ConfigMap`, and one
Kustomization uses it. `security-openbao` on `aws-0` substitutes
`${cert_manager_approle_id}` from the `cert-manager-openbao-approle` Secret,
because cert-manager's OpenBao issuer takes `roleId` as a plain string with no
`secretRef` option — a generated value has no other way in.

A Secret's keys are created in-cluster at runtime, so `check-substitution.py`
cannot compare against them. It reports that case as a note naming the variable
and the Secret, rather than failing it or silently skipping it:

```text
note: 1 Kustomization(s) apply variable(s) no ConfigMap defines, but also
substitute from a Secret this repo cannot read:
  Kustomization/security-openbao (security/aws-0/openbao):
  ${cert_manager_approle_id} not in any ConfigMap; may come from Secret
  cert-manager-openbao-approle
```

`gcp-0` has no Secret reference here on purpose. The AWS copy substitutes out
of the very Secret its own `ExternalSecret` creates, so a fresh cluster's first
reconcile of that path necessarily fails and succeeds on the retry; GCP pins
the role ID in its OpenBao management stack and has no such cycle.

### Escaping `${...}` that Flux must not touch

Anything in an applied manifest that legitimately contains `${...}` has to be
written `$${...}`, which Flux renders back to a single `$`. Nine files need it,
and they are not all Grafana:

- Grafana dashboard and datasource JSON, where `${var}` is Grafana's own
  template syntax — `$${__value.raw}`, `$${service}`.
- `tooling/base/promptfoo/cronjob.yaml`, where an inline Node script builds
  Prometheus exposition lines with JavaScript template literals:
  ``out.push(`promptfoo_test_total{category="$${c}"} $${x.total}`)``.

`check-substitution.py` strips the escaped form before it looks for the
unescaped one — otherwise every dashboard in the repository would be a false
positive.

## Flux managing Flux

There is no `flux bootstrap` in this repository. Stage 2 of the cluster build
installs two Helm charts — `flux-operator`, then `flux-instance` — and the
second creates one object:

```yaml
# opentofu/shared/helm_values/flux-instance.yaml.tftpl — one file, both clouds
instance:
  distribution:
    version: "2.x"
    artifact: "oci://ghcr.io/controlplaneio-fluxcd/flux-operator-manifests"
  components: [source-controller, kustomize-controller, helm-controller,
               notification-controller, source-watcher]
  sync:
    kind: GitRepository
```

`instance.sync.url`, `.ref` and `.path` are passed by `--set` from each stack —
`path` is `clusters/<cluster_name>`, and `ref` is what
`TF_VAR_flux_git_ref=refs/heads/<branch>` overrides when a feature branch is
being deployed to a throwaway cluster.

What that buys over `flux bootstrap`:

- **The installation is a declared object, not the residue of a command.**
  `flux bootstrap` commits a rendered `gotk-components.yaml` to the repository
  and upgrades by re-running the command with a newer CLI. Here, which
  controllers exist, how they are sharded, what flags they run with and what
  version they are is one `FluxInstance` spec — and the operator reconciles the
  installation toward it continuously, so a hand-edited controller Deployment
  is corrected the same way any other drift is.
- **`version: "2.x"` is a range, not a pin.** The operator resolves and applies
  Flux 2.x releases from the OCI artifact without a human re-running anything.
  What *is* pinned is the operator's own chart.
- **Controller tuning is a patch, not a fork.** `kustomize.patches` in the same
  values file adds the `--concurrent` and `--requeue-dependency` flags and the
  `CancelHealthCheckOnNewRevision` feature gate described under
  [How Flux itself is tuned](#how-flux-itself-is-tuned) above. One patch also
  widens the operator-generated `allow-egress` NetworkPolicy, whose default
  same-namespace ingress rule blocks Cilium's Gateway API L7 proxy.
- **`source-watcher`** is in the component list for one reason: it reconciles
  `ArtifactGenerator`, which is what re-slices this repository into the
  per-domain `ExternalArtifact`s described in
  [Repository Structure]({{< relref "/docs/platform/gitops/repository-structure.md" >}}).

### The operator upgrades itself, from Git

OpenTofu installs the operator once, at the version pinned in
`opentofu/config.tm.hcl`. From then on `flux/operator/helmrelease.yaml` owns
it, sourced from `flux/sources/ocirepo-flux-operator.yaml`:

```yaml
url: oci://ghcr.io/controlplaneio-fluxcd/charts/flux-operator
ref:
  semver: ">=0.43.0 <1.0.0"
verify:
  provider: cosign
  matchOIDCIdentity:
    - issuer: "https://token.actions.githubusercontent.com"
      subject: "https://github.com/controlplaneio-fluxcd/charts/*"
```

So the OpenTofu pin is a bootstrap floor, not the running version — after Stage
2 the operator tracks the semver range, and every chart version is checked
against a keyless cosign signature from the publisher's GitHub Actions identity
before it is installed. The `FluxInstance` itself stays OpenTofu-owned: the
thing that describes the installation is created by the same apply that creates
the cluster, so a cluster is never half-bootstrapped.

### Preview environments per pull request

`ResourceSet` and `ResourceSetInputProvider` are the operator's own CRDs, and
`flux/previews/` uses them to build one namespace per pull request:

```yaml
# flux/previews/input-provider.yaml
spec:
  type: GitHubPullRequest
  url: https://github.com/Smana/cloud-native-ref
  filter:
    labels: [preview]     # opt-in per PR, not every PR
    limit: 5
```

Each matching PR renders a `Namespace`, a `GitRepository` pinned to the PR's
commit SHA, and a `Kustomization` applying `./apps/aws-0` into its own
`preview-pr-<id>` namespace. The operator's `<< inputs.* >>` templating is
evaluated before Flux's own `${var}` substitution runs on the generated
Kustomization — two layers, which is why both can appear in the same file.

The `ResourceSet` runs under a `flux-previews` ServiceAccount whose ClusterRole
grants three resources and nothing else: `namespaces`, `gitrepositories`,
`kustomizations`. A generator that creates cluster-scoped objects from the
content of a pull request is exactly where least privilege has to be real.

Previews run on `aws-0` only — `clusters/gcp-0/flux/` has no `flux-previews`
Kustomization.

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

### Two web UIs, and why both

The CLI is the primary interface, but reconciliation state is also worth
looking at, and two things serve it:

| | Hostname | Behind | Reachable by |
|---|---|---|---|
| **Flux UI** | `flux-ui-<cluster>.priv.<cloud>.ogenki.io` | `platform-tailscale-admin` | `tag:admin` |
| **Headlamp** | `headlamp.priv.<cloud>.ogenki.io` | `platform-tailscale-general` | `tag:k8s` |

**The Flux UI** ships with the Flux Operator — `web.enabled: true` in
`flux/operator/helmrelease.yaml` — and is the operator's own view of
`FluxInstance`, Kustomizations, HelmReleases, sources and events. It sits on
the **admin** Gateway, not the general one; see
[Private access]({{< relref "/docs/platform/networking/private-access.md" >}})
for the ACL that backs the two tags.

It authenticates against ZITADEL over OIDC and then **impersonates the
logged-in human**:

```yaml
impersonation:
  username: "claims.email"
  groups: "claims.groups"
```

So the UI holds no standing privilege of its own — Kubernetes RBAC decides what
each person can do, and the API server's audit log carries their email rather
than a service account name. `flux/operator/rbac.yaml` binds the ZITADEL
groups: `admin` to `cluster-admin`, and `backend`, `frontend` and `data` to
`edit`. The full identity chain is in
[Authentication]({{< relref "/docs/platform/security/authentication.md" >}}).

**Headlamp** is the general-purpose cluster UI, and it carries a Flux plugin —
`ghcr.io/headlamp-k8s/headlamp-plugin-flux`, pinned, installed by an init
container alongside the cert-manager and AI-assistant plugins. It is the one to
reach for when a Flux failure turns out not to be a Flux problem: the plugin
puts Kustomization and HelmRelease state next to the Pods, Events and logs of
whatever they created, without leaving the page.

The two differ in what they can show *per person*. The Flux UI impersonates on
both clusters. Headlamp does on `aws-0`, where EKS is configured to trust
ZITADEL directly — but not on `gcp-0`, where GKE cannot be, so Headlamp sits
behind oauth2-proxy and talks to the API server as its own ServiceAccount. The
per-user RBAC tiers collapse to one there, which is the trade
[ADR-0026]({{< relref "/docs/decisions/0026-headlamp-auth-proxy-on-gke.md" >}})
records and accepts.

Flux also reports on itself: `flux/observability/` ships its Grafana
dashboards and alert rules, and `flux/notifications/` sends reconciliation
failures to Slack, so a Kustomization that goes Failed at 3am is a message
rather than a surprise the next morning. For walking the full Flux →
Kubernetes → Crossplane chain on a live cluster, see
[Troubleshooting]({{< relref "/docs/guides/troubleshooting.md" >}}).

## Validation before any of this applies

Every manifest above is rendered and gated before it reaches `main` — see
[Validation]({{< relref "/docs/platform/gitops/validation.md" >}}).
