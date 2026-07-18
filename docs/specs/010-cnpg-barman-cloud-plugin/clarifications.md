# Clarifications Log — Migrate SQLInstance backups to the Barman Cloud CNPG-I plugin

**Spec**: [SPEC-010](spec.md)

> **Append-only.** Never rewrite earlier entries. Every entry has a stable ID (`CL-1`, `CL-2`, ...) so `spec.md` and `plan.md` can reference the decision by ID. This is the durable "why did we pick option A?" audit trail.

---

## CL-1 — 2026-07-18 — Migrate to the plugin, or stay on in-tree Barman Cloud?

**Asked by**: Spec author
**Context**: In-tree `barmanObjectStore` is deprecated (CNPG 1.26) and removed in operator **1.31.0**. The cluster runs operator 1.30.0 today, so backups still work — the question is whether to migrate proactively or defer until forced.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Migrate to the Barman Cloud CNPG-I plugin now | Unblocks the 1.31.0 bump; migration is documented as seamless/zero-data-loss; done on our schedule | New plugin install (greenfield); two render sites to change |
| B | Stay on in-tree until forced | No work now | Blocks any operator bump past 1.30.x; forced migration under time pressure later |

**Decision**: A — migrate to the plugin now.
**Rationale**: In-tree removal in 1.31.0 is a hard upstream deadline; the CNPG project documents the plugin migration as seamless. Doing it proactively (while the cluster is not live, per this session's context) removes the operator-upgrade blocker with zero migration risk. Matches the constitution's "prefer the sanctioned upstream mechanism".
**Decided by**: Recency-assessment session, 2026-07-18 (user-approved as a Tier-1 adoption).
**References**: <https://cloudnative-pg.io/plugin-barman-cloud/docs/migration/>; SPEC-010 spec.md Problem.

---

## CL-2 — 2026-07-18 — Plugin delivery mechanism: HelmRelease vs raw manifests?

**Asked by**: Spec author (/clarify)
**Context**: The barman-cloud plugin (controller Deployment + `ObjectStore` CRD) must be installed cluster-wide — greenfield, nothing exists today. Flux can deliver it as a `HelmRelease` from the official chart or as vendored raw manifests; the choice sets version management and how much of the securityContext/CNP the repo owns.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | `HelmRelease` from the official `plugin-barman-cloud` chart | Matches constitution "prefer HelmRelease when an upstream chart exists" + the CNPG-operator install pattern; Flux-native version pin + clean upgrades; Renovate-trackable | Must confirm the chart exposes PSS-restricted `securityContext` + resource knobs |
| B | Raw manifests vendored under `infrastructure/base/` + CRDs under `crds/base/` | Full control over securityContext / CNP / resources | Manual version bumps; drifts from upstream release manifest; against the prefer-HelmRelease default |

**Decision**: A — `HelmRelease` from the official `plugin-barman-cloud` chart.
**Rationale**: The plugin ships an official chart, so the constitution's GitOps rule ("prefer `HelmRelease` over raw manifests when an upstream chart exists") applies; mirrors `infrastructure/base/cloudnative-pg/helmrelease.yaml`. Version pin + upgrades stay Flux-native and Renovate-trackable.
**Decided by**: user via /clarify, 2026-07-18
**References**: constitution GitOps section; `infrastructure/base/cloudnative-pg/helmrelease.yaml`; [[CL-1]]

## CL-3 — 2026-07-18 — Exact `ScheduledBackup` + `Cluster.spec.plugins` + recovery API shape?

**Asked by**: Spec author (/clarify)
**Context**: The composition renders `ScheduledBackup`, `Cluster.spec.plugins`, and the recovery `externalClusters`. The plugin API shape had to be confirmed against the real docs/CRD rather than guessed (this marker was a verification, not a design choice).

**Resolution (verified from upstream docs — `plugin-barman-cloud`)**:
- `ScheduledBackup`: `spec.method: plugin` + `spec.pluginConfiguration.name: barman-cloud.cloudnative-pg.io`.
- `Cluster`: `spec.plugins: [{name: barman-cloud.cloudnative-pg.io, isWALArchiver: true, parameters: {barmanObjectName: <ObjectStore name>}}]`.
- Recovery: `Cluster.spec.externalClusters[].plugin: {name: barman-cloud.cloudnative-pg.io, parameters: {barmanObjectName: <recovery ObjectStore>, serverName: <source cluster>}}` — note singular `plugin:` (not `plugins:`) — with `spec.bootstrap.recovery.source: <externalCluster name>`.

**Decision**: Adopt the plugin's documented API verbatim — it is the plugin's only interface, no alternative. Confirms the plan.md FR-003/FR-004 sketch and removes the T001 "verify exact shape" guess.
**Rationale**: Verified factual answer against canonical upstream docs.
**Decided by**: verification via upstream docs (/clarify), 2026-07-18
**References**: <https://github.com/cloudnative-pg/plugin-barman-cloud> (`migration.md`, `usage.md`); [[CL-1]]

## CL-4 — 2026-07-18 — Credential model: credential-less IAM (Pod Identity), access-key Secret, or both?

**Asked by**: Spec author (/clarify)
**Context**: The plugin's `ObjectStore` supports credential-less IAM on EKS (recommended) or access keys in a Secret. The repo defaults to EKS Pod Identity (existing `PodIdentityAssociation` for SA `<name>-cnpg-cluster`, `main.k:744-761`). FR-006 originally required "no new Secret".

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | Credential-less IAM via Pod Identity (omit `s3Credentials`; ambient creds) | Constitution-aligned; no static creds; reuses IAM bundle | Only works where ambient IAM is available (EKS + Pod Identity) |
| B | Access-key Secret via ESO (S3 keys in OpenBao → `ExternalSecret` → `ObjectStore.s3Credentials`) | Works for any S3-compatible / cross-account store | Static credential; extra ESO wiring; adds an XRD field |

**Decision**: **Both — A as the default, B as an opt-in alternative.**
- **Default** (no opt-in): credential-less IAM via Pod Identity — the `ObjectStore` omits explicit `s3Credentials`; the plugin sidecar (in the CNPG instance pods, SA `<name>-cnpg-cluster`) inherits ambient credentials from the existing `PodIdentityAssociation`. No new Secret.
- **Opt-in**: a claim may select access-key mode, wiring an ESO-backed Secret (keys sourced from OpenBao) into `ObjectStore.s3Credentials`.

**Rationale**: A keeps the default posture constitutional (EKS Pod Identity, never IRSA, no static creds) and satisfies FR-006 for the common path; B adds flexibility for non-Pod-Identity / non-AWS / cross-account object stores without compromising the default. Reconciliations: **FR-006** "no new Secret" now scopes to the default path; the opt-in access-key path uses an ESO-managed Secret (never hardcoded). **Non-Goal #2** (XRD API unchanged) gains a carve-out for one optional, default-off access-key field. Residual for the default path: T001 must confirm the `ObjectStore` accepts an omitted `s3Credentials` block (the plugin docs show IRSA-annotation + access-keys explicitly; the repo must NOT use the IRSA `eks.amazonaws.com/role-arn` annotation — Pod Identity supplies ambient creds via the AWS SDK default chain).
**Decided by**: user via /clarify, 2026-07-18
**References**: plugin `ObjectStore` auth docs (IRSA/ambient + access-keys); constitution (Pod Identity; no hardcoded creds → ESO); FR-006; Non-Goal #2; `main.k:744-761`; [[CL-3]]

## CL-5 — 2026-07-18 — Plugin securityContext + resource limits + CNP egress shape?

**Asked by**: Spec author (/clarify)
**Context**: The plugin controller Deployment + injected backup sidecar must comply with PSS-restricted securityContext (constitution) and need a `CiliumNetworkPolicy` for S3 egress. securityContext + limits are constitution-mandated; the real choice was the CNP egress model (`toFQDNs` vs `toEntities: world`). Both the workload's long-lived nature (CNP rule #4) and the CL-4 ambient-credential path (needs the Pod Identity Agent, CNP rule #3) constrain it.

**Options considered**:

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A | `toFQDNs` for S3 + DNS L7 + `toEntities: ["host"]` TCP 80 (Pod Identity Agent) | Precise default-deny; constitution-aligned for long-lived; makes CL-4 ambient creds work | S3 FQDN set to maintain (`matchPattern` subdomain-depth care) |
| B | `toEntities: world` on TCP 443 | Simpler | Disallowed by CNP rule #4 for long-lived workloads; `world` excludes `host`, so it breaks CL-4's Pod Identity Agent reach (rule #3) regardless |

**Decision**: **A — `toFQDNs`.**
- **securityContext** (PSS-restricted, both controller and — where configurable — the injected sidecar): `runAsNonRoot: true`, `readOnlyRootFilesystem: true`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `seccompProfile.type: RuntimeDefault`. Resource requests + limits set.
- **CiliumNetworkPolicy** (default-deny + explicit allow) egress:
  - kube-dns with L7 `rules.dns matchPattern: "*"` — mandatory or `toFQDNs` silently fails (rule #1);
  - `toFQDNs` for the S3 endpoints (`s3.<region>.amazonaws.com` + regional/bucket variants; watch `matchPattern` subdomain depth — rule #2);
  - `toEntities: ["host"]` on TCP 80 for the Pod Identity Agent (`169.254.170.23`) — required for CL-4 ambient creds (rule #3);
  - egress to the CNPG cluster/instances as needed.

**Rationale**: Compliant with CNP rule #4 (no `world:443` on a long-lived workload) and rule #3 (host entity for the Pod Identity Agent); satisfies the constitution's zero-trust default-deny + PSS-restricted mandates. B was rejected: it violates rule #4 and, because `world` excludes the `host` entity, would break CL-4's credential path regardless.
**Decided by**: user via /clarify, 2026-07-18
**References**: `.claude/rules/cilium-network-policies.md` (rules #1–#4); constitution security defaults; [[CL-4]] (Pod Identity Agent dependency)

---

## CL-6 — 2026-07-18 — CORRECTION: no Helm chart exists → GitRepository + Flux Kustomization (supersedes CL-2)

**Asked by**: Implementation (verification before build)
**Context**: CL-2 chose `HelmRelease` delivery on the premise that the plugin ships an official chart. **Verification during implementation found this premise false**: the Barman Cloud plugin supports only manifest/Kustomize installation — a Helm chart is an open upstream feature request (issue #351). The `plugin-barman-cloud-v0.7.0` "chart" referenced in CL-2 is a *manifest release*, not a Helm chart.

**Options considered** (both raw-manifest — no chart exists):

| Option | Answer | Pros | Cons |
|--------|--------|------|------|
| A′ | Flux `Kustomization` from a `GitRepository` at the plugin release tag, with kustomize patches (namespace, securityContext, CNP) | Mirrors the repo's existing CNPG-CRD + gateway-api-CRD install pattern; versioned by tag; Renovate-trackable; minimal vendored YAML | Patching a multi-resource upstream manifest |
| B′ | Vendor the release `manifest.yaml` into the repo | Fully explicit | Large static blob; manual version bumps |

**Decision**: **A′ — Flux `Kustomization` from a `GitRepository`** at the plugin release tag. **Supersedes CL-2.**
- `ObjectStore` CRD under `crds/base/` (mirrors `crds/base/kustomization-cloudnative-pg.yaml`).
- Plugin workload under `infrastructure/base/cloudnative-pg-barman-plugin/` via a Flux Kustomization from `flux/sources/gitrepo-barman-cloud-plugin.yaml` (tag), with kustomize patches: **namespace = `infrastructure`** (MUST match the CNPG operator, not the docs' default `cnpg-system`), PSS-restricted securityContext, resource limits, + an added `CiliumNetworkPolicy` (CL-5).
- Requires **cert-manager** (already in the repo) for plugin↔operator TLS.

**Side-findings (same verification):**
1. **cert-manager is a hard requirement** for the plugin↔operator mTLS — satisfied (repo already runs cert-manager).
2. **CL-4 credential mechanism refined**: `ObjectStore.spec.configuration` is the *same* `BarmanObjectStoreConfiguration` type as the in-tree field, so the default path sets `s3Credentials.inheritFromIAMRole: true` (a verbatim carry-over of `main.k:277`) — **not** an omitted block. Ambient Pod Identity still supplies creds via the AWS SDK default chain; the CL-5 host:80 CNP rule is still required. This *strengthens* CL-4 (direct carry-over, no "omit-and-verify" residual).

**Rationale**: No chart exists, so CL-2's `HelmRelease` is impossible. A′ matches the repo's established CRD-install pattern (GitRepository + Flux Kustomization), keeps upgrades to a tag bump, and lets the namespace/securityContext/CNP patches layer on cleanly.
**Decided by**: user via /clarify (correction), 2026-07-18
**References**: upstream issue #351 (Helm chart requested); plugin installation docs (manifest/Kustomize; same-namespace-as-operator; cert-manager required); `crds/base/kustomization-cloudnative-pg.yaml`; `flux/sources/gitrepo-cloudnative-pg.yaml`; supersedes [[CL-2]]

---

## Related

- Constitution: [docs/specs/constitution.md](../constitution.md)
- ADRs: [docs/decisions/](../../decisions/) — ADR-0002 (EKS Pod Identity over IRSA) governs the credential model
