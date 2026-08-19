# Crossplane Configuration Extraction — Design

**Date:** 2026-08-18
**Status:** design approved, plan pending
**Branch:** `feat/crossplane-configuration-extraction`
**Related:** [GCP Support — Dual-Cloud Platform Design](2026-08-18-gcp-support-design.md) workstream 7,
[ADR-0007](../../decisions/0007-cloud-abstraction-boundaries.md)

---

## Why this design exists

The platform's Crossplane API surface — 5 XRDs, 5 Compositions, 5 KCL modules — lives inside
`cloud-native-ref`, the repository that also holds the cluster it happens to run on. Nobody can adopt
`App` or `SQLInstance` without cloning a repository full of one specific EKS cluster's wiring, and
nothing forces the API to stay separable from that wiring.

The [GCP design](2026-08-18-gcp-support-design.md) listed this extraction as workstream 7, gated
behind the directory refactor (workstream 6). **That ordering is reversed here.** The refactor's
purpose is to partition the repo by cloud; doing it first means partitioning files that are about to
leave. Extracting first shrinks what the refactor has to move, and the extraction is the step that
forces the AWS coupling to become explicit — which is the information the refactor needs.

This is a **relocation, not a redesign**. No XRD schema changes, the `cloud.ogenki.io` group is
untouched, and no Composition changes behaviour. GCP content is explicitly out of scope; this only
makes room for it.

## Verified during design (evidence, not assumption)

| Question | Finding | How |
|---|---|---|
| Are the KCL modules safe to inline? | **Yes, by construction.** All 5 are a single non-test `main.k`, importing only KCL stdlib (`json`, `yaml`), with empty `[dependencies]` in `kcl.mod` | `ls kcl/*/*.k`, `grep '^import' kcl/*/main.k`, `kcl.mod` |
| Does the YAML block scalar corrupt the KCL? | **No.** All 5 modules round-trip byte-identical (SHA-256 match), largest 62 048 B | `yaml.safe_dump(default_style="\|")` → `safe_load` → sha256 compare |
| Do the XRDs carry Flux `postBuild` vars? | **No.** All 9 `${...}` vars live in `environmentconfig.yaml` alone, which stays behind | `grep '\${' *.yaml` |
| Does anything else read the XRD files by path? | **Yes, two consumers** — see *Blockers* | `gen-catalog.sh:106`, `wizard.yaml:20,30-32` |
| Does Crossplane here support Configuration packages with function dependencies? | Yes — Crossplane **2.3.4** | `controller/helmrelease.yaml:16` |
| Current KCL validation baseline | `./scripts/validate-kcl-compositions.sh` → exit 0, 5 modules fmt + syntax clean | fresh run |
| **Does an inlined Composition render identically to the OCI module?** | **Yes — 12/12 examples byte-identical**, across all 5 Compositions, 2 480–25 433 B each | `crossplane render` both ways, `cmp` |
| Does the validator cover every example? | **No** — `inferenceservice-endpointpicker.yaml` exists but is absent from the `COMPOSITIONS` array; 12 examples, 11 tested | `validate-kcl-compositions.sh:55-60` |

The render equivalence result is the migration's central premise and it is **settled, not assumed**.
Each of the 12 claim examples was rendered twice — once through the current
`source: oci://ghcr.io/smana/cloud-native-ref/crossplane-<mod>:<ver>` Composition and once through a
generated Composition with `main.k` inlined — and compared with `cmp`. All 12 are byte-identical,
including the 1291-line `app` module and the 1144-line `inference-service` module.

The prototype generator that produced the inlined Compositions is ~25 lines: parse the Composition,
find the pipeline step whose `input.spec.source` starts with `oci://`, resolve the module name from
the `crossplane-<mod>:` segment, and substitute the file contents. It becomes `make generate`.

## Measured cloud coupling

The seam had to be located before the packages could be cut.

| XRD | AWS-coupled | Evidence in `main.k` |
|---|---|---|
| `KVStore` | none | 0 matches for `aws\|gcp\|upbound` |
| `InferenceService` | no managed AWS resources | `karpenter.sh/nodepool`, `runtimeClassName: nvidia` only |
| `EPI` | total | `iam.aws.m.upbound.io`, `eks.aws.m.upbound.io` |
| `SQLInstance` | partial | CNPG neutral; barman backup pulls `iam.aws` ×3, `eks.aws` ×1 |
| `App` | partial | `s3Bucket` ×25, `s3.aws.m.upbound.io` ×2 |

Three of five are **mixed**: a neutral contract with an AWS slice inside it. So the split cannot be
drawn at the XRD level — there is one `apps.cloud.ogenki.io` CRD, and two packages both shipping it
is an ownership conflict Crossplane refuses.

It can be drawn one layer down. **A Composition need not ship in the same package as its XRD**; it
only names `compositeTypeRef`. That is the same seam the GCP design's workstream 8 already assumes
(*"`objectStore` API migration + `App`/`SQLInstance` branching"*).

## Decisions

| Decision | Outcome |
|---|---|
| Repository | `github.com/Smana/crossplane-configuration` |
| Delivery | Crossplane **Configuration packages** (xpkg), not raw YAML via Flux |
| KCL delivery | **Inlined** into the Compositions, generated and sync-checked in CI |
| Package cut | `-core` (neutral contracts) + `-aws` (AWS implementations); `-gcp` created when it has content |
| Versioning | Lockstep from one git tag, both starting `0.1.0` |
| API group | **Unchanged** — `cloud.ogenki.io` |

### Naming

`crossplane-configuration`, with the scope suffix on the *package* rather than the repository.

Searched the namespace first. Two conventions dominate and both are small enough to win:
`configuration-<scope>` (upbound, 20+ repos, including `configuration-aws-eks-pod-identity` — our
`EPI`) and `platform-ref-<scope>` (upbound, `platform-ref-aws` at 117★, the most-starred repo in the
niche). The bare `crossplane-configuration` name is currently held only by 0★ repositories.

Rejected: anything built on `platform-apis`. GitHub search for that token returns appsmith (40k★),
insomnia (39k★) and wgpu (17k★) — the term is drowned. `crossplane configuration` returns a page
whose top hit is 12★, a namespace a new repository can actually own.

The repository name omits `ogenki`, so discovery from `apiVersion: cloud.ogenki.io/v1alpha1` rests on
topics and description: `crossplane`, `crossplane-configuration`, `xrd`, `kcl`,
`platform-engineering`, `gitops`.

### Why inline the KCL

Publishing the modules as separate OCI artifacts is what happens today, and it costs a standing tax:
5 independently-versioned tags, the `-prN` pin flip on every PR, a whole `validate-composition-versions`
CI job that exists only to police those pins, and the `kcl mod push` trap where the tag in the URL is
ignored in favour of `kcl.mod`'s `version` field. A dangling `crossplane-app:0.1.10-pr1434` pin sat
on `main` undetected because a failed publish skipped the audit that would have caught it.

Inlining deletes all of it. `main.k` stays the editable source — `kcl fmt`, `kcl test`, and review all
operate on it — and `make generate` embeds it into `composition.yaml`, with CI running
`make generate && git diff --exit-code`. The committed Composition is the real artifact, so
`crossplane render` works on it directly with no build step.

The cost is that the modules stop being independently consumable. Nothing consumes them
independently today.

## Architecture

### Package topology

```
crossplane-configuration-core
    XRDs         App, SQLInstance, KVStore, InferenceService
    Compositions kvstore
    dependsOn    function-kcl, function-auto-ready, function-environment-configs

crossplane-configuration-aws          dependsOn: crossplane-configuration-core
    XRD          EPI
    Compositions app, sql-instance, inference-service, epi

crossplane-configuration-gcp          (created in GCP workstream 8, not now)
    XRD          GCPWorkloadIdentity
    Compositions per-cloud App / SQLInstance / InferenceService
```

`EPI`'s **XRD sits in `-aws`, not `-core`**. Both halves of it are wholly AWS; leaving the XRD in
core would advertise `epis.cloud.ogenki.io` on a GKE cluster that can never satisfy it. Core holds
only the four genuinely shared contracts.

A GCP-only adopter installs `-core` + `-gcp` and receives no AWS CRD and no AWS Composition.

### What moves, what stays

| Stays in `cloud-native-ref` | Why |
|---|---|
| `environmentconfig.yaml` | 9 Flux `${...}` postBuild vars — cluster identity |
| `cluster-providerconfig-aws.yaml` | cluster credentials |
| `providers/`, `activation-policy.yaml`, `additional-rbac.yaml` | cluster wiring |
| `functions.yaml` | **corrected** — also cluster wiring. `Function` objects are cluster-scoped install manifests and cannot live inside a Configuration package. Deleting it would make Flux prune the Functions while the packages' `dependsOn` reinstalls them, for no gain |
| ~37 claims across 42 files | the consumers |
| **new** — 2 `Configuration` manifests | the pins |

Moves: 5 XRDs, 5 Compositions, 5 KCL modules, `examples/`,
`scripts/validate-kcl-compositions.sh`, `scripts/flux-schema/xrd-to-crd.py`.

The new repository keeps its **own** `functions.yaml` for local `crossplane render` and for the
App Wizard's preview, and declares the same versions as `dependsOn` for external adopters. CI
asserts the two agree, so the duplication cannot drift silently.

### Repository layout

```
crossplane-configuration/
├── apis/
│   ├── app/               definition.yaml  composition.yaml  kcl/{main.k,main_test.k,kcl.mod}
│   ├── sqlinstance/       …
│   ├── kvstore/           …
│   ├── inferenceservice/  …
│   └── epi/               …
├── packages/
│   ├── core/crossplane.yaml
│   └── aws/crossplane.yaml
├── examples/              12 claim examples (environmentconfig.yaml stays behind)
├── scripts/               generate.sh  validate.sh  xrd-to-crd.py
├── Makefile               generate | test | render | build | push
└── .github/workflows/     ci.yaml  release.yaml
```

`composition.yaml` is generated; `main.k` is the source of truth.

## Blockers this design must solve

Both were found by inspection and would fail *silently* on a naive move.

### 1. The schema catalog is built from the XRD files

`scripts/flux-schema/gen-catalog.sh:106` globs
`infrastructure/base/crossplane/configuration/*-definition.yaml`, and `.fluxschema.yml` sets
`skipMissingSchemas: false`. Move the XRDs and every `cloud.ogenki.io` claim — ~37 of them across 42
files — fails validation rather than being skipped. That is precisely the failure mode SPEC-007 was
written to eliminate, so it cannot be waived.

**Solution.** `xrd-to-crd.py` moves to the new repository, whose release CI attaches the converted
`xrd-crds.yaml` to each GitHub release. `gen-catalog.sh` fetches it at the version already pinned in
the `Configuration` manifest. One version string then drives both the installed package and the
schemas it is validated against, so the two cannot drift. The script already fetches remote catalogs
and Helm charts, so this introduces no new class of dependency.

### 2. The App Wizard reads four files by path

`apps/platform/app-wizard/wizard.yaml:20,30-32` sets `xrdPath`, `compositionPath`, `functionsPath`
and `envConfigPath`, resolved under `REPO_ROOT=/repo` where an initContainer clones this repository.

**Solution.** A second initContainer clones `crossplane-configuration` at the pinned tag into
`/repo/.crossplane-configuration/`, so the paths stay repo-relative. Three of the four are
repointed; `envConfigPath` is unchanged because the EnvironmentConfig stays behind. **No app-wizard
code change** — the alternative, absolute paths, would need one, since only `uiHintsPath` is
documented as absolute-capable.

## Cutover

Three stages. `cloud-native-ref` is not modified until stage 2, and stage 1 leaves both worlds valid
and independently deployable.

**Stage 1 — build the new repository.** Move files, generate the Compositions, wire CI, publish
`0.1.0`. `cloud-native-ref` is untouched and keeps running from its own OCI modules. Nothing is
reversible-with-difficulty yet.

**Stage 2 — cut over, atomically, in one PR.** Add the 2 `Configuration` manifests; repoint
`gen-catalog.sh` and `wizard.yaml`; delete `configuration/*-{definition,composition}.yaml`,
`configuration/kcl/`, `configuration/examples/`, `functions.yaml`,
`.github/workflows/crossplane-modules.yml`, `scripts/validate-kcl-compositions.sh`. Gate:
`./scripts/validate-manifests.sh` → exit 0 with `Invalid: 0, Skipped: 0`.

**Stage 3 — verify on the cluster.** The packages own the XRDs, every pre-existing claim is still
`Synced=True` / `Ready=True`, and no claim was recreated.

Ordering constraint: the Configuration packages must be installed and healthy **before** the Flux
Kustomization prunes the old XRDs, or claims briefly lose their CRDs.

## Success criteria

1. `crossplane-configuration` publishes `-core` and `-aws` at `0.1.0`, both pullable anonymously.
2. Rendering each of the 12 claim examples through the inlined Compositions produces output
   byte-identical to rendering through today's OCI modules. **Already proven during design** (12/12);
   the plan re-runs it in the new repository's CI as a standing regression gate, and closes the
   `inferenceservice-endpointpicker.yaml` coverage gap while doing so.
3. `./scripts/validate-manifests.sh` → exit 0, `Invalid: 0, Skipped: 0`, with the XRD schemas sourced
   from the release asset.
4. `kubectl get app,sqlinstance,kvstore,epi,inferenceservice -A` shows the same objects as before,
   `Synced=True` / `Ready=True`, with unchanged `metadata.uid` — proving adoption, not recreation.
5. The App Wizard renders an `App` preview successfully.
6. `cloud-native-ref` contains no `oci://ghcr.io/smana/cloud-native-ref/crossplane-*` reference.

## Risks

| Risk | Mitigation |
|---|---|
| Package install re-creates XRDs, transiently orphaning claims | **Measured 2026-08-19 on kind, and it does not.** Installing the published `-aws:v0.1.0` over five XRDs applied the old way left all 20 identities — 5 XRDs, 5 CRDs, 5 Compositions, 5 claims — byte-identical by `uid`. Crossplane adopts the existing objects and takes controller ownership via `ownerReferences` on the `ConfigurationRevision` |
| `dependsOn` on providers conflicts with the cluster's own `Provider` manifests | Declare only function and configuration dependencies in `crossplane.yaml`; the cluster already owns its providers |
| Inlined 1291-line `main.k` makes `composition.yaml` unreviewable | Review happens on `main.k`; CI proves the generated file matches. Both the YAML round-trip and full render equivalence are already verified |
| `ManagedResourceActivationPolicy` interferes with package-installed XRDs | The policy governs provider MR CRDs, not XRDs — expected unaffected, asserted in stage 3 |
| Schema catalog fetch becomes a network dependency of CI | Already true for the Flux and CNCF catalogs; pin by version and fail loudly |
| **Flux prunes the old XRDs and destroys every claim** | **Measured 2026-08-19 on kind with real Flux, and the single-PR cutover is fatal.** Removing the old manifests in the same commit that adds the `Configuration` makes kustomize-controller `DELETE` the five XRDs it still has in inventory. That cascades to the CRDs and *every claim is permanently lost* — all 13 identities changed, 3/3 claims `GONE`, Crossplane then recreated empty XRDs from the package. Adoption does not protect against this: the objects are adopted but stay in Flux's inventory. **Stage 2 must therefore be two PRs** — see below |
| Stage 2 is large and atomic | ~~It is a cutover; a partial one leaves claims without CRDs. Size is the price of atomicity.~~ **Reversed by the prune finding above:** atomicity is what destroys the claims. The safe sequence is two PRs, verified end-to-end on kind with all 13 identities preserved |

## Stage 2 cutover sequence (revised 2026-08-19)

Verified on kind against real Flux and the published `v0.1.0` packages. The naive single-PR
cutover was run first and destroyed every claim; this sequence was then run from the same
starting state and preserved all 13 identities.

**PR A — adopt, prune nothing.** Add the two `Configuration` manifests *and* annotate every old
XRD and Composition with `kustomize.toolkit.fluxcd.io/prune: disabled`. The old files stay in
git. Flux applies both; the packages adopt the existing XRDs.

```yaml
commonAnnotations:
  kustomize.toolkit.fluxcd.io/prune: disabled
```

Verify before proceeding: both `Configuration`s `INSTALLED=True HEALTHY=True`, and every claim's
`metadata.uid` unchanged.

**PR B — delete the old files.** With prune disabled on those objects, Flux drops them from its
inventory without issuing a `DELETE`. The XRDs remain, now owned solely by the
`ConfigurationRevision`.

Two details observed during the test:

- The `-core` package is pulled in by `-aws`'s `dependsOn` and lands as
  `smana-crossplane-configuration-core` — a registry-derived name, not the one in
  `packages/core/crossplane.yaml`. It is created by Crossplane, so it is **not** in Flux's
  inventory and is not pruned when the source changes. Declare only `-aws` in git.
- The adopted XRDs keep their `kustomize.toolkit.fluxcd.io/*` labels after PR B. Cosmetic —
  the labels are inert once the objects leave the inventory. `resourceVersion` held steady over
  90s, so Flux and Crossplane are not fighting over them.


## Open questions

- Does `InferenceService` belong in `-core`? It has no AWS managed resources but hardcodes
  `karpenter.sh/nodepool` and `runtimeClassName: nvidia`, both of which change on GKE. Its XRD is in
  `-core` and its Composition in `-aws`, which is consistent — but this is the one placement to
  revisit in GCP workstream 8.
- Does the App Wizard eventually read XRDs from the cluster rather than from a clone? That would
  remove the second initContainer, but is an app-wizard change and out of scope here.
- ~~Should `examples/` be flat or per-API?~~ **Decided: flat**, because
  `crossplane xpkg build --examples-root` takes exactly one directory, and the build stages the
  per-package subset anyway.
- Does `crossplane-configuration` become the home of the App Wizard's `ui-hints.yaml` too? It is
  XRD-shaped metadata living in `cloud-native-ref` today.
