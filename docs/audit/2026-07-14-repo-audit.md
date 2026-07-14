# Repository Audit & Improvement Plan — 2026-07-14

**Method**: six parallel audit agents (leftovers, consistency, security, docs/DX, structure,
gap analysis), every high/medium finding adversarially re-verified by an independent agent
before inclusion. Repo-static only (no cluster/AWS state was consulted). Numbers below (line
refs, counts) were re-derived during verification, not taken from the first pass.

**Out of scope**: two in-flight efforts are explicitly excluded from findings — the
`app-wizard` feature (`feat/spec-008-app-wizard`) and the Flux schema validation rework
(`feat/flux-schema-validation`, SPEC-007, which replaces the current kubeconform-based
validation). The report describes the durable state of `main`, not work still on branches.

**Verdict in one line**: the platform's *architecture and governance are genuinely strong* —
the debt is concentrated in (1) network-policy coverage that lags the constitution, (2) an
empty Kyverno policy layer, (3) no cluster-level backup, (4) supply-chain gaps on internally
built images, and (5) a handful of doc/branch leftovers. Nothing structural needs to move.

---

## ✅ What's solid (keep doing this)

- **GitOps discipline**: all 24 Flux Kustomizations trace cleanly to overlays, dependsOn
  hierarchy enforced, `driftDetection: enabled` on all 22 base HelmReleases, consistent
  `postBuild.substituteFrom` with a single vars ConfigMap.
- **Kustomize overlay model**: `{base,mycluster-0}` is applied rigorously; base layers use
  only relative paths and are genuinely reusable for a second cluster.
- **KCL compositions**: all 4 modules (app, inference-service, eks-pod-identity,
  cloudnativepg) carry `main.k` + `main_test.k` + `README.md` — 100 % constitution §8.1
  compliance; production XRs all use the `xplane-` prefix; unit tests + `crossplane render`
  run in CI.
- **Secrets**: ExternalSecrets everywhere (30+), zero hardcoded credentials found in tracked
  files.
- **IAM**: `xplane-*` scoping consistently enforced; the `s3:*` grants are bucket-scoped with
  explicit Deny on destructive ops for stateful buckets.
- **Tracing** (a finder claimed it was missing — refuted): VictoriaTraces is deployed with
  OTLP ingestion, Grafana Jaeger datasource, Flux event tracing, and auto-injected OTEL env
  vars via the App composition. Collector-less by documented design (SPEC-006, CL-1).
- **Alerting is better than it looks**: ~19 alerts in vmrules + Cilium/Flux/AIGateway rules
  elsewhere; runbook URLs on Karpenter 3/3, Runlore 12/12, Flux 3/3, Cilium 4/4; LLM SLO
  recording rules + breach alerts exist (`apps/base/ai/llm/vmrule-llm-slo.yaml`).
- **Intentional gating is clean and documented**: LLM platform double gate (Terramate env var
  + suspended umbrella), Cilium prefix-delegation disable, commented dagger-engine/gha-runners.
- **OpenBao backups**: daily snapshot CronJob → S3 with KMS + retention, restore doc drafted.
- **SDD governance**: constitution, ADRs, 3-artifact specs with auto-archive — mature and
  actually followed.

---

## 🧹 Leftovers (each verified before the verdict)

| # | Item | Verified verdict | Action |
|---|------|------------------|--------|
| L1 | `demo_podinfo` local branch | Fully merged (`git log main..demo_podinfo` = 0). | `git branch -d demo_podinfo`. |
| L2 | `docs/plans/self-hosted-llm-platform/` (~130 KB) | **Not orphaned** — labeled "frozen historical draft", actively cited by ADR-0004 via relative links; source material for SPEC-001…006. | Keep. Don't move (would break ADR links). |
| L3 | `docs/plans/crossplane-validation-improvements.md` | Floating plan ("Phase 2 complete, 1/3-5 planned"), zero backlinks, no owner. | Decide: fold remaining phases into an issue/spec, or archive it. |
| L4 | `docs/superpowers/specs/` (7 dated design docs) vs `docs/specs/` | Two spec systems coexist; superpowers docs are session artifacts, SDD specs are the governed pipeline. | Add a README line in `docs/superpowers/` stating these are exploratory design sessions, authoritative specs live in `docs/specs/`. |
| L5 | 4 scripts unreferenced by CI/docs: `cleanup-benchmark-images.sh`, `image-gallery-benchmark.sh`, `validate-vector-vrl.sh`, (`openbao-snapshot.sh` is CronJob-owned — fine) | `validate-vector-vrl.sh` likely superseded by `test-vector-vrl.sh` (which CI runs). | Triage: delete the two benchmark scripts if the benchmark is done; consolidate the two vector-vrl scripts; comment `openbao-snapshot.sh` as CronJob-owned. |
| L6 | Stale local branches: `feat_app_module`, `feat_app_module_backup`, `feat_tailscale_operator`, `chore_upgrade_cilium_karpenter`, `chore_dec_2025_upgrade` | Unmerged but old naming convention (snake_case) suggests pre-SDD era. | Review each once; delete or convert to issues. |

---

## 🔧 Improvements (verified findings, grouped)

### Security

- **S1 — CiliumNetworkPolicy coverage: 29 of 38 HelmReleases have no network policy (76 % gap). HIGH.**
  The constitution mandates default-deny + explicit allow per pod-running workload. Coverage
  today: envoy-ai-gateway, envoy-gateway, keda, vllm-semantic-router, zitadel, gha-runners
  (9 HRs), plus non-HR promptfoo/dagger-engine. Entire observability stack (13 HRs), most of
  security/ (cert-manager, external-secrets, kyverno, tailscale-operator) and infrastructure/
  (karpenter, crossplane, external-dns, CSI drivers, cloudnative-pg…) run policy-free.
  → This is the single biggest gap between what the repo *says* and what it *ships*.
- **S2 — Kyverno is an empty shell. HIGH.** `kyverno-policies` chart v3.8.2 with `values: {}`;
  zero custom ClusterPolicies (the last one was removed in 2023, commit `3377ba03`); no
  PolicyExceptions; no policy-violation metrics/alerts; audit-vs-enforce mode undocumented.
  The README claims "security-first" — the policy engine enforces nothing custom.
- **S3 — 4 unpinned GitHub Actions (supply-chain risk). MEDIUM, confirmed.**
  `ci.yaml` lines 46/62/78/104: `trivy-action@master`, `checkov-action@master`,
  `trufflehog@main`, `polaris setup@master`. Everything else is pinned. Pin these to SHAs.
- **S4 — Human cluster-admin bindings undocumented. MEDIUM.** `security/base/rbac/admin.yaml`
  (Zitadel `admin` group) and `flux/operator/rbac.yaml` both bind `cluster-admin`.
  Constitution §3.4 only covers *workloads*, so this is legal — but no ADR/comment justifies
  the human access model. Document it (or scope it down).
- **S5 — `s3:*` wildcard rationale (LOW).** `opentofu/eks/init/iam.tf:172-207` and the CNPG
  composition use `s3:*` scoped to named buckets with Deny on destructive ops — acceptable,
  but add the inline justification so future audits (and Trivy) don't re-flag it.

### Consistency

- **C1 — Resource limits missing on 2 HelmReleases (not 4 — verifier corrected).**
  `observability/base/runlore/helmrelease.yaml` and
  `observability/base/kubernetes-event-exporter/helmrelease.yaml` have no `resources`.
  (grafana-oncall valkey/rabbitmq use Bitnami `resourcesPreset: nano` — compliant.)
- **C2 — chartRef vs sourceRef split** (7 vs ~15 HelmReleases) with no documented standard.
  Pick one (chartRef is the newer idiom), document in a rule file, migrate opportunistically.
- **C3 — interval/timeout scatter**: intervals range 30s→12h with no documented rationale;
  `timeout` set on only 4 HRs. Write the policy down (fast-poll for operators, 12h for static
  repos), then align outliers.
- **C4 — prune strategy undocumented**: 23/24 Kustomizations `prune: true`, CRDs `false` —
  correct but fragile; one sentence in an ADR or rule file makes it deliberate.
- **C5 — postBuild substitution has no guard**: a missing var renders literal `${VAR}` silently.
  Cheap win: a lint step that greps rendered/output manifests for unresolved `${` before apply.

### Docs & DX

- **D1 — No DR / cluster-rebuild runbook**: pieces exist (OpenBao restore doc, CNPG PITR,
  OpenTofu state) but no end-to-end "rebuild from zero" procedure. Tied to SPEC-D below.
- **D2 — No per-component READMEs** under `infrastructure/base/*` (only crossplane has one).
  50-line READMEs for cilium, karpenter, envoy-gateway, keda would pay for themselves.
- **D3 — `flux/` vs `clusters/` data flow** is sound but non-obvious; one paragraph in
  `clusters/mycluster-0/README.md` explaining "flux/ = shared components, wired per-cluster
  via clusters/<name>/flux/*.yaml" closes it.

### Structure

- **No structural moves recommended.** The directory split is principled; verified.
- **ST1 — Multi-cluster friction is real but bounded**: of 174 `mycluster-0` references, the
  actual blockers are 28 `eks-mycluster-0-vars` ConfigMap references and 11 Flux `path:`
  directives; base layers need zero changes. Documentation (76 refs) is inert. Decide the
  stance (see P8) rather than refactoring speculatively.
- **ST2 — Pass-through overlay dirs** (7 single-file kustomizations that only point at base)
  and the single-file `…/configuration/kcl/` dir: harmless; flatten opportunistically or
  document why the extra Flux Kustomization boundary exists (ordering/suspend).

---

## 🕳️ Missing (gap analysis, calibrated for a reference platform)

| # | Gap | Status after verification |
|---|-----|---------------------------|
| M1 | **Cluster backup/restore (Velero)** | Confirmed absent. `velero.tf` stubs exist in the EKS modules but `attach_velero_policy` is never set; no HelmRelease, no bucket, no RTO/RPO doc. OpenBao + CNPG backups exist — the *cluster state* layer doesn't. |
| M2 | **Runtime security (Falco/Tetragon)** | Confirmed absent — and notably Tetragon would showcase well next to Cilium. |
| M3 | **Supply chain for internal images** | `provenance: false` hardcoded in `build-container-images.yml:170`; no cosign signing, no SBOM for pev2 (the only internally-built image on main). Ironically the repo *verifies* cosign on upstream sources (karpenter, flux-operator) but doesn't sign its own. SBOM already listed as TODO in docs. |
| M4 | **Cost visibility** | No OpenCost/Kubecost; tags have `environment` + `owner` + `project` (finder undercounted) but no cost dashboard, budget alert, or cost doc. Only LLM token costs (Runlore) are tracked. |
| M5 | **E2E platform test** | Unit tests + `crossplane render` exist in CI (good); no kind/vcluster job that deploys a composition and verifies behavior. Explicit TODO in docs/ci-workflows.md. |
| M6 | **Runbooks dir** | Most alerts link upstream runbooks; 4 LLM/Promptfoo alerts lack `runbook_url`; no `docs/runbooks/` for platform-specific procedures. |
| M7 | **Renovate blind spots** | `ignorePaths: [clusters, opentofu]` → versions in `config.tm.hcl` (cilium 1.19.5, flux-operator 0.53.0…) and mise.toml rot manually. |
| M8 | **Published docs site** | 202 .md files, no mkdocs/Pages. For a public reference repo, discoverability = impact. |
| M9 | **Image automation (Flux)** | Controllers commented out — but Renovate covers chart bumps; enabling image-reflector is *optional*, not debt. Documented decision would suffice. |
| M10 | **Multi-env story** | Single cluster is intentional and README-consistent; OpenTofu already validates `env ∈ {dev,staging,prod}`. Needs a *stated position*, not an implementation. |

---

## 📋 Improvement plan (prioritized)

### Now — quick wins (< 1 h total, no spec needed)

1. **Delete the merged `demo_podinfo` branch** — `git branch -d demo_podinfo`. (L1)
2. **Pin the 4 GitHub Actions to SHAs** — `ci.yaml:46,62,78,104`. (S3)
3. **Add resources to runlore + kubernetes-event-exporter HelmReleases.** (C1)

### Next — small PRs (an evening each)

4. **Write the conventions down**: chartRef standard, interval/timeout policy, prune strategy,
   `s3:*` justification comments, human-RBAC ADR. One "platform conventions" PR. (C2–C4, S4, S5)
5. **`${VAR}` leak check** in the validation pipeline. (C5)
6. **Stance docs**: single-cluster position + multi-cluster path (ST1/M10), image-automation
   decision (M9), superpowers-vs-specs README note (L4), flux/ data-flow paragraph (D3).
7. **Script triage** (L5) + stale branch review (L6).
8. **Runbook gap**: add `runbook_url` to the 4 LLM/Promptfoo alerts; seed `docs/runbooks/`. (M6)

### Specs — these meet the repo's own "spec required" bar

Ordered by (showcase value × risk closed) / effort:

- **SPEC-A: CiliumNetworkPolicy rollout** (S1) — phased: observability stack → security stack
  → infrastructure operators. The `.claude/rules/cilium-network-policies.md` traps doc means
  the hard lessons are already written down. Biggest constitution-vs-reality gap; probably a
  PHASED spec.
- **SPEC-B: Kyverno policy suite** (S2, M2-lite) — custom ClusterPolicies
  (require-requests, disallow-privileged, restrict-registries, verifyImages once SPEC-C
  lands), documented audit→enforce promotion, PolicyExceptions, violation metrics + alert.
- **SPEC-C: Supply chain for internal images** (M3) — flip `provenance: true`, cosign keyless
  signing in the build workflow, syft SBOM, then Kyverno/Flux verification closes the loop
  with SPEC-B. High showcase value for a reference platform, small blast radius.
- **SPEC-D: Cluster backup & DR** (M1, D1) — wire the existing velero.tf stubs, Velero
  HelmRelease + S3 bucket via Crossplane, then the end-to-end rebuild runbook that ties
  OpenTofu state + Flux sync + OpenBao restore + CNPG PITR together.
- **SPEC-E (optional): Tetragon** (M2) — runtime observability/enforcement; natural Cilium
  companion, strong demo value.
- **SPEC-F (optional): OpenCost + tagging** (M4) — add `cost_center`/workload tags in
  OpenTofu locals, OpenCost HelmRelease, one Grafana dashboard, one budget alert.
- **SPEC-G (optional): kind-based e2e job** (M5) — deploy App + SQLInstance compositions to a
  kind cluster in CI, assert behavior. Closes the last testing gap.
- **SPEC-H (optional): mkdocs site** (M8) — cheap, and multiplies the value of the 202 docs
  files this repo already has.

### Explicitly *not* recommended

- Moving/renaming top-level directories (layout is sound; Flux path churn isn't worth it).
- Archiving `docs/plans/self-hosted-llm-platform/` (ADR-0004 links into it).
- Enabling Flux image automation (Renovate already covers the need; document instead).
- A tracing backend (already have VictoriaTraces — the audit initially got this wrong and the
  verification pass caught it; treat third-party "add Tempo" advice with suspicion).
