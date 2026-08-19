<!-- MIRROR of Smana/crossplane-configuration:docs/kcl-authoring.md @ ddc6717
     Upstream is authoritative. Kept here so the platform docs site can publish it.
     Update by re-copying from upstream; see the note at the foot of this page. -->

> **This page is mirrored.** The compositions it describes live in
> [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration), and so does
> the authoritative copy of this page — [`docs/kcl-authoring.md`](https://github.com/Smana/crossplane-configuration/blob/main/docs/kcl-authoring.md).
> Edit it there. This copy exists so the platform documentation site can publish composition
> authoring guidance alongside everything else.

# Authoring KCL compositions

The Compositions in `crossplane-configuration` are generated: `apis/<api>/kcl/main.k` is the source of truth and
`task generate` inlines it into `apis/<api>/composition.yaml` as a block scalar. **Never edit the
inlined copy** — CI regenerates and fails if the two disagree.

Inlining is why a published package pulls nothing at render time. It also means the KCL modules are
no longer published as OCI artifacts; the `version` field surviving in each `kcl.mod` is vestigial
metadata that nothing reads.

## The five rules

**1. Always `kcl fmt`.** CI formats in place and fails if the tree changes. `kcl fmt` has no
`--check` flag (0.11.3), which is why `task test` formats then diffs.

**2. Never mutate a dict after creation.** This is the one that silently doubles your output.
function-kcl hashes each resource at creation; mutating it produces a second hash, so *both*
versions appear in the rendered result ([function-kcl#285]). Use inline conditionals instead:

```kcl
# WRONG — yields two Deployments in the rendered output
_deployment = {metadata.annotations = {}}
if _ready:
    _deployment.metadata.annotations["krm.kcl.dev/ready"] = "True"

# RIGHT — decided at creation
_deployment = {
    metadata.annotations = {
        if _ready:
            "krm.kcl.dev/ready" = "True"
    }
}
```

The same trap in other shapes: conditional field assignment (`if c: r.field = v`), dictionary update
(`r.metadata.labels["k"] = "v"`), and accumulating into a resource inside a loop. Compute values
*first*, then build the resource once.

**3. List comprehensions must be single-line.** Multi-line ones fail CI.

**4. Don't shadow the loop variable in a dict comprehension.** `[{name = name} for name in xs]`
writes the *value* as both key and value — you get `{<value>: <value>}`, not `{name: <value>}`.
Rename the loop variable: `for n in xs`. The symptom is remote and confusing: Kubernetes rejects the
rendered manifest with `field not declared in schema`.

**5. Validate with `task check`.** Runs generate-sync, `kcl fmt` + `kcl test`, XRD schema validation
of the example claims, and render equivalence against the golden fixtures in `tests/golden/`.

[function-kcl#285]: https://github.com/crossplane-contrib/function-kcl/issues/285

## Catching a mutation bug

The failure is duplicate resources in the rendered output, so look there rather than at the source:

```bash
task render                      # diffs every example against tests/golden/
crossplane render examples/app-basic.yaml apis/app/composition.yaml functions.yaml \
  | grep -c "^kind: Deployment"  # >1 for a single-Deployment claim means duplicates
```

Grepping the source finds candidates but not proof — a post-creation assignment is only a bug if the
resource is one function-kcl emits:

```bash
grep -rn '^\s*_[a-zA-Z]*\.[a-zA-Z]' apis/*/kcl/main.k     # field assignment after creation
grep -rn '\["[^"]*"\] = ' apis/*/kcl/main.k               # dictionary update
```

## Readiness

Native Kubernetes resources are marked ready by inspecting observed cluster state through
`option("params").ocds`, then setting `krm.kcl.dev/ready` conditionally:

| Kind | Ready when |
|---|---|
| `Deployment` | `status.conditions[type=Available, status=True]` |
| `Service` | `spec.clusterIP` assigned |
| `HTTPRoute` | `status.parents[].conditions[type=Accepted, status=True]` |
| `AIGatewayRoute` | top-level `status.conditions[type=Accepted, status=True]`; rendering additionally latched on Deployment readiness |

```kcl
_observed = ocds.get(_name + "-deployment", {})?.Resource
_ready = any_true([c.get("type") == "Available" and c.get("status") == "True" for c in _observed?.status?.conditions or []])
```

**Always ready when created** (no observed state to wait on): HPA, PDB, Gateway,
CiliumNetworkPolicy, HelmRelease, Backend, AIServiceBackend.

**Report real conditions** (they are XRs with their own status): SQLInstance, EKSPodIdentity,
S3 Bucket.

## Crossplane v2 traps

These describe how the *cluster* behaves, so they bite when a composition is deployed rather than
when it renders.

1. **Managed resources are namespaced** in provider-aws v2.x (`m.upbound.io`), where v1's
   `upbound.io` was cluster-scoped. Every direct MR needs `metadata.namespace`. Symptom:
   `<Kind>/<name> namespace not specified` on a Flux dry-run.
2. **`ManagedResourceActivationPolicy` gates which CRDs install.** Provider packages ship dozens;
   only those listed in the consuming cluster's activation policy exist. Adding a new MR Kind to a
   composition usually means adding its plural CRD name there too. Symptom: `no matches for kind`.
3. **Compositions writing third-party Kinds need an aggregate ClusterRole.** The Crossplane SA only
   gets RBAC for what its providers manage; `keda.sh/scaledobjects`, `batch/jobs` and friends need
   an explicit grant labelled `rbac.crossplane.io/aggregate-to-crossplane: "true"`. Symptom:
   the XR reconcile loops on `Timeout: failed waiting for ... Informer to sync`.
4. **A fresh CRD's informer can stall even with RBAC in place.** Check the cheap deterministic thing
   first — `kubectl auth can-i --as=system:serviceaccount:crossplane-system:crossplane list <plural> -A`
   — and if that says `yes` while the timeout persists, restart the controller.

## Security and policy checks — a known gap

**Nothing automatically audits the workloads these Compositions produce.** Worth stating plainly,
because the platform constitution implies otherwise.

`cloud-native-ref`'s `./scripts/validate-manifests.sh` runs Polaris over its rendered bundle, but
that bundle contains the *claims* (`kind: App`), not the Deployments Crossplane expands them into at
runtime — those objects only ever exist in-cluster, so Polaris never sees them. The retired
`validate-kcl-compositions.sh` had three stages (`kcl fmt`, `kcl run`, `crossplane render`); the
Polaris ≥85 / kube-linter / Datree row in the constitution's validation table described an agent
workflow, never a script.

So a composition that drops `readOnlyRootFilesystem` or `seccompProfile` from its pod spec passes
every gate in both repos. Review pod specs by hand until this is closed.

The fix is cheap and belongs in `crossplane-configuration`: `task render` already writes rendered
output for all 12 examples, which is exactly the input a Polaris audit wants.

---

## Keeping this page in sync

Upstream (`crossplane-configuration`) is the source of truth: it holds the code, the CI that
enforces these rules, and the release the platform pins.

There is **no automated check** that this mirror matches upstream — the two can drift silently
today. When the documentation site is built, prefer fetching this file from the tag pinned in
`infrastructure/base/crossplane/configuration/configuration-packages.yaml` at build time over
keeping a copy in git. That removes the duplication rather than policing it, and guarantees the
published page describes the API version the cluster actually serves.
