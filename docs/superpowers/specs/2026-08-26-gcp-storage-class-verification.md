# Portable storage classes — workstream 13 — verification

Verifies: `docs/superpowers/specs/2026-08-26-gcp-storage-class-design.md`
Plan: `docs/superpowers/plans/2026-08-26-gcp-storage-class.md`
Implementation: `62e2c0c5` (Task 1, publish `storage_class`), `c7a508da` (Task 2, substitute 8 sites),
`cca9c3a9` (Task 3, CI fixture)

## Scope note: no cluster deploy

**Deliberate, not an oversight — but see the correction below before reading this claim as settled.**
Both `aws-0` and `gcp-0` are torn down. The change is a build-time substitution — a Kustomize/Flux
`postBuild.substituteFrom` variable resolved at render time — and the rendered bundle is the artifact
that proves *that mechanism*, byte for byte, the same content Flux would apply on a live cluster.

What a deploy would additionally prove is a separate claim this document got wrong on its first pass:
that GKE actually has a StorageClass named `standard-rwo` (originally written here as `balanced-rwo`,
which does not exist on GKE at all — see the design doc's "The problem" section for the correction
and its in-repo evidence). That is not a fact this change controls, and it is **not a guarantee** —
an earlier draft of this document called it one, which was itself part of the defect: a claim
checked by a method structurally incapable of checking it, upgraded to a guarantee to explain why no
other method was needed. It is corroborated in-repo (`opentofu/gcp/gke/init/helm_values/flux-instance.yaml`
already runs `standard-rwo` successfully on a deployed `gcp-0`), which is materially stronger than an
assumption, but it is still not verified for *these eight manifests specifically*, and the rendered
bundle cannot verify it either — see criterion 1. Every criterion below is checked against the
rendered bundle and the two source-of-truth ConfigMap definitions; criterion 1 says plainly where
that method's reach ends.

## Success criteria

### 1. Every affected manifest renders `gp3` in `aws-0`'s bundle and `standard-rwo` in `gcp-0`'s

**Marked NOT CHECKABLE BY THE AVAILABLE METHOD, not PASS — see the correction below.** An earlier
draft of this document marked this criterion PASS on the evidence in this section. That was wrong,
and not only because the value was wrong (`balanced-rwo`, which does not exist on GKE — see the
design doc's "The problem" section). The criterion's subject is "does the GCP value work" — does it
name a class GKE actually provides — and no command below, then or now, can answer that. Marking it
PASS on this evidence is exactly the failure mode criterion 4 exists to name: a claim checked by a
method structurally incapable of checking it.

`render-bundle.py` uses **one** `FIXTURE_VARS` map for both clusters (see Task 3), so the rendered
`.bundle/` cannot show a per-cluster difference — it renders whatever the fixture says (`gp3`) for
every overlay, `aws-0` and `gcp-0` alike. The actual per-cluster values live only in the two
ConfigMaps that Flux substitutes from on a real cluster:

```
$ grep -n 'storage_class' opentofu/aws/eks/configure/kubernetes.tf
70:      storage_class          = "gp3"

$ grep -n 'storage_class' opentofu/gcp/gke/configure/kubernetes.tf
67:      storage_class = "standard-rwo"
```

`gp3` on `aws-0`, `standard-rwo` on `gcp-0` — this is what the ConfigMaps publish today, corrected
from `balanced-rwo` after review (see `opentofu/gcp/gke/configure/kubernetes.tf`'s comment for the
in-repo corroboration: `opentofu/gcp/gke/init/helm_values/flux-instance.yaml` already runs
`standard-rwo` successfully on a deployed `gcp-0`, for a different resource). **This grep only shows
what the ConfigMap publishes, which is exactly what the branch's own diff already shows — it does not
independently establish that GKE provides a class by that name.** That fact was, and remains, outside
what any command in this repository can check while both clusters are destroyed. The bundle's
single-fixture limitation compounds this — it cannot show a per-cluster difference at all — but even
a bundle that could would still only show the *name being applied*, not whether GKE *has* a class by
that name.

Corroborating the fixture side — every one of the 8 call sites renders a real value (not a literal)
in the shared-fixture bundle:

```
$ grep -rc 'storageClassName: gp3\|storageClassName: "gp3"' .bundle/ | grep -v ':0' | wc -l
13
$ grep -rn '${storage_class}' .bundle/ | wc -l
0
```

(13, not 8, because `render-bundle.py` renders each HelmRelease at least twice by design — once
inline as part of its top-level Kustomize overlay build, once again as its own dedicated
`helm template` pass with `spec.values` — and separately again per overlay directory where a
component has both a `base` and a cluster-specific overlay, e.g. `victoria-traces`. An earlier draft
of this document pasted `10` here. Re-run now against the same committed tree, twice, both runs give
13 — the exact multiplication is a `render-bundle.py` architecture detail not worth re-deriving here,
and Task 4's own changes (comment-only, in `apps/base/openwebui/{app,pvc}.yaml`) did not touch any of
the 8 `storageClassName` lines, so they cannot explain the difference. The `10` in the earlier draft
was simply wrong — pasted from a `.bundle/` state that does not reproduce; treat this run as the
authoritative one.)

**Two different sub-claims here, with two different verdicts.** *The substitution mechanism* —
each of the 8 sites renders a real value pulled from `FIXTURE_VARS`, with zero unsubstituted
literals — is confirmed working, reproduced twice: **PASS**, and this part is unaffected by which
GCP name is correct. *The criterion as the design doc states it* — "renders `gp3` in `aws-0`'s
bundle and `standard-rwo` in `gcp-0`'s", i.e. does the GCP value work — is **NOT CHECKABLE BY THE
AVAILABLE METHOD**: nothing above establishes that GKE provides a class named `standard-rwo`, only
that the ConfigMap now says `standard-rwo` instead of `gp3` where it used to (equivalently) say
`balanced-rwo` instead of `gp3`. Both clusters being destroyed means this half of the criterion has
no available check in this repository; it is not marked PASS.

### 2. `./scripts/validate-manifests.sh` passes with `Invalid: 0, Skipped: 0`

```
$ ./scripts/validate-manifests.sh
...
Summary: 1785 resources found in 238 files - Valid: 1785, Invalid: 0, Skipped: 0
==> All gates passed
$ echo $?
0
```

**PASS.**

### 3. `check-substitution.py` passes — every `${storage_class}` sits under a Kustomization declaring `postBuild`

```
$ python3 scripts/flux-schema/check-substitution.py
==> 46 Flux Kustomization(s) checked; substitution wiring is consistent
$ echo $?
0
```

**PASS.**

### 4. Removing `storage_class` from `FIXTURE_VARS` makes a gate fail

**This criterion, as literally stated, did NOT pass — and that is the load-bearing finding of this
workstream, reported plainly rather than softened.**

Task 3 Step 4 removed the `"storage_class": "gp3"` entry from `FIXTURE_VARS` and re-ran the gate:

```
$ ./scripts/validate-manifests.sh >/dev/null 2>&1; echo "exit=$?"
exit=0
$ grep -Ei 'Invalid:|Skipped:' /tmp/mutation-validate.log
Summary: 1785 resources found in 238 files - Valid: 1785, Invalid: 0, Skipped: 0
$ grep -rn '${storage_class}' .bundle/ | head -3
.bundle/chart-observability-aws-0-runlore-runlore.yaml:513:      storageClassName: ${storage_class}
.bundle/chart-observability-base-runlore-runlore-runlore.yaml:513:      storageClassName: ${storage_class}
.bundle/overlay-tooling-base-gha-runners.yaml:124:        storageClassName: ${storage_class}
```

`validate-manifests.sh` **passed** — `Invalid: 0`, `Skipped: 0`, exit 0 — with unsubstituted
`${storage_class}` literals sitting in the rendered bundle at multiple sites. Neither of the gate's
two stages catches this: `flux schema validate` (gate 1) accepts it because `storageClassName` is a
free-form string in every schema that defines it — a literal `${storage_class}` is syntactically a
valid string, indistinguishable from a real class name. `polaris audit` (gate 2) has no opinion on
storage class values at all.

**Conclusion: the schema gate cannot catch this class of defect. The `FIXTURE_VARS` entry is the
only thing standing between a broken substitution and a green CI run for this variable** — exactly
the blind spot the design predicted (and the same shape as the `region`/`project_id` blind spots
already on record in `render-bundle.py`'s comments). This is not a regression introduced by this
workstream; it is a pre-existing property of the schema-based validation approach (SPEC-007), newly
demonstrated for this specific variable. The fixture entry (committed in `cca9c3a9`) is the
mitigation, not the gate.

The change was restored via `git checkout scripts/flux-schema/render-bundle.py` — after the fixture
entry was already committed, so the checkout returned the file to the committed state rather than
discarding uncommitted work (a reordering directed by the team lead, correcting the brief's original
step order). Confirmed clean afterward: `storage_class` entry present, gate green again (§2 above
is the fresh, post-restore run).

**Criterion not met in the literal sense written ("makes a gate fail"); the actual protection is the
fixture's mere presence, verified working by criteria 1–3, not by the gate's ability to fail without
it.**

### 5. The GCP design doc records that Filestore was dropped and why

`docs/superpowers/specs/2026-08-26-gcp-storage-class-design.md` §"Filestore, removed from scope"
(lines 100–133) records the decision and four supporting reasons (cost — 1 TiB billing floor vs.
Cloud Storage Standard; access pattern — write-once/read-many, no shared writes; parity — AWS side
is already object-storage-backed via `s3files:`; identity reuse — GCS Fuse rides workstream 8's
Workload Identity). This was committed in `77868d84`, ahead of this implementation.

Confirmed no other doc still names Filestore as planned/in-scope:

```
$ grep -rln -i 'filestore' website/ docs/ 2>/dev/null | grep -v superpowers
(no output)
```

The roadmap table's Filestore mention was already removed in the same design commit — there is
nothing left to re-add it from.

**PASS.**

### 6. No change to what `aws-0` renders: the bundle diff for AWS is the substitution only

```
$ git diff origin/main --stat -- observability/ infrastructure/ apps/ tooling/
 apps/base/openwebui/app.yaml                                       | 3 ++-
 apps/base/openwebui/pvc.yaml                                       | 7 ++++---
 infrastructure/base/vllm-semantic-router/helmrelease.yaml          | 2 +-
 observability/base/grafana-oncall/helmrelease-rabbitmq.yaml        | 2 +-
 observability/base/runlore/helmrelease.yaml                        | 2 +-
 .../base/victoria-metrics-k8s-stack/helmrelease-vmcluster.yaml     | 4 ++--
 observability/base/victoria-traces/helmrelease-vtsingle.yaml       | 2 +-
 tooling/base/gha-runners/default-scale-set-helmrelease.yaml        | 2 +-
 8 files changed, 13 insertions(+), 11 deletions(-)
```

(`origin/main` is the branch's merge base, `04ec429e`; `77868d84`/`014d807b` are design/plan docs
only, not in these trees. An earlier draft of this document showed 7 files / 8+8 lines, omitting
`apps/base/openwebui/app.yaml` — that was pasted from before this document's own commit, `48ae2194`,
landed its two comment rewrites in `app.yaml` and `pvc.yaml`. Re-run now against the committed tree,
the real count is 8 files / 13 insertions / 11 deletions.)

The diff is now two different kinds of change, and they need to be told apart:

```
$ git diff origin/main -- observability/ infrastructure/ apps/ tooling/ | grep '^[+-]' | grep -v '^+++\|^---'
-  storageClassName: gp3
+  storageClassName: ${storage_class}
[... 7 more identical-shape value pairs, one per call site ...]
-  # The openwebui-data PVC below is RWO (default gp3 StorageClass).
+  # The openwebui-data PVC below is RWO (the platform's default block
+  # storage class -- gp3 on aws-0, standard-rwo on gcp-0; either way, RWO).
-# downloads on startup. gp3 because the workload is small-IOPS read +
-# occasional write — RWO is fine since we only run a single replica.
+# downloads on startup. The platform's default SSD-backed class (gp3 on
+# aws-0, standard-rwo on gcp-0) suits this small-IOPS read + occasional
+# write pattern -- RWO is fine since we only run a single replica.
```

The 8 `storageClassName`/`storageClass` lines are still pure value-token swaps — that part of the
claim is unchanged from the earlier draft. What's new is two comment-only rewrites (Task 4, fixing
the stale-`gp3` comments flagged in review), which are not part of the design's criterion 6 claim at
all but do land inside the same source trees the `--stat` command scopes to.

Comments have no effect on what Flux applies, and this is checked, not assumed — Kustomize's build
step re-serializes every resource through its object model, which drops comments. Confirmed directly
against the rendered bundle for the file that changed:

```
$ grep -n '#' .bundle/overlay-apps-base-openwebui.yaml
(no output)
$ grep -n 'storageClassName' .bundle/overlay-apps-base-openwebui.yaml
16:  storageClassName: gp3
```

Zero comment lines in the rendered output; the value line renders `gp3`, unchanged. Since Task 1's
AWS ConfigMap sets `storage_class = "gp3"` (the exact prior hardcoded literal) and Task 3's CI
fixture also uses `"gp3"`, both the CI-rendered bundle and a live `aws-0` Flux substitution reproduce
byte-identical `storageClassName: gp3` output at all 8 sites. `aws-0`'s actual rendered manifests are
provably unaffected by this document's own commit.

**PASS.**

## Documentation sweep (beyond the design's own criteria)

Task 4 Step 3's brief scoped the doc grep to `website/content/docs/` and `docs/architecture/`; the
team lead widened it to include manifest comments too, after review caught two stale ones there.
Full sweep and disposition:

| Hit | Disposition |
|---|---|
| `apps/base/openwebui/app.yaml:20` | **Fixed.** Was `"RWO (default gp3 StorageClass)"` — now names both classes; RWO (the load-bearing property behind the `Recreate` strategy) is unchanged and portable. |
| `apps/base/openwebui/pvc.yaml:11` | **Fixed.** Was `"gp3 because the workload is small-IOPS..."` — now names both classes; the IOPS/access-pattern reasoning is preserved verbatim in substance. |
| `website/content/docs/platform/observability/sre-agent.md:88` | **Fixed.** Storage table row named `gp3` as a fact of the runlore deployment; now names the platform default per cluster. (Runlore is not currently deployed to `gcp-0` — `clusters/gcp-0/` has no `observability/` Kustomization yet — but the underlying manifest is portable now, and the doc should describe the manifest's actual behavior, not just today's deployment footprint.) |
| `website/content/docs/platform/observability/metrics.md:21` | **Fixed.** Same treatment for the `vmcluster` storage row (vmcluster is currently commented out of `kustomization.yaml` — `vmsingle` is what's active — but the manifest itself is what Task 2 changed, so the doc should match it). |
| `website/content/docs/platform/developer-platform/app-field-reference.md:130` | **Reviewed, no change.** `storageClass` is already documented generically as `cluster default` with no hardcoded value — already portable. |
| `website/content/docs/platform/developer-platform/app.md:180` | **Reviewed, no change.** `# storageClass: gp3   # optional; defaults to the cluster default` is an illustrative override example, not an assertion that `gp3` is what you get — the adjoining text already states the portable default behavior. |
| `website/content/docs/platform/foundations/aws.md:102,106` | **Reviewed, no change.** Describes the OpenBao EC2 instance's own root EBS volume (`opentofu/aws/openbao/cluster/`) — an AWS-only stack with no GCP equivalent, unrelated to the `storage_class` PVC variable. |
| `docs/architecture/bootstrap-stages.drawio:84` | **Reviewed, no change.** Diagram is titled "five OpenTofu stacks" under `opentofu/aws/...` specifically — the node describes the AWS `eks/configure` stage's own `gp3_storageclass` `kubectl_manifest` resource, which is genuinely AWS-only and not consumed by the portable `${storage_class}` variable. |
| `docs/architecture/platform-overview.drawio:93` | **Reviewed, no change.** False-positive substring match inside a base64-encoded PNG blob; no textual content. |
| `infrastructure/base/vllm-semantic-router/helmrelease.yaml:384`, `observability/base/victoria-metrics-k8s-stack/helmrelease-vmcluster.yaml:53`, `security/base/openbao-snapshot/snapshot-cronjob.yaml:36` | **Reviewed in Task 2, no change.** Historical/rationale comments (Karpenter disruption cost, a past misplacement bug, a past PVC-pinning problem) that don't assert a current class value and read correctly as-is. |

## Gate results (fresh, this session)

| Gate | Command | Result |
|---|---|---|
| Manifest validation | `./scripts/validate-manifests.sh` | exit 0 — `Invalid: 0, Skipped: 0`, `All gates passed` |
| Substitution wiring | `python3 scripts/flux-schema/check-substitution.py` | exit 0 — `46 Flux Kustomization(s) checked; substitution wiring is consistent` |
| Doc links | `./scripts/validate-links.sh` | exit 0 — `All relative Markdown links resolve (0 allowlisted)` |
| Doc claims | `./scripts/validate-doc-claims.sh` | exit 0 — `All 6 documentation claims match the repository (10 page checks)` |
| Doc paths | `./scripts/verify-doc-paths.sh` | exit 0 — `Every repository path named in the docs site exists` |

All five gates green, run fresh in this session after the documentation fixes above.

## Summary

| # | Criterion | Result |
|---|---|---|
| 1 | Per-cluster values render correctly | **NOT CHECKABLE BY THE AVAILABLE METHOD** — substitution mechanism confirmed PASS; whether `standard-rwo` names a real GKE class is outside what any command here can check while both clusters are destroyed (see §1) |
| 2 | `validate-manifests.sh`: `Invalid: 0, Skipped: 0` | PASS |
| 3 | `check-substitution.py` passes | PASS |
| 4 | Mutation test makes a gate fail | **DID NOT hold as literally stated — schema gate passes on the unsubstituted literal; the fixture is the only protection (see §4)** |
| 5 | Filestore drop recorded, roadmap clean | PASS |
| 6 | `aws-0` bundle diff is substitution only | PASS |

4 of 6 criteria pass outright; criteria 1 and 4 are both honest findings about the limits of this
repository's own gates, not defects this implementation introduced. Criterion 4's mutation test
exists specifically to check whether the schema gate's coverage is real; criterion 1's method — a
rendered bundle and a grep of the ConfigMap literal — was never capable of checking whether a GCP
class name is real, which is exactly how `balanced-rwo` reached this branch marked PASS in an
earlier draft. No cluster was deployed — deliberate, per the scope note above.
