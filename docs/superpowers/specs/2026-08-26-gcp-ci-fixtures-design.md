# Per-cluster CI rendering and the undefined-variable gate — workstream 15

**Date:** 2026-08-26
**Status:** approved, not yet implemented
**Workstream:** 15 of the [GCP support programme](2026-08-18-gcp-support-design.md)

## Problem

Flux substitutes `${var}` from a per-cluster ConfigMap. Nothing checks that a variable a cluster
*applies* is a key that cluster *defines*, and an undefined variable does not fail — it renders as an
empty string. Schema-valid, silently wrong.

This has recurred. Workstream 9 alone needed `storage_class`, `openbao_cidr` and
`openbao_snapshot_secret` added to both clusters' ConfigMaps, and in each case the only thing that
caught the omission was a human remembering to add a fixture entry. `render-bundle.py` says so about
one of them:

> Without this entry `VAR_RE.sub` passes the name through verbatim and the ExternalSecret silently
> extracts nothing: schema-valid, useless, and gate 1 would never catch it since the target field is
> a free-form string.

A second, related gap: `FIXTURE_VARS` is one flat map used for every cluster, so `gcp-0` overlays
render with AWS values. The file documents this as a known lie:

> this single map cannot tell which cluster is rendering. So it stays AWS-shaped for both, which
> means the gcp-0 bundle would render a region that cluster never substitutes — the blind spot that
> let `region: ${region}` reach review.

## Scope

Two parts. **Part A is the gate; Part B is honest output.** Only Part A catches errors
automatically, and the design says so rather than implying otherwise.

Out of scope, deliberately: Renovate coverage and per-cloud schema catalogs, both named in the
workstream 15 roadmap row. The catalogs already have their seam — `gen-catalog.sh` derives the
version from the package pin and fetches the release's `xrd-crds.yaml` asset — and Renovate's GCP gap
is unmeasured. Neither belongs in a change whose value is the gate.

## Part A — every applied variable must exist in that cluster's ConfigMap

Extend `scripts/flux-schema/check-substitution.py`. It already has both halves of what is needed:

- `flux_kustomizations()` — every Flux Kustomization under `clusters/`, with its `spec.path` and
  `postBuild`. The cluster is the path segment: `clusters/<cluster>/…`.
- `rendered_vars(path)` — the variables that path applies, via `kustomize build` (so cross-tree
  `../../base/foo.yaml` references are followed), with `$${var}` escapes stripped first.

What is missing is the other side: which keys the named ConfigMap actually has.

### Reading the ConfigMap keys

Both `configure` stacks declare it identically:

```hcl
resource "kubectl_manifest" "flux_cluster_vars" {
  yaml_body = yamlencode({
    ...
    data = {
      cluster_name = var.cluster_name
      region       = var.region
      ...
```

Extraction is anchored on that resource name and the `data = {` block inside it, collecting
`^\s+(\w+)\s*=` up to the closing brace. Verified: neither block contains a heredoc, a nested brace,
a ternary or a list, and comments interleave harmlessly.

This is **not** general HCL parsing, which `check-substitution.py`'s own docstring rightly calls
fragile. It is one well-known block with a stable anchor. If that anchor ever moves, the extractor
must **fail loudly** rather than return an empty key set — an empty set would make every variable
look undefined, or worse, a silently-skipped file would make every variable look fine. The check
asserts a non-empty result per cluster.

### The check

For each Kustomization: `applied − defined` must be empty. A miss reports the cluster, the
Kustomization, the variable and the ConfigMap it should have been added to.

Because this walks the cluster graph rather than the filesystem, it is precise about `base/`:

- a base directory referenced only by `aws-0` is checked only against `aws-0`'s keys;
- one referenced by **both** clusters must satisfy **both**, which is the property that makes a
  shared manifest genuinely cloud-neutral.

That precision matters, because `base/` is not uniformly shared. `infrastructure/base/karpenter` and
`infrastructure/base/aws-load-balancer-controller` use AWS-only variables and `gcp-0` never
references them; `infrastructure/base/crossplane` contains both AWS- and GCP-specific subtrees. A
filesystem-level rule would flag all three as broken. The cluster graph does not.

## Part B — per-cluster fixtures

Split `FIXTURE_VARS` into a shared map plus per-cluster maps, and select by the overlay root's path
segment (`<area>/aws-0/…`, `<area>/gcp-0/…`).

**Roots under `base/` keep the merged map.** They exist in the bundle only because
`top_most_overlays()` treats a nested-but-unreferenced directory as a root — nothing deploys them,
and Part A already enforces their correctness through the cluster graph. Rendering them twice was
considered and rejected: with hard-fail it flags the three legitimately cloud-specific directories
above, and without hard-fail it doubles the bundle for no gate.

### What Part B does and does not buy

It does **not** add a gate. GCP-shaped values are still strings to the schema validator, so a wrong
GCP value passes exactly as an AWS-shaped one does.

What it removes is a documented falsehood in the artifact reviewers read. Workstream 9's bucket
naming is the worked example: `${region}-ogenki-<name>` is a legal GCS bucket name that the
Crossplane principal's IAM condition forbids creating, because that condition requires a
`<project_id>-ogenki-` prefix. Under per-cluster fixtures the GCP bundle would have shown
`europe-west4-ogenki-openbao-snapshot` — visible to a reviewer comparing it against the condition.
It would still not have failed CI, because the thing that rejected it was an IAM condition no gate in
this repo evaluates.

Stating that plainly is the point. A change that makes output more honest is worth making; claiming
it would have caught the bug would be the same overreach this workstream exists to remove.

## Success criteria

1. A variable applied by a cluster but absent from that cluster's ConfigMap fails
   `check-substitution.py`, naming cluster, Kustomization, variable and target ConfigMap.
2. Removing any one of `storage_class`, `openbao_cidr`, `openbao_snapshot_secret` from a ConfigMap
   reproduces that failure — the three real omissions this gate exists for.
3. A base directory referenced by both clusters fails if a variable is missing from either.
4. A base directory referenced by one cluster does not fail for the other cluster's variables.
5. `gcp-0` overlays in `.bundle/` render GCP values; `aws-0` overlays are byte-identical to today.
6. The ConfigMap extractor fails loudly if its anchor disappears, rather than returning an empty set.

## Sequencing note

`FIXTURE_VARS` is edited by two open PRs — #1841 adds `storage_class`, #1844 adds `openbao_cidr` and
`openbao_snapshot_secret`. Restructuring it will conflict with both. The conflicts are additive and
trivial to resolve; this is recorded so whoever merges is not surprised.
