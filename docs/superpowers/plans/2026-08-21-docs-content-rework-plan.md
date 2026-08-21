# Documentation Site Content Rework — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backfill nine ADRs for every technology choice with a namable rejected alternative, replace the rotting version table with component roles, rewrite the homepage hero and `SECURITY.md`, and close the link gate that let ten dead links reach production.

**Architecture:** Pure documentation change across three sequential PRs. PR 1 adds nine ADR files and nine index rows — no existing page is touched. PR 2 closes the link gate first (red), fixes the ten links it surfaces (green), then rewrites the Technology Stack page, deletes `technology-choices`, and installs the ADR rule. PR 3 reworks the homepage, `how-this-is-built`, `SECURITY.md`, and adds a supply-chain section.

**Tech Stack:** Hugo 0.156.0 extended + Hextra theme; Markdown with Hugo `relref` shortcodes; Python 3 inside `scripts/validate-links.sh`; bash.

**Design:** [2026-08-21-docs-content-rework-design.md](../specs/2026-08-21-docs-content-rework-design.md)

## Global Constraints

- **Never invent a fact.** Every technical claim in every ADR must be traceable to a file in this repository. Where a claim cannot be traced, cut it. This plan names the source file for every required claim; if the source says something different from the plan, **the source wins and you flag it**.
- **Every ADR must name a cost.** `## Consequences` → `### Negative` may not be empty and may not contain only restated positives. An ADR that lists no trade-off is a changelog entry and fails review.
- **House ADR structure**, matching `0005`/`0007`: `## Context`, `## Decision Drivers`, `## Considered Options` (with `### Option N:` subsections), `## Decision Outcome`, `## Consequences` (with `### Positive`, `### Negative`, `### Neutral`), `## Implementation Notes`, `## References`. Horizontal rules (`---`) between top-level sections.
- **Frontmatter on every ADR:** `title`, `linkTitle`, `weight` (ADR number × 10), `description` (one sentence, states the choice and the reason), `lastVerified: 2026-08-21`.
- **`linkTitle` is what the sidebar shows, and it must carry meaning.** The existing records use `linkTitle: ADR-0001`, which renders a navigation column of bare identifiers — already unhelpful at seven records, unusable at sixteen. Every `linkTitle` is `NNNN · <short noun phrase>`, roughly 20–30 characters, so the sidebar reads as a table of contents while the number stays available for citation. Task 10 retrofits the seven existing records.
- **Header block after frontmatter:** `**Status**: Accepted`, `**Date**: 2026-08-21`, `**Deciders**: Smana (Platform Owner)`. Never `Platform Team` — this is a solo-maintained repository.
- **Internal links use `relref`**, never raw relative paths: `[text]({{< relref "/docs/decisions/0009-cilium-over-vpc-cni.md" >}})`. Files not published on the site (`docs/superpowers/**`, `.claude/rules/**`, `docs/specs/**`) must be linked as absolute `https://github.com/Smana/cloud-native-ref/blob/main/…` URLs.
- **No version numbers in prose** unless the number is the point (e.g. "Cilium ≤1.19.4 crashes on Gateway API ≥v1.5.0"). Versions rot; roles do not.
- **Line width:** wrap prose at ~80 characters, matching the surrounding files.
- **Commit style:** Conventional Commits, `docs(<scope>):`. Never co-author. Never add tool attribution.

## Verification commands

Run all three after every task that touches `website/` or `docs/`:

```bash
./scripts/validate-links.sh          # expect: "==> All relative Markdown links resolve"
./scripts/verify-doc-paths.sh        # expect: "==> Every repository path named in the docs site exists."
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

`hugo` must print no `REF_NOT_FOUND` warning. A `relref` to a page that does not exist fails the build (`refLinksErrorLevel: ERROR` in `website/hugo.yaml:10`).

---

# PR 1 — The records

Nine new files, one index edit. Nothing existing is modified, so this PR is reviewable file-by-file.

Each ADR task follows the same shape. Read `website/content/docs/decisions/template.md` and `0005-gke-standard-self-managed-cilium.md` once before starting Task 1 — `0005` is the house-style reference.

---

### Task 1: ADR-0008 — Flux over Argo CD

**Files:**
- Create: `website/content/docs/decisions/0008-flux-over-argocd.md`

**Interfaces:**
- Produces: the relref target `/docs/decisions/0008-flux-over-argocd.md`, cited by Task 10 (index) and Task 13 (stack page, GitOps section).

**Source material — read before writing:**
- `clusters/mycluster-0/` — every `Kustomization` and its `dependsOn` edges
- `website/content/docs/platform/gitops/_index.md` and `repository-structure.md`
- `website/content/docs/concepts/gitops-model.md`
- Memory note: this repo shards Flux controllers (`sharding.fluxcd.io/key=apps`); sources live under `flux-sources` with no shard label

**Required claims (each must be checkable against the source above):**
- `dependsOn` is the ordering primitive the platform's layered bootstrap needs — Namespaces → CRDs → Crossplane → EKS Pod Identities → Security → Infrastructure → Observability → Applications.
- Flux's controllers are themselves CRDs, so the platform composes against them (the `App` composition emits `HelmRelease`); Argo CD's `Application` is a thinner surface for that.
- Flux Operator + `FluxInstance` is how the platform installs Flux from OpenTofu Stage 2 (`opentofu/eks/configure/main.tf`), which is what makes the bootstrap single-command.

**Required `### Negative` content (the cost):**
- Controller sharding is a real operational trap: a `GitRepository`/`HelmRepository` placed under an app directory inherits `sharding.fluxcd.io/key=apps`, and the default-shard `HelmChart` then cannot find it — "source not found" on a source that reports `Ready`. Sources must live under `flux-sources`.
- Flux has no built-in UI; the platform runs Headlamp partly to compensate.

**Required honesty line:** state plainly that Argo CD would also have worked and that this is a preference, not a verdict. `concepts/technology-choices.md` already says this; preserve it.

- [ ] **Step 1: Read the source material**

```bash
ls clusters/mycluster-0/
grep -rn "dependsOn" clusters/mycluster-0/ | head -30
grep -rln "sharding.fluxcd.io" flux/ clusters/ infrastructure/ tooling/
sed -n '1,80p' website/content/docs/concepts/gitops-model.md
```

- [ ] **Step 2: Write the ADR**

Create the file with this exact frontmatter and header, then write the body per the required-claims list above:

```markdown
---
title: Use Flux for GitOps reconciliation
linkTitle: 0008 · Flux over Argo CD
weight: 80
description: The cluster is reconciled by Flux rather than Argo CD, because dependsOn expresses the platform's layered bootstrap ordering and Flux's controllers are CRDs the platform composes against.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context
```

Options to cover in `## Considered Options`: **Option 1: Flux** (chosen), **Option 2: Argo CD**, **Option 3: Helm + CI push**. Give each real pros and cons — Argo CD's cons must not be strawmen, since the ADR concludes it would also have worked.

- [ ] **Step 3: Verify every claim against source**

For each factual sentence, name the file that proves it. Delete any sentence you cannot attach to a file.

```bash
grep -c "dependsOn" clusters/mycluster-0/*.yaml | grep -v ":0" | head
```

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

Expected: all three pass. The ADR is not yet in the index, which is fine — Hugo renders it regardless.

- [ ] **Step 5: Confirm the cost is present**

```bash
sed -n '/### Negative/,/### Neutral/p' website/content/docs/decisions/0008-flux-over-argocd.md
```

Expected: at least two bullets, at least one of which is the sharding trap. If this section restates positives, rewrite it before committing.

- [ ] **Step 6: Commit**

```bash
git add website/content/docs/decisions/0008-flux-over-argocd.md
git commit -m "docs(decisions): record Flux over Argo CD as ADR-0008"
```

---

### Task 2: ADR-0009 — Cilium over the VPC CNI

**Files:**
- Create: `website/content/docs/decisions/0009-cilium-over-vpc-cni.md`

**Interfaces:**
- Produces: relref target `/docs/decisions/0009-cilium-over-vpc-cni.md`, cited by Task 10, Task 13 (networking section), and Task 8 (ADR-0015 references it for the GatewayClass lockstep).

**This is the highest-value ADR in the set.** It is the choice with the largest blast radius and the best-documented cost. It is also the one most likely to be written as an advertisement. The `### Negative` section is the point of the record.

**Source material — read before writing:**
- `CLAUDE.md` § "Cilium Prefix Delegation (ENABLED — WireGuard is load-bearing)"
- `opentofu/eks/configure/cilium-cni-config.tf`
- `opentofu/eks/init/helm_values/cilium.yaml`
- `website/content/docs/platform/networking/cilium.md`
- `.claude/rules/cilium-network-policies.md`

**Required claims:**
- Cilium replaces four components a default EKS build runs separately: the VPC CNI, kube-proxy, the NetworkPolicy engine, and the ingress controller (as the GatewayClass implementation).
- eBPF datapath; native routing with pod IPs from the secondary CIDR `100.64.0.0/16` via prefix delegation.
- Hubble gives flow-level observability the VPC CNI has no equivalent for.

**Required `### Negative` content — all four, each traceable:**
1. **cilium#43493** breaks the Gateway API L7 proxy on cross-node traffic under prefix delegation: the BPF ipcache sets `hastunnel` incorrectly for remote pods under native routing. The workaround is `encryption.type: wireguard` — node-to-node tunnels bypass the faulty routing logic. WireGuard is therefore load-bearing as a *workaround*, not chosen for performance, and cannot be disabled or swapped for ztunnel while the bug is open. Source: `CLAUDE.md`.
2. **`cniVersion` must be bumped by hand on every Cilium minor.** Because the platform sets `cni.configMap`, the chart default never applies. Cilium 1.20 moved it 0.3.1 → 1.0.0. Source: `opentofu/eks/configure/cilium-cni-config.tf` and `CLAUDE.md`.
3. **Prefix delegation does not apply to bootstrap nodes.** Node-group nodes are created in Stage 1, before Cilium exists in Stage 2, so their ENIs get individual secondary IPs that are never converted — a permanent ~42-IP ceiling instead of ~672. It surfaces as an `InstallFailed` HelmRelease in an unrelated namespace.
4. **`cilium-operator` probes for the Gateway API CRDs exactly once at startup** and permanently disables its Gateway API controller if any are missing — no crash, no alert. Symptoms cascade to `GatewayClass ACCEPTED=Unknown` and every `App` claim owning a route stuck `READY=False`. Source: `CLAUDE.md` § Troubleshooting.

**Required `### Neutral`:** pod subnets must not carry the `kubernetes.io/role/cni` tag (VPC-CNI uses it during Stage 1 bootstrap and leaves orphan ENIs when Cilium takes over); only `cilium.io/pod-subnet=true`.

- [ ] **Step 1: Read the source material**

```bash
sed -n '/Cilium Prefix Delegation/,/Pod Subnet Tagging/p' CLAUDE.md
cat opentofu/eks/configure/cilium-cni-config.tf
sed -n '/Gateways stuck/,/only \*after\*/p' CLAUDE.md
```

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use Cilium instead of the AWS VPC CNI
linkTitle: 0009 · Cilium over VPC CNI
weight: 90
description: Cilium replaces the VPC CNI, kube-proxy, the NetworkPolicy engine and the ingress controller with one eBPF datapath — at the cost of a load-bearing WireGuard workaround and a manual CNI-version bump per minor release.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context
```

Options: **Option 1: Cilium** (chosen), **Option 2: AWS VPC CNI + kube-proxy + ingress-nginx**, **Option 3: VPC CNI with Cilium in chaining mode** (network policy only, no kube-proxy replacement).

- [ ] **Step 3: Verify all four negatives are present and sourced**

```bash
sed -n '/### Negative/,/### Neutral/p' website/content/docs/decisions/0009-cilium-over-vpc-cni.md | grep -ci "43493\|cniVersion\|prefix delegation\|startup"
```

Expected: `4` or higher. If lower, a required cost is missing.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0009-cilium-over-vpc-cni.md
git commit -m "docs(decisions): record Cilium over the VPC CNI as ADR-0009"
```

---

### Task 3: ADR-0010 — VictoriaMetrics over Prometheus

**Files:**
- Create: `website/content/docs/decisions/0010-victoriametrics-over-prometheus.md`

**Interfaces:**
- Produces: relref target `/docs/decisions/0010-victoriametrics-over-prometheus.md`, cited by Task 10 and Task 13 (observability section).

**Source material:**
- `observability/base/victoria-metrics-k8s-stack/`, `victoria-logs/`, `victoria-traces/`
- `website/content/docs/platform/observability/metrics.md` and `logs.md`
- `.claude/rules/observability.md` — LogsQL field conventions

**Required claims:**
- One operator family and one query surface across metrics, logs and traces, rather than Prometheus + Loki + Tempo from three projects.
- CRDs for scrape config and alert rules (`VMServiceScrape`, `VMRule`) — the same "operator with a CRD over a chart with a values file" principle the Decisions index states.
- Lower resource consumption at equivalent retention. **Do not quote a ratio** unless you can cite a measurement from this repository; state it qualitatively otherwise.

**Required `### Negative`:**
- Smaller community than Prometheus; fewer third-party dashboards and runbooks assume it.
- LogsQL is not PromQL or LogQL — dot-notation Kubernetes fields (`kubernetes.container_name`, not `kubernetes_container_name`) and a `log.`-prefixed namespace after `unpack_json`. Every query written against Loki examples must be translated. Source: `.claude/rules/observability.md`.
- The stack ships both single and cluster variants of VictoriaMetrics and VictoriaLogs, so there are two `HelmRelease` files per component to keep aligned.

- [ ] **Step 1: Read the source material**

```bash
ls observability/base/victoria-metrics-k8s-stack/ observability/base/victoria-logs/
cat .claude/rules/observability.md
```

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use VictoriaMetrics rather than Prometheus
linkTitle: 0010 · VictoriaMetrics
weight: 100
description: Metrics, logs and traces run on the VictoriaMetrics family rather than Prometheus, Loki and Tempo, for one operator model and one query surface across all three signals.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context
```

Options: **Option 1: VictoriaMetrics family** (chosen), **Option 2: kube-prometheus-stack + Loki + Tempo**, **Option 3: a managed offering** (Amazon Managed Prometheus / Grafana Cloud).

- [ ] **Step 3: Check no unsourced numbers crept in**

```bash
grep -nE "[0-9]+ ?(x|×|%|GiB|GB) " website/content/docs/decisions/0010-victoriametrics-over-prometheus.md
```

Expected: no output, or every hit traceable to a file in this repo.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0010-victoriametrics-over-prometheus.md
git commit -m "docs(decisions): record VictoriaMetrics over Prometheus as ADR-0010"
```

---

### Task 4: ADR-0011 — OpenBao over HashiCorp Vault

**Files:**
- Create: `website/content/docs/decisions/0011-openbao-over-vault.md`

**Interfaces:**
- Produces: relref target `/docs/decisions/0011-openbao-over-vault.md`, cited by Task 10, Task 13 (security section), and Task 7 (ADR-0014 cross-references the licence reasoning).

**Source material:**
- `opentofu/openbao/cluster/`, `opentofu/openbao/management/`
- `CLAUDE.md` § OpenBao (namespace layout: shared platform services in root, tenants in namespaces)
- `website/content/docs/platform/security/openbao.md`
- Memory: the 2.6 deadlock is our write concurrency, mitigated with `-parallelism=1` in the management stack's workflows — **not** by pinning to 2.5.5. The repo runs 2.6.2.

**Required claims:**
- The trigger was HashiCorp's BUSL relicensing; OpenBao is the Linux Foundation fork. Frame this as a licence decision, not a technical-superiority claim.
- API-compatible enough that the `hashicorp/vault` OpenTofu provider configures it — verify in `opentofu/openbao/management/versions.tf` before asserting.

**Required `### Negative`:**
- Smaller ecosystem; upstream integrations and documentation still assume Vault.
- The 2.6 line carries a write-concurrency deadlock this platform hits during `tofu apply`. Mitigated with `-parallelism=1` in the management stack's Terramate workflow rather than by pinning back. Symptom: `bao status` hanging against `127.0.0.1` means core deadlock, never the VPN.
- The root CA private key lives in the live OpenBao mount, because the intermediate is signed inside OpenBao to keep the deploy unattended. Accepted for a reference platform, explicitly not for one where the root CA matters. Cross-link `/docs/platform/security/pki-and-secrets.md`.

- [ ] **Step 1: Read the source material and confirm the provider**

```bash
grep -rn "vault" opentofu/openbao/management/versions.tf opentofu/openbao/cluster/versions.tf
grep -rn "parallelism" opentofu/openbao/
sed -n '/### OpenBao/,/Namespace layout/p' CLAUDE.md
```

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use OpenBao rather than HashiCorp Vault
linkTitle: 0011 · OpenBao over Vault
weight: 110
description: Secrets and the private PKI run on OpenBao, the Linux Foundation fork, after HashiCorp relicensed Vault under the BUSL — accepting a smaller ecosystem and a 2.6 write-concurrency deadlock worked around with serialised applies.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context
```

Options: **Option 1: OpenBao** (chosen), **Option 2: stay on Vault under the BUSL**, **Option 3: AWS Secrets Manager + AWS Private CA only** (no self-hosted secrets engine).

Option 3 matters: the platform *does* use Secrets Manager alongside OpenBao, so the ADR must explain the split rather than pretend it was either/or.

- [ ] **Step 3: Verify the deadlock claim is stated correctly**

```bash
grep -n "parallelism\|2.5.5\|deadlock" website/content/docs/decisions/0011-openbao-over-vault.md
```

Expected: mentions `-parallelism=1`; must NOT claim the fix was pinning to 2.5.5.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0011-openbao-over-vault.md
git commit -m "docs(decisions): record OpenBao over Vault as ADR-0011"
```

---

### Task 5: ADR-0012 — Crossplane and OpenTofu, not either alone

**Files:**
- Create: `website/content/docs/decisions/0012-crossplane-and-opentofu.md`

**Interfaces:**
- Produces: relref target `/docs/decisions/0012-crossplane-and-opentofu.md`, cited by Task 10 and Task 13.

**This ADR records a boundary, not a winner.** Both tools are in the repository. The record explains where the line falls and why, and must not read as "Crossplane beat Terraform".

**Source material:**
- `opentofu/` — network, openbao, eks/init, eks/configure
- `infrastructure/base/crossplane/`
- `website/content/docs/decisions/0007-cloud-abstraction-boundaries.md` — the existing boundary ADR; this one must not contradict it
- `.claude/rules/crossplane-validation.md`

**Required claims:**
- The boundary is "below Kubernetes / above Kubernetes": OpenTofu owns VPC, OpenBao, the EKS cluster itself; Crossplane owns what applications claim once a cluster exists.
- The reason is reconciliation, not expressiveness: a claim reconciled by a controller is continuously enforced; a plan is true only at apply time. State explicitly that OpenTofu describes cloud resources *better*, and that this is not the axis the decision turns on.
- Compositions live in `Smana/crossplane-configuration` and ship as a package; this repo pins a version.

**Required `### Negative`:**
- Two IaC tools means two mental models, two state models, and two failure modes for contributors.
- Crossplane v2 traps this repo hit: managed resources are namespaced (v1 was cluster-scoped), a `ManagedResourceActivationPolicy` gates which CRDs install at all, and compositions writing third-party Kinds need an aggregate ClusterRole. Source: `.claude/rules/crossplane-validation.md`.
- The composition split across repositories means a schema change needs a release there and a pin bump here, and the App Wizard clones the same tag — two pins to move together.

- [ ] **Step 1: Read the source material**

```bash
cat .claude/rules/crossplane-validation.md
ls opentofu/
sed -n '/## Decision Outcome/,/## Consequences/p' website/content/docs/decisions/0007-cloud-abstraction-boundaries.md
```

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use Crossplane and OpenTofu, split at the Kubernetes boundary
linkTitle: 0012 · Crossplane + OpenTofu
weight: 120
description: OpenTofu provisions everything below Kubernetes and Crossplane everything applications claim above it, because a claim reconciled by a controller is continuously enforced while a plan is true only at apply time.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0007]({{< relref "/docs/decisions/0007-cloud-abstraction-boundaries.md" >}}) — where the platform draws its cloud boundary

---

## Context
```

Options: **Option 1: split at the Kubernetes boundary** (chosen), **Option 2: OpenTofu for everything**, **Option 3: Crossplane for everything** (including cluster bootstrap — chicken-and-egg).

- [ ] **Step 3: Check it does not contradict ADR-0007**

Read `0007`'s Decision Outcome and confirm this ADR's boundary statement is consistent with it. If they disagree, stop and raise it — one of them is wrong.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0012-crossplane-and-opentofu.md
git commit -m "docs(decisions): record the Crossplane/OpenTofu boundary as ADR-0012"
```

---

### Task 6: ADR-0013 — Tailscale over a bastion

**Files:**
- Create: `website/content/docs/decisions/0013-tailscale-over-bastion.md`

**Interfaces:**
- Produces: relref target `/docs/decisions/0013-tailscale-over-bastion.md`, cited by Task 10 and Task 13.

**Source material:**
- `CLAUDE.md` § "Tailscale Gateway API Integration"
- `website/content/docs/platform/networking/private-access.md`
- `opentofu/network/` — the subnet router
- `security/base/tailscale-operator/`

**Required claims:**
- ACL tags are the authorization primitive: `tag:k8s` for the general gateway (all members), `tag:admin` for the admin gateway (`group:admin` only). Both use `loadBalancerClass: tailscale` via `CiliumGatewayClassConfig`.
- The two-gateway split makes admin services *unreachable* for non-admins rather than merely unlisted.
- The EKS API endpoint is private; Tailscale is how it is reached at all.
- No bastion host to patch, and no long-lived SSH keys.

**Required `### Negative`:**
- A third-party dependency on the control path to a private cluster: if Tailscale's coordination server is unavailable, new connections cannot be established.
- Tailscale MagicDNS does not resolve the EKS API hostname, so reaching the private endpoint from a dev session needs VPC DNS (`10.0.0.2`) and `kubectl --server=<ip> --tls-server-name=<hostname>`. Verify against `website/content/docs/get-started/aws/access.md` before writing.
- `TF_VAR_tailscale_api_key` is the one secret the bootstrap cannot source from AWS Secrets Manager.

- [ ] **Step 1: Read the source material**

```bash
sed -n '/### Tailscale Gateway API Integration/,/## Key File Locations/p' CLAUDE.md
sed -n '1,120p' website/content/docs/platform/networking/private-access.md
```

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use Tailscale for private access rather than a bastion
linkTitle: 0013 · Tailscale private access
weight: 130
description: Private cluster access runs over Tailscale with ACL tags as the authorization primitive, splitting general and admin gateways, instead of a bastion host or a managed VPN appliance.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context
```

Options: **Option 1: Tailscale** (chosen), **Option 2: bastion host + SSH**, **Option 3: AWS Client VPN**.

- [ ] **Step 3: Verify the gateway tags against source**

```bash
grep -rn "tag:k8s\|tag:admin" --include="*.yaml" --include="*.tf" . | grep -v website/public | head
```

Expected: the tags used in the ADR appear in real manifests. Correct the ADR if they differ.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0013-tailscale-over-bastion.md
git commit -m "docs(decisions): record Tailscale over a bastion as ADR-0013"
```

---

### Task 7: ADR-0014 — OpenTofu over Terraform

**Files:**
- Create: `website/content/docs/decisions/0014-opentofu-over-terraform.md`

**Interfaces:**
- Produces: relref target `/docs/decisions/0014-opentofu-over-terraform.md`, cited by Task 10 and Task 13 (CLI tools section).

**Source material:**
- `mise.toml` — OpenTofu is the pinned binary
- `opentofu/*/versions.tf` — the provider set
- ADR-0011 (Task 4) — the same BUSL trigger; cross-link rather than repeat

**Required claims:**
- Same trigger as OpenBao: HashiCorp's BUSL relicensing in August 2023. Cross-link ADR-0011 with `relref`.
- OpenTofu is a drop-in for this repository's usage: the provider set is `hashicorp/aws`, `hashicorp/helm`, `hashicorp/tls`, `hashicorp/random`, `hashicorp/time`, `hashicorp/http`, `hashicorp/cloudinit`, `hashicorp/vault`, plus `integrations/github`, `tailscale/tailscale`, `gavinbunney/kubectl`. Confirm this list with the command in Step 1 — do not copy it from here if the repo has changed.
- Terramate orchestrates it and is tool-agnostic, so the switch did not touch orchestration.

**Required `### Negative` — the honest wrinkle:**
- `opentofu/openbao/*` is configured with the **`hashicorp/vault` provider**. The platform left Terraform over the licence and still depends on a HashiCorp-licensed provider to configure the fork it left it for. **Verify the provider's current licence before stating what it is** — check the provider repository, and if you cannot confirm it, describe the dependency without characterising the licence.
- The registry is different, so provider availability is not automatically identical; the community fork lags on rare providers.

- [ ] **Step 1: Confirm the provider list**

```bash
grep -rh "source *= *\"" opentofu/*/versions.tf opentofu/*/*/versions.tf 2>/dev/null | sed 's/.*source *= *//' | sort -u
grep -n "opentofu\|terraform" mise.toml
```

Use the actual output in the ADR.

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use OpenTofu rather than Terraform
linkTitle: 0014 · OpenTofu over Terraform
weight: 140
description: Infrastructure as code runs on OpenTofu after HashiCorp's BUSL relicensing — a drop-in for this repository's provider set, though the OpenBao stack still depends on the hashicorp/vault provider.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0011]({{< relref "/docs/decisions/0011-openbao-over-vault.md" >}}) — the same licence trigger, applied to Vault

---

## Context
```

Options: **Option 1: OpenTofu** (chosen), **Option 2: stay on Terraform**, **Option 3: Pulumi or CDK**.

- [ ] **Step 3: Verify the wrinkle is present**

```bash
grep -n "hashicorp/vault" website/content/docs/decisions/0014-opentofu-over-terraform.md
```

Expected: at least one hit in the `### Negative` section. This is the content that makes the ADR worth reading — if it is missing, the ADR is an advertisement.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0014-opentofu-over-terraform.md
git commit -m "docs(decisions): record OpenTofu over Terraform as ADR-0014"
```

---

### Task 8: ADR-0015 — Gateway API over ingress-nginx

**Files:**
- Create: `website/content/docs/decisions/0015-gateway-api-over-ingress-nginx.md`

**Interfaces:**
- Consumes: `/docs/decisions/0009-cilium-over-vpc-cni.md` from Task 2 — cross-link it, since Cilium is the GatewayClass implementation.
- Produces: relref target `/docs/decisions/0015-gateway-api-over-ingress-nginx.md`, cited by Task 10 and Task 13.

**Higher fabrication risk.** No prose exists to migrate — `technology-choices.md` never mentioned this choice. Every claim must come from a manifest.

**Source material:**
- `website/content/docs/platform/networking/gateway-api.md`
- `opentofu/eks/configure/locals.tf` — `gateway_api_crds_urls`
- `opentofu/eks/configure/variables.tf` — `gateway_api_version`
- `CLAUDE.md` § "Gateways stuck `Waiting for controller`"
- Memory: Cilium ≤1.19.4 crashes on Gateway API ≥v1.5.0 (TLSRoute-v1, cilium#45139, fixed in 1.19.5). Keep Cilium ≥1.19.5; `eks/configure` `gateway_api_version` must equal the Flux gitrepo pin.

**Required claims:**
- Role separation is the point: the platform owns `Gateway`, applications own `HTTPRoute`. An `Ingress` merges both into one object with vendor annotations.
- One CRD set serves both public ingress and Tailscale-private ingress — the two private gateways use `loadBalancerClass: tailscale` through `CiliumGatewayClassConfig`, which has no `Ingress` equivalent.
- Cilium implements the GatewayClass, so adopting Gateway API removed a component rather than adding one. Cross-link ADR-0009.
- ExternalDNS watches `HTTPRoute` directly.

**Required `### Negative`:**
- **Version lockstep with Cilium.** Cilium is the implementation, so the Gateway API CRD version cannot move independently: Cilium ≤1.19.4 crashes on Gateway API ≥v1.5.0 (cilium#45139). `gateway_api_version` in `opentofu/eks/configure` must equal the Flux gitrepo pin.
- **CRDs must exist before `cilium-operator` starts.** It probes exactly once and silently disables its Gateway API controller for the process lifetime if any CRD is missing. The durable fix is adding the CRD to `gateway_api_crds_urls`; `gateway_api_crds_urls` is append-only.
- Smaller ecosystem than `Ingress`: fewer examples, and some upstream charts still only template an `Ingress`.

- [ ] **Step 1: Read the source material and confirm ingress-nginx is genuinely absent**

```bash
cat opentofu/eks/configure/locals.tf | sed -n '/gateway_api_crds_urls/,/]/p'
grep -rn "gateway_api_version" opentofu/eks/configure/variables.tf
grep -ril "ingress-nginx" --include="*.yaml" . | grep -v website/public
```

The last command should return only `crds/base/crds-cert-manager.yaml` (a CRD schema field) and `observability/base/grafana-oncall/helmrelease-oncall.yaml` (chart values for a component not wired into any Kustomization). If it returns more, the ADR's premise needs adjusting.

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use Gateway API rather than Ingress
linkTitle: 0015 · Gateway API
weight: 150
description: Routing uses Gateway API rather than ingress-nginx, separating platform-owned Gateways from application-owned HTTPRoutes and serving public and Tailscale-private ingress from one CRD set — at the cost of version lockstep with Cilium.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0009]({{< relref "/docs/decisions/0009-cilium-over-vpc-cni.md" >}}) — Cilium is the GatewayClass implementation

---

## Context
```

Options: **Option 1: Gateway API with Cilium as the implementation** (chosen), **Option 2: ingress-nginx**, **Option 3: AWS Load Balancer Controller `Ingress`**.

Option 3 needs care: the repository *does* run the AWS Load Balancer Controller. Explain what it is used for rather than implying it is absent.

- [ ] **Step 3: Verify what the AWS Load Balancer Controller actually does here**

```bash
grep -rn "aws-load-balancer" infrastructure/base/aws-load-balancer-controller/*.yaml | head
grep -rln "ingressClassName\|alb.ingress" --include="*.yaml" infrastructure/ tooling/ observability/ security/ apps/ 2>/dev/null
```

Write Option 3 from this output, not from assumption.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0015-gateway-api-over-ingress-nginx.md
git commit -m "docs(decisions): record Gateway API over Ingress as ADR-0015"
```

---

### Task 9: ADR-0016 — Kyverno over Gatekeeper and native admission

**Files:**
- Create: `website/content/docs/decisions/0016-kyverno-over-gatekeeper.md`

**Interfaces:**
- Produces: relref target `/docs/decisions/0016-kyverno-over-gatekeeper.md`, cited by Task 10, Task 13, and Task 19 (supply-chain section).

**Higher fabrication risk** — same reason as Task 8. Nothing existed to migrate.

**Source material:**
- `security/base/kyverno/helmrelease-controller.yaml` and `helmrelease-policies.yaml`
- `website/content/docs/platform/security/policies.md`
- `docs/platform-constitution.md` § security defaults

**Required claims:**
- Policies are YAML resembling the Kubernetes objects they govern; Gatekeeper's are Rego, a second language to learn and review.
- Kyverno validates, **mutates and generates**; Pod Security Admission validates only. The platform uses `kyverno-policies`, the upstream pack implementing the Pod Security Standards as `ClusterPolicy` resources.
- `crds.install: false` on the controller — CRDs are managed under `crds/base/`, ahead of the controllers that consume them, like every other CRD here.

**Required `### Negative` — this is the one that matters:**
- **`kyverno-policies` installs with `values: {}`.** The enforced policy set *and* its audit-versus-enforce action come from the chart's own defaults rather than being chosen here. This is a deliberate deferral, and the ADR must record it as an accepted trade-off rather than omit it. Verify by reading the file — do not assume it is still `{}`.
- An admission webhook is in the request path for every matching API call; a failed webhook can block writes.
- Native `ValidatingAdmissionPolicy` (CEL, in-tree, no webhook) has since become viable and would remove that failure mode. Note it as a future reconsideration rather than pretending it did not exist.

- [ ] **Step 1: Read the source material and confirm `values: {}`**

```bash
cat security/base/kyverno/helmrelease-policies.yaml
grep -n "crds" security/base/kyverno/helmrelease-controller.yaml
grep -rln "ValidatingAdmissionPolicy" --include="*.yaml" . | grep -v website/public
```

The third command should return only `infrastructure/base/envoy-gateway/helmrelease.yaml` (an opt-in component's own chart), confirming native VAP is not the platform's policy engine.

- [ ] **Step 2: Write the ADR**

```markdown
---
title: Use Kyverno for admission policy
linkTitle: 0016 · Kyverno admission
weight: 160
description: Admission control runs on Kyverno rather than OPA Gatekeeper or Pod Security Admission alone, for YAML policies and mutation alongside validation — accepting that the enforced policy set currently comes from the upstream chart's defaults.
lastVerified: 2026-08-21
---

**Status**: Accepted
**Date**: 2026-08-21
**Deciders**: Smana (Platform Owner)
**Related Design**: N/A — records a choice predating the design workflow

---

## Context
```

Options: **Option 1: Kyverno** (chosen), **Option 2: OPA Gatekeeper**, **Option 3: Pod Security Admission alone**, **Option 4: native ValidatingAdmissionPolicy**.

- [ ] **Step 3: Verify the `values: {}` trade-off is recorded**

```bash
sed -n '/### Negative/,/### Neutral/p' website/content/docs/decisions/0016-kyverno-over-gatekeeper.md | grep -c "values"
```

Expected: at least `1`. If zero, the ADR is missing its most honest content.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/decisions/0016-kyverno-over-gatekeeper.md
git commit -m "docs(decisions): record Kyverno for admission policy as ADR-0016"
```

---

### Task 10: Index the records and make the sidebar readable

**Files:**
- Modify: `website/content/docs/decisions/_index.md` — the ADR table
- Modify: `website/content/docs/decisions/0001-…` through `0007-…` — the `linkTitle` frontmatter field on each

**Interfaces:**
- Consumes: all nine relref targets from Tasks 1–9.

Two halves of one job: the index lists the records, the sidebar navigates them. Both are currently unusable at sixteen entries — the index because nine rows are missing, the sidebar because every entry is a bare identifier.

- [ ] **Step 1: Add nine rows to the table**

Append to the existing table in `website/content/docs/decisions/_index.md`, after the ADR-0007 row, preserving the existing column format:

```markdown
| [0008]({{< relref "/docs/decisions/0008-flux-over-argocd.md" >}}) | Use Flux for GitOps reconciliation | Accepted | 2026-08-21 |
| [0009]({{< relref "/docs/decisions/0009-cilium-over-vpc-cni.md" >}}) | Use Cilium instead of the AWS VPC CNI | Accepted | 2026-08-21 |
| [0010]({{< relref "/docs/decisions/0010-victoriametrics-over-prometheus.md" >}}) | Use VictoriaMetrics rather than Prometheus | Accepted | 2026-08-21 |
| [0011]({{< relref "/docs/decisions/0011-openbao-over-vault.md" >}}) | Use OpenBao rather than HashiCorp Vault | Accepted | 2026-08-21 |
| [0012]({{< relref "/docs/decisions/0012-crossplane-and-opentofu.md" >}}) | Use Crossplane and OpenTofu, split at the Kubernetes boundary | Accepted | 2026-08-21 |
| [0013]({{< relref "/docs/decisions/0013-tailscale-over-bastion.md" >}}) | Use Tailscale for private access rather than a bastion | Accepted | 2026-08-21 |
| [0014]({{< relref "/docs/decisions/0014-opentofu-over-terraform.md" >}}) | Use OpenTofu rather than Terraform | Accepted | 2026-08-21 |
| [0015]({{< relref "/docs/decisions/0015-gateway-api-over-ingress-nginx.md" >}}) | Use Gateway API rather than Ingress | Accepted | 2026-08-21 |
| [0016]({{< relref "/docs/decisions/0016-kyverno-over-gatekeeper.md" >}}) | Use Kyverno for admission policy | Accepted | 2026-08-21 |
```

Titles must match each ADR's `title` frontmatter exactly. If Task 1–9 changed a title, use the file's actual value.

- [ ] **Step 2: Verify every row's title matches its file**

```bash
for n in 0008 0009 0010 0011 0012 0013 0014 0015 0016; do
  f=$(ls website/content/docs/decisions/${n}-*.md)
  printf '%s: ' "$n"
  grep -m1 '^title:' "$f" | sed 's/^title: //'
done
```

Compare against the table rows. Fix any mismatch.

- [ ] **Step 3: Retrofit `linkTitle` on the seven existing records**

Each currently reads `linkTitle: ADR-000N`, which is why the sidebar is a column of bare identifiers. Replace with:

| File | New `linkTitle` |
|---|---|
| `0001-use-kcl-for-crossplane-compositions.md` | `0001 · KCL compositions` |
| `0002-eks-pod-identity-over-irsa.md` | `0002 · EKS Pod Identity` |
| `0003-vllm-production-stack-over-kserve.md` | `0003 · vLLM over KServe` |
| `0004-amazon-s3-files-for-model-weights-storage.md` | `0004 · S3 Files for weights` |
| `0005-gke-standard-self-managed-cilium.md` | `0005 · Cilium on GKE` |
| `0006-nap-computeclass-over-karpenter.md` | `0006 · GKE ComputeClass` |
| `0007-cloud-abstraction-boundaries.md` | `0007 · Cloud boundaries` |

Leave `template.md`'s `linkTitle: Template` alone — it is already meaningful.

- [ ] **Step 4: Confirm no bare identifier survives**

```bash
grep -H "^linkTitle:" website/content/docs/decisions/*.md
```

Expected: sixteen `NNNN · …` values plus `Template`. No entry may read `ADR-NNNN` on its own.

- [ ] **Step 5: Check the sidebar renders and nothing wraps badly**

```bash
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

Then serve it and look at the Decisions section in the sidebar:

```bash
hugo server --source website --port 1313
```

Every entry should fit on one line at the default sidebar width. Shorten any that wrap — the number plus two or three words is the budget.

- [ ] **Step 6: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
```

A typo in any `relref` fails the Hugo build. That is the test on the index rows.

- [ ] **Step 7: Confirm the index lists sixteen records**

```bash
grep -c "^| \[00" website/content/docs/decisions/_index.md
```

Expected: `16`.

- [ ] **Step 8: Commit and open PR 1**

```bash
git add website/content/docs/decisions/
git commit -m "docs(decisions): index ADR-0008 through ADR-0016 and name the sidebar entries

Every record's linkTitle was its own identifier, so the navigation column
read ADR-0001 through ADR-0007 and said nothing. Sixteen of those would be
worse. Each entry now carries its number and what it decided."
```

---

# PR 2 — Reference and the rule

Tasks 11 and 12 are a red-green pair: the gate goes in first and must fail on the ten existing dead links, then the links are fixed and it passes. Do not reorder them.

---

### Task 11: Close the link gate (RED)

**Files:**
- Modify: `scripts/validate-links.sh` — the Python block at lines 34–72, and the comment at lines 22–26

**Interfaces:**
- Produces: a `validate-links.sh` that exits 1 while any raw relative Markdown link exists under `website/content/`.

**Why the current exclusion is wrong.** Lines 22–26 justify skipping `website/content/` because "Hugo already gates that tree harder than this script could — `refLinksErrorLevel: ERROR` fails the build on a dead ref". That setting is present (`website/hugo.yaml:10`) and it is true *for `ref`/`relref` shortcodes*. Raw Markdown links bypass it entirely. Verified: `hugo --source website --minify` exits 0 with all ten dead links in place. The comment is not wrong about Hugo; it is wrong about coverage.

The new check does not resolve Hugo links — it asserts the **absence of a construct**. Inside `website/content/`, pages address each other with `relref`, so a raw `](../…)` or `](./…)` is always a mistake.

- [ ] **Step 1: Confirm the gate currently passes despite the dead links**

```bash
./scripts/validate-links.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check; echo "HUGO EXIT=$?"
```

Expected: both pass. This is the bug.

- [ ] **Step 2: Count the links the new rule must catch**

```bash
grep -rn "](\.\./\|](\./" website/content --include="*.md" | grep -v relref | wc -l
```

Expected: `10`.

- [ ] **Step 3: Replace the exclusion with a two-mode check**

In `scripts/validate-links.sh`, replace line 44:

```python
files = [f for f in files if not f.startswith('website/content/')]
```

with a split, so the existing resolver keeps its tree and the new rule owns the other:

```python
# Two trees, two models. Outside website/content, links are file-relative and
# get resolved. Inside it, pages address each other with `relref`, so a raw
# relative link is always a mistake — Hugo's refLinksErrorLevel only governs
# `ref`/`relref` shortcodes and lets raw Markdown links through silently.
hugo_files = [f for f in files if f.startswith('website/content/')]
files = [f for f in files if not f.startswith('website/content/')]
```

Then, after the existing `for f in files:` loop, add the second loop. It reuses the same fence and code-span stripping so documentation samples are not flagged:

```python
for f in hugo_files:
    try:
        lines = open(f, encoding='utf-8', errors='replace').read().split('\n')
    except OSError:
        continue
    in_fence = False
    for line in lines:
        if fence.match(line):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        for m in link.finditer(code_span.sub('', line)):
            t = m.group(1)
            if t.startswith(('../', './')):
                print(f"{f}\t{t} (raw relative link — use a relref shortcode)")
```

- [ ] **Step 4: Update the header comment**

Replace lines 22–26 with:

```bash
# `website/content/` is Hugo's tree and gets a different check, not no check.
# Its internal links are `relref` shortcodes this regex cannot resolve, so the
# resolver above skips it — but Hugo's `refLinksErrorLevel: ERROR` only governs
# `ref`/`relref`, and raw Markdown links bypass it silently. So inside that tree
# this script asserts the absence of a construct instead: a raw `](../…)` or
# `](./…)` link is always wrong there. Two trees, two models, no gap.
```

- [ ] **Step 5: Run it and watch it FAIL**

```bash
./scripts/validate-links.sh; echo "EXIT=$?"
```

Expected: `EXIT=1`, with ten `BROKEN` lines naming `0002`, `0005`, `0006`, `0007` and each raw target. If it exits 0, the check is not wired up — fix before continuing.

- [ ] **Step 6: Verify it does not flag legitimate content**

```bash
./scripts/validate-links.sh --list | grep -v "raw relative link" | head
```

Expected: no output beyond the ten. Any extra hit means the fence or code-span stripping is not being applied — fix before continuing.

- [ ] **Step 7: Commit the gate alone**

Commit the failing gate separately so the red state is in history:

```bash
git add scripts/validate-links.sh
git commit -m "docs(ci): gate raw relative links inside website/content

Hugo's refLinksErrorLevel only governs ref/relref shortcodes; raw Markdown
links bypass it, so ten dead links in published ADRs passed both gates.
Inside website/content a raw relative link is always wrong — assert its
absence rather than trying to resolve Hugo's link model."
```

---

### Task 12: Fix the ten dead links (GREEN)

**Files:**
- Modify: `website/content/docs/decisions/0002-eks-pod-identity-over-irsa.md` (2 links)
- Modify: `website/content/docs/decisions/0005-gke-standard-self-managed-cilium.md` (3 links)
- Modify: `website/content/docs/decisions/0006-nap-computeclass-over-karpenter.md` (1 link)
- Modify: `website/content/docs/decisions/0007-cloud-abstraction-boundaries.md` (4 links)

**Interfaces:**
- Consumes: the failing gate from Task 11.

**Conversion rules:**

| Current target | Becomes | Why |
|---|---|---|
| `../platform-constitution.md` | `{{< relref "/docs/reference/platform-constitution.md" >}}` | Published on the site, under `reference/` not `decisions/` |
| `../superpowers/specs/2026-08-18-gcp-support-design.md` | `https://github.com/Smana/cloud-native-ref/blob/main/docs/superpowers/specs/2026-08-18-gcp-support-design.md` | Lives in the repo, not published to the site |
| `../specs/done/2024-Q1/0000-eks-pod-identity/spec.md` | `https://github.com/Smana/cloud-native-ref/blob/main/docs/specs/done/2024-Q1/0000-eks-pod-identity/spec.md` | Archived spec, not published |
| `../../.claude/rules/cilium-network-policies.md` | `https://github.com/Smana/cloud-native-ref/blob/main/.claude/rules/cilium-network-policies.md` | Repo rule file, not published |

- [ ] **Step 1: List exactly what needs changing**

```bash
grep -rn "](\.\./\|](\./" website/content --include="*.md" | grep -v relref
```

- [ ] **Step 2: Verify each GitHub target actually exists before linking to it**

```bash
ls docs/superpowers/specs/2026-08-18-gcp-support-design.md
ls docs/specs/done/2024-Q1/0000-eks-pod-identity/spec.md
ls .claude/rules/cilium-network-policies.md
ls website/content/docs/reference/platform-constitution.md
```

If any path is missing, the link must be removed rather than pointed at a 404. Report which.

- [ ] **Step 3: Apply the conversions**

Edit each of the four files per the table above. Preserve the link text — only the target changes.

- [ ] **Step 4: Run the gate and watch it PASS**

```bash
./scripts/validate-links.sh; echo "EXIT=$?"
```

Expected: `EXIT=0`, `==> All relative Markdown links resolve`.

- [ ] **Step 5: Confirm Hugo still builds and the relref resolves**

```bash
./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

A wrong `relref` path fails the build — that is the check on the constitution link.

- [ ] **Step 6: Commit**

```bash
git add website/content/docs/decisions/
git commit -m "docs(decisions): repoint ten links left over from the docs migration

Four ADRs still linked ../specs/, ../superpowers/ and ../../.claude/ paths
from the pre-site docs tree. Site-published targets become relref; repo-only
targets become absolute GitHub URLs."
```

---

### Task 13: Rewrite the Technology Stack page

**Files:**
- Modify: `website/content/docs/reference/technology-stack.md` — full rewrite

**Interfaces:**
- Consumes: all nine relref targets from Tasks 1–9, plus existing ADR-0001…0007.

**Shape — every section follows this, per the design:**

```markdown
## Networking

Cilium replaces four things a default EKS build would run separately: the
VPC CNI, kube-proxy, the NetworkPolicy engine, and the ingress controller.
Most of this section is a consequence of that one choice.

Versions for this layer live in `opentofu/config.tm.hcl` (bootstrap) and in
each component's `HelmRelease`.
**Decisions:** [ADR-0009]({{< relref "/docs/decisions/0009-cilium-over-vpc-cni.md" >}}) (Cilium),
[ADR-0015]({{< relref "/docs/decisions/0015-gateway-api-over-ingress-nginx.md" >}}) (Gateway API).

| Component | Role in the platform |
|-----------|----------------------|
| Cilium | eBPF datapath, kube-proxy replacement, NetworkPolicy enforcement, GatewayClass implementation |
| Gateway API | Routing CRDs; installed before Cilium, which implements them |
| ExternalDNS | Watches HTTPRoutes and writes Route 53 records |
```

**Rules:**
- Keep the existing seven sections and their component membership. Do not add or drop components.
- The `Version` and `Pinned in` columns are removed entirely.
- Where the old `Pinned in` cell carried a *fact* rather than a path — Atlas Operator not supporting `dir.remote`, the EFS CSI chart 4.x shipping driver 3.x for S3 Files, Valkey being provisioned per-tenant by the `KVStore` composition — move that fact into the Role cell. Do not lose it.
- The "What this table intentionally omits" section is deleted (defect D3 — it calls `technology-choices` "retired" while that page is still live at this point).
- Replace the page lead with the freshness policy.

- [ ] **Step 1: Capture the current component list so nothing is lost**

```bash
grep -E "^\| " website/content/docs/reference/technology-stack.md | awk -F'|' '{print $2}' | sed 's/^ *//;s/ *$//' | grep -v "^Component$\|^Tool$\|^-" > /tmp/stack-before.txt
wc -l /tmp/stack-before.txt
```

- [ ] **Step 2: Write the new lead**

```markdown
---
title: Technology Stack
weight: 20
description: What runs in the platform and what each component is responsible for, grouped by the layer it belongs to.
lastVerified: 2026-08-21
---

What runs here and what each piece is responsible for. No version numbers:
they belong in the repository, where Renovate opens a pull request for every
upstream release and CI renders the whole repository against it before it can
merge. A version copied into prose is out of date the first time that job
runs, and nothing fails when it happens.

Each section says where that layer's versions are declared, so you know which
file to open. For the *why* behind a choice, follow the **Decisions** line.
```

- [ ] **Step 3: Rewrite each of the seven sections**

Sections, in order: CLI tools; EKS bootstrap; Infrastructure; Security; Observability; Data and tooling; Managed AWS services.

Map ADRs to sections:

| Section | Decisions line |
|---|---|
| CLI tools | ADR-0014 (OpenTofu) |
| EKS bootstrap | ADR-0008 (Flux), ADR-0009 (Cilium), ADR-0015 (Gateway API) |
| Infrastructure | ADR-0001 (KCL), ADR-0012 (Crossplane/OpenTofu boundary) |
| Security | ADR-0002 (Pod Identity), ADR-0011 (OpenBao), ADR-0013 (Tailscale), ADR-0016 (Kyverno) |
| Observability | ADR-0010 (VictoriaMetrics) |
| Data and tooling | none |
| Managed AWS services | ADR-0004 (S3 Files), ADR-0007 (cloud boundaries) |

- [ ] **Step 4: Verify no component was dropped**

```bash
grep -E "^\| " website/content/docs/reference/technology-stack.md | awk -F'|' '{print $2}' | sed 's/^ *//;s/ *$//' | grep -v "^Component$\|^-" > /tmp/stack-after.txt
diff /tmp/stack-before.txt /tmp/stack-after.txt
```

Expected: no lines removed. Additions are acceptable only if a component genuinely exists and was missing before.

- [ ] **Step 5: Verify no version numbers survive**

```bash
grep -nE "[0-9]+\.[0-9]+\.[0-9]+|\| v?[0-9]+\.[0-9]+" website/content/docs/reference/technology-stack.md
```

Expected: no output, except a deliberate in-prose number where the number is the point (e.g. a Kubernetes minor in a compatibility note). Review each hit.

- [ ] **Step 6: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/reference/technology-stack.md
git commit -m "docs(reference): describe component roles instead of pinning versions

The version table was gated by nothing and drifted, which is the failure the
site's own 'counts rot silently' section warns about. Roles and the layer a
component belongs to do not rot; Renovate and CI own the versions."
```

---

### Task 14: Delete `technology-choices`, move its principles

**Files:**
- Delete: `website/content/docs/concepts/technology-choices.md`
- Modify: `website/content/docs/decisions/_index.md` — add the principles preamble
- Modify: `website/content/docs/concepts/_index.md:23` — remove the card

**Interfaces:**
- Consumes: the nine ADRs from Tasks 1–9, which absorb this page's "ones without records" section.

**The four principles to move verbatim** (from the deleted page's "The principles behind the picks"):

1. **Prefer the boring option, except where boring means unsupported.** Most choices here are conventional. The exceptions are deliberate and each has a decision record.
2. **Prefer an operator with a CRD to a Helm chart with a values file.** A CRD is an API that other things can compose against; a values file is a configuration blob that only its own chart understands.
3. **Prefer open source without a licence cliff.** Several picks are about avoiding a rug-pull rather than about technical merit.
4. **Pay for a choice once.** Where a component is load-bearing, it is worth being deliberate; where it is replaceable, it is not worth agonising over.

- [ ] **Step 1: Find every inbound link before deleting**

```bash
grep -rn "technology-choices" --include="*.md" --include="*.html" --include="*.yaml" . | grep -v website/public | grep -v docs/superpowers
```

Expected at this point: `website/content/docs/concepts/_index.md:23` only. Task 13 already removed the `technology-stack.md` reference. If anything else appears, fix it in this task.

- [ ] **Step 2: Add the principles to the Decisions index**

Insert into `website/content/docs/decisions/_index.md`, between the existing intro paragraph and the ADR table:

```markdown
## The principles behind the picks

**Prefer the boring option, except where boring means unsupported.** Most
choices here are conventional. The exceptions are deliberate, and each has a
record below.

**Prefer an operator with a CRD to a Helm chart with a values file.** A CRD is
an API that other things can compose against; a values file is a configuration
blob that only its own chart understands.

**Prefer open source without a licence cliff.** Several records below are about
avoiding a rug-pull rather than about technical merit.

**Pay for a choice once.** Where a component is load-bearing it is worth being
deliberate; where it is replaceable it is not worth agonising over.

## When a choice needs a record

A technology choice with a rejected alternative requires an ADR before merge.
If you can name what it was chosen over, write the record. If nothing credible
competed, it is an installation and not a decision — say so in the pull request
rather than leaving it unsaid. Version bumps, chart-value changes and
single-file fixes never need one.
```

- [ ] **Step 3: Delete the page and its card**

```bash
git rm website/content/docs/concepts/technology-choices.md
```

Then remove line 23 of `website/content/docs/concepts/_index.md` — the `{{< card link="technology-choices" … >}}` line — and check whether the `_index.md` intro paragraph still describes the section accurately with five cards instead of six.

- [ ] **Step 4: Verify nothing links to the deleted page**

```bash
grep -rn "technology-choices" --include="*.md" website/ | grep -v website/public
```

Expected: no output.

- [ ] **Step 5: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

A surviving `relref` to the deleted page fails the Hugo build. That is the test.

- [ ] **Step 6: Commit**

```bash
git add -A website/content/docs/concepts/ website/content/docs/decisions/_index.md
git commit -m "docs(concepts): retire technology-choices into the decision records

Its six undocumented picks are now ADR-0008 through ADR-0013, and its four
principles move to the Decisions index where they frame the records rather
than duplicating them."
```

---

### Task 15: Install the ADR rule

**Files:**
- Modify: `CLAUDE.md` — the *When a Design Is Required* table
- Modify: `.claude/rules/superpowers.md` — the Design-phase row of the gate table
- Modify: `docs/platform-constitution.md` — the spec-compliance checklist

**Interfaces:**
- Consumes: the wording already published in `decisions/_index.md` by Task 14. The three copies must match it word for word.

**The rule, verbatim:**

> A technology choice with a rejected alternative requires an ADR before merge. If you can name what it was chosen over, write the record. If nothing credible competed, it is an installation and not a decision — say so in the pull request rather than leaving it unsaid. Version bumps, chart-value changes and single-file fixes never need one.

- [ ] **Step 1: Add a row to the CLAUDE.md design table**

Find the *When a Design Is Required* table and add:

```markdown
| New Technology | Any component or pattern chosen over a named alternative — requires an [ADR](website/content/docs/decisions/) before merge |
```

Then add the full rule as a short paragraph under the table, and confirm the *When to Skip* list below it still reads correctly alongside the new row.

- [ ] **Step 2: Add the Design-phase gate**

In `.claude/rules/superpowers.md`, the gate table's Design row currently cites the platform constitution. Extend it so the ADR requirement is part of the same gate — a technology choice with a named rejected alternative needs its record on the branch before the PR opens.

- [ ] **Step 3: Add the checklist line**

In `docs/platform-constitution.md`, add to the spec-compliance checklist:

```markdown
- [ ] ADR written for any technology chosen over a named alternative
```

- [ ] **Step 4: Verify all four copies of the rule agree**

```bash
grep -rn "rejected alternative" CLAUDE.md .claude/rules/superpowers.md docs/platform-constitution.md website/content/docs/decisions/_index.md
```

Expected: four hits. Read them and confirm the wording matches. A rule stated three different ways is three rules.

- [ ] **Step 5: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 6: Commit and open PR 2**

```bash
git add CLAUDE.md .claude/rules/superpowers.md docs/platform-constitution.md
git commit -m "docs: require an ADR for any technology chosen over a named alternative"
```

---

# PR 3 — Front door and security

Independent of PRs 1 and 2. No task here links to a new ADR.

---

### Task 16: Homepage

**Files:**
- Modify: `website/content/_index.md`

**Two changes.** The hero, and collapsing two feature grids into one.

- [ ] **Step 1: Replace the headline and subtitle**

Replace the `hextra/hero-headline` and `hextra/hero-subtitle` blocks with:

```markdown
{{< hextra/hero-headline >}}
  An opinionated, production-ready Kubernetes platform, built on GitOps
{{< /hextra/hero-headline >}}

{{< hextra/hero-subtitle >}}
  Infrastructure as code with OpenTofu and Crossplane, continuous delivery
  with Flux, a private PKI and zero-trust networking, and a developer
  abstraction that turns one small YAML claim into a whole application.
  Deploy it into your own AWS account in about thirty minutes.
{{< /hextra/hero-subtitle >}}
```

Leave the hero badge and both hero buttons unchanged.

- [ ] **Step 2: Collapse the two feature grids**

The page currently has "What this repository is for" (4 cards) and "Browse the docs" (6 cards), covering the same sections twice. Delete the first `<h2>` and its grid; keep the second, retitled to `What's here`. Then, for the four sections the deleted grid covered better, replace the surviving card's `subtitle` with the deleted one's — the first grid's writing is stronger:

| Card | Subtitle to carry over |
|---|---|
| Get Started | "Three sequential stages — network, secrets, Kubernetes — driven by OpenTofu and Terramate. One command per stage, and the cluster comes up with Cilium, Flux and Karpenter already running." |
| Concepts | "GitOps as a dependency hierarchy rather than a slogan. Progressive complexity in a platform API. Zero trust that is enforced by policy, not asserted in a README." |
| Platform | "Cilium, Flux, Crossplane, OpenBao, VictoriaMetrics, Gateway API, Karpenter, KEDA — each with what it actually buys you here, and what it cost to adopt." |
| Guides | "Fork and adapt, add an application, add a cloud provider, troubleshoot." |

Leave the Reference and Decisions cards as they are.

- [ ] **Step 3: Check the trailing note still matches**

The page ends with a paragraph about AWS EKS today and a second cloud, linking ADR-0007. Confirm it still reads correctly after the grid change and that its `relref` resolves.

- [ ] **Step 4: Run the gates and eyeball the result**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
grep -c "hextra/feature-grid" website/content/_index.md
```

Expected: `2` (one opening, one closing shortcode) — down from `4`.

- [ ] **Step 5: Commit**

```bash
git add website/content/_index.md
git commit -m "docs(site): lead the homepage with what the platform is

The hero defined the project by what it isn't and took forty words to reach
a concrete noun. Reuses the README's opening line so GitHub and the site
say the same thing, and collapses two overlapping feature grids into one."
```

---

### Task 17: Name Superpowers in "How this is built"

**Files:**
- Modify: `website/content/docs/concepts/how-this-is-built.md`

**Do not touch** the "Where the process is expensive" section or "The evidence rule". Those are the strongest part of the page.

- [ ] **Step 1: Attribute the workflow**

In the "Design before implementation" section, before the numbered list, name the plugin so a reader can reproduce the method rather than only admire it:

```markdown
The sequence is not homegrown. It comes from
[Superpowers](https://github.com/obra/superpowers), a plugin whose skills
trigger on the shape of the work rather than on a command someone has to
remember, and which is declared in this repository's `.claude/settings.json`.
Non-trivial changes go through a fixed sequence:
```

- [ ] **Step 2: Link the long-form post**

At the end of the same section, after the paragraph about decision records:

```markdown
The wider practice this sits inside — how an AI coding agent is actually
wired into a platform-engineering workflow, and where it earns its keep — is
covered at length in [Agentic Coding: concepts and hands-on Platform
Engineering use cases](https://blog.ogenki.io/post/series/agentic_ai/ai-coding-agent/).
```

- [ ] **Step 3: Verify the settings claim before publishing it**

```bash
grep -n "superpowers" .claude/settings.json
```

If the plugin is not declared there, correct the sentence to match reality rather than leaving it. Report what you found.

- [ ] **Step 4: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 5: Commit**

```bash
git add website/content/docs/concepts/how-this-is-built.md
git commit -m "docs(concepts): name Superpowers as the source of the workflow

The page described a five-step method and attributed it to nothing, so a
reader could not reproduce it."
```

---

### Task 18: Rewrite SECURITY.md

**Files:**
- Modify: `SECURITY.md` — full rewrite

**What is wrong with the current file.** It is a template. "Uses development-grade certificates" — the platform runs a three-tier private PKI with automatic rotation. "Change all default passwords and secrets" — there are no default passwords; the operator credential is generated by OpenTofu into AWS Secrets Manager. "Enable Pod Security Standards" — Kyverno already enforces them at admission. The advice describes a repository this is not.

**Keep:** the reporting section (GitHub Security Advisory) and the "this is a reference repository" framing.

**Replace the posture section** with what is actually enforced, each line traceable:

| Property | Where it is enforced | Source |
|---|---|---|
| No static cloud credentials | EKS Pod Identity, never IRSA, never keys | ADR-0002; `security/base/epis/` |
| IAM scoped to `xplane-*` | Crossplane provider policies | `docs/platform-constitution.md` |
| No delete permission on stateful services | S3, IAM, Route 53 | `docs/platform-constitution.md` |
| Default-deny pod networking | CiliumNetworkPolicy per workload | `security/base/*/network-policy.yaml` |
| Private cluster API | Endpoint is private; reachable over Tailscale only | `opentofu/eks/init/` |
| TLS everywhere internally | Private PKI via OpenBao + cert-manager | `security/base/cert-manager/` |
| No secrets in Git | External Secrets from AWS Secrets Manager and OpenBao | `security/base/external-secrets/` |
| Restricted pod security context | Kyverno admission + Polaris on the rendered bundle | `security/base/kyverno/`; `scripts/validate-manifests.sh` |

**Replace "Known Demo Limitations"** with the two the repository actually documents:

- The **root CA private key is present in the live OpenBao mount**, because the intermediate is signed inside OpenBao to keep the deploy unattended. Accepted for a reference platform; not to be carried into a deployment where the root CA matters.
- **CiliumNetworkPolicy coverage is uneven.** The constitution requires one per pod-running workload; the observability stack does not yet meet that bar.

**Correct the tooling list** — the current one is vague and merges two different tools:

- Trivy — filesystem scan of the repository in CI (`scan-type: fs`), `CRITICAL,HIGH`, `ignore-unfixed`. **Not image scanning.**
- Checkov — Terraform and secrets frameworks, `soft_fail: true`: reports to GitHub Security, does not fail the build.
- TruffleHog — CI, `--only-verified`.
- `detect-secrets` — pre-commit, a different tool at a different point.
- Polaris — audits the rendered manifest bundle; this one *is* a gate.
- `flux schema validate` with `skipMissingSchemas: false` — an unknown Kind fails the build.

- [ ] **Step 1: Re-verify every CI claim before writing it**

```bash
sed -n '/Security scanning/,/kubernetes-validation/p' .github/workflows/ci.yaml
grep -n "detect-secrets" .pre-commit-config.yaml
grep -n "skipMissingSchemas" .fluxschema.yml
```

Write from this output. If any flag differs from the table above, the output wins.

- [ ] **Step 2: Write the new SECURITY.md**

Keep the `# Security Policy` heading and the reporting section as-is. Replace everything from "## Security Considerations" onward per the tables above.

- [ ] **Step 3: Add a pointer to the site**

```markdown
## How the platform implements this

The security model is documented in full at
[cnref.ogenki.io](https://cnref.ogenki.io):
[Zero trust](https://cnref.ogenki.io/docs/concepts/zero-trust/) for the model,
[Security](https://cnref.ogenki.io/docs/platform/security/) for the PKI, secret
flow and enforced policies.
```

- [ ] **Step 4: Verify no false claim survived**

```bash
grep -niE "development-grade|default password|elevated permission|checkov infrastructure analysis" SECURITY.md
```

Expected: no output.

- [ ] **Step 5: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
```

- [ ] **Step 6: Commit**

```bash
git add SECURITY.md
git commit -m "docs(security): describe the posture this repository actually has

The file was a template: it warned about development-grade certificates
against a three-tier private PKI, and about default passwords that are
generated into Secrets Manager. Replaces the invented limitations with the
two the repository genuinely documents."
```

---

### Task 19: Add the supply-chain section

**Files:**
- Modify: `website/content/docs/platform/security/policies.md` — append a section before "## RBAC"
- Modify: `website/content/docs/platform/security/_index.md` — link `SECURITY.md`

**Interfaces:**
- Consumes: the verified CI facts from Task 18 Step 1. The two must not disagree.

**This section must be narrower than "supply chain security" usually implies.** The honest content is what makes it worth adding:

- Trivy runs `scan-type: fs` over the repository, `severity: CRITICAL,HIGH`, `ignore-unfixed: true`. **No container image is scanned anywhere in CI** — say so.
- Checkov runs `soft_fail: true` on the `terraform,secrets` frameworks. It reports to GitHub Security and never blocks a merge. Advisory, not a gate.
- Secret detection happens twice with two tools: `detect-secrets` in pre-commit (local, pre-push) and TruffleHog in CI with `--only-verified` (post-push, verified findings only).
- Polaris audits the *rendered* bundle — ~69 controllers versus 1 raw Deployment in the source tree — and is a gate.
- `flux schema validate` with `skipMissingSchemas: false`: an unknown Kind fails the build rather than being skipped.
- Harbor is the registry. It carries **no Trivy configuration** in its `HelmRelease`, so its scanner sits at chart defaults. Do not claim the registry scans images unless you verify the chart's default and can cite it.

- [ ] **Step 1: Confirm the Harbor claim**

```bash
grep -n "trivy\|scanner" tooling/base/harbor/helmrelease-harbor.yaml
```

Expected: no output, confirming no explicit configuration. If output appears, describe what is configured instead.

- [ ] **Step 2: Confirm the Polaris controller counts before quoting them**

```bash
grep -n "69\|controllers" scripts/validate-manifests.sh CLAUDE.md | head
```

Use a number only if you can cite it; otherwise write it qualitatively.

- [ ] **Step 3: Write the section**

Add `## Supply chain` to `policies.md`, before `## RBAC`. Open with what the section is *not*:

```markdown
## Supply chain

What runs here is narrower than the phrase usually implies, so it is worth
being precise about which of these block a merge and which only report.
```

Then a table with a `Blocks a merge?` column, and prose for the Harbor caveat.

- [ ] **Step 4: Link SECURITY.md from the security index**

Add to `website/content/docs/platform/security/_index.md`, after the intro paragraph:

```markdown
The repository's [security policy](https://github.com/Smana/cloud-native-ref/blob/main/SECURITY.md)
covers reporting, the enforced posture in summary, and the limitations this
platform accepts as a reference implementation.
```

- [ ] **Step 5: Cross-check against SECURITY.md**

```bash
grep -niE "soft_fail|scan-type|only-verified|skipMissingSchemas" SECURITY.md website/content/docs/platform/security/policies.md
```

Both files must describe the same tools the same way. Reconcile any difference.

- [ ] **Step 6: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 7: Commit**

```bash
git add website/content/docs/platform/security/
git commit -m "docs(security): document the supply chain, including what it does not cover

Trivy scans the filesystem and no images; Checkov is soft-fail and blocks
nothing. Framing either as a gate would repeat the failure this rework fixes."
```

---

### Task 20: Correct ADR-0001 and ADR-0002 provenance

**Files:**
- Modify: `website/content/docs/decisions/0001-use-kcl-for-crossplane-compositions.md` — header block
- Modify: `website/content/docs/decisions/0002-eks-pod-identity-over-irsa.md` — header block

**The defect.** Both say `**Date**: 2024-01-15` and `**Deciders**: Platform Team`. Both files were added on 2026-01-06 in commit `6583c0ef` ("feat(ai): use the spec design development frawework"). The KCL conversion ADR-0001 describes landed 2024-09-29 ("convert compositions to use kcl function only"). So the date is not merely imprecise — it predates the work it records, on a site whose credibility rests on not doing that.

- [ ] **Step 1: Re-derive the real dates**

```bash
git log --diff-filter=A --format="%ad %h %s" --date=short -- "website/content/docs/decisions/0001-*" "docs/decisions/0001-*"
git log --diff-filter=A --format="%ad %s" --date=short -- "*.k" | tail -3
git log --diff-filter=A --format="%ad %s" --date=short -- "*pod-identity*" "*epi*" | tail -5
```

- [ ] **Step 2: Correct both header blocks**

Set `**Deciders**: Smana (Platform Owner)` on both, matching ADR-0003 and ADR-0004.

For the date, use the date of the decision the ADR records — the KCL conversion for 0001, the Pod Identity adoption for 0002 — and add a short parenthetical noting when the record itself was written, so the gap is visible rather than papered over:

```markdown
**Status**: Accepted
**Date**: 2024-09-29 (recorded retrospectively on 2026-01-06)
**Deciders**: Smana (Platform Owner)
```

Use whatever dates Step 1 actually produced.

- [ ] **Step 3: Update the Decisions index dates to match**

```bash
grep -n "| \[0001\]\|| \[0002\]" website/content/docs/decisions/_index.md
```

Change the `Date` cells to the corrected dates so the index and the records agree.

- [ ] **Step 4: Verify no `Platform Team` remains**

```bash
grep -rn "Platform Team" website/content/docs/decisions/
```

Expected: no output. ADR-0005, 0006 and 0007 also carry `Deciders: Platform Team` — correct those too if the grep finds them, for the same reason.

- [ ] **Step 5: Run the gates**

```bash
./scripts/validate-links.sh && ./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"
```

- [ ] **Step 6: Commit and open PR 3**

```bash
git add website/content/docs/decisions/
git commit -m "docs(decisions): correct the provenance on the earliest records

ADR-0001 and ADR-0002 carried a date predating the work they record and a
'Platform Team' that does not exist. Both were written on 2026-01-06."
```

---

## Final verification

Run before opening the last PR:

```bash
./scripts/validate-links.sh
./scripts/verify-doc-paths.sh
hugo --source website --quiet --minify --destination /tmp/hugo-check && echo "BUILD OK"

# 16 records indexed
grep -c "^| \[00" website/content/docs/decisions/_index.md

# every sidebar entry names a decision, none is a bare identifier
grep -h "^linkTitle:" website/content/docs/decisions/*.md | grep -c "·"

# no versions on the stack page
grep -cE "\| v?[0-9]+\.[0-9]+" website/content/docs/reference/technology-stack.md

# the deleted page is gone and unreferenced
grep -rn "technology-choices" --include="*.md" website/ | grep -v website/public

# the rule reads identically in four places
grep -rn "rejected alternative" CLAUDE.md .claude/rules/superpowers.md docs/platform-constitution.md website/content/docs/decisions/_index.md
```

Expected: `16`, `16`, `0`, no output, four matching hits.

`./scripts/validate-manifests.sh` is not required — no task in this plan touches a Kubernetes manifest.
