# Cloud-Partitioned OpenTofu Layout — Design

**Date:** 2026-08-23
**Status:** design approved, plan pending
**Branch:** `worktree-gcp-foundation`
**Implements:** workstream 6 of the [GCP support design](2026-08-18-gcp-support-design.md)
**Depends on:** the [GCP foundation plan](../plans/2026-08-18-gcp-foundation.md) Phases 0–4 (written, not applied)

---

## Why this design exists

`opentofu/` grew as a single-cloud tree. The GCP foundation added `opentofu/gcp/` alongside
`network/`, `eks/`, `openbao/` and `llm-platform/`, which are all AWS — so the layout now implies
that AWS *is* the platform and GCP is a guest. That asymmetry is not cosmetic. It has already
produced three concrete problems:

1. **The tailnet ACL belongs to whichever cloud got there first.** `tailscale_acl` is a
   tailnet-wide singleton declared in `opentofu/aws/network` with `overwrite_existing_content = true`.
   Both clusters share one tailnet, so the GCP subnet router's routes had to be authorised from the
   AWS stack ([`0451eedb`](https://github.com/Smana/cloud-native-ref/commit/0451eedb)). A second
   `tailscale_acl` in the GCP stack would make each apply silently overwrite the other's.

2. **Gateway API is applied two different ways.** AWS enumerates **10** CRD URLs in a
   `count`-indexed list; GCP applies the whole release bundle `for_each`-keyed. The enumeration is
   exactly what failed on 2026-08-19, when `cilium-operator` probed for CRDs two seconds before
   Flux created `backendtlspolicies` and silently disabled Gateway API for the life of the pod.
   Fixing that class of bug in one directory does not fix it in the other.

3. **The GCP stacks joined the global Terramate run order ungated.** `terramate list --run-order`
   places `opentofu/gcp/network` *first*, before the AWS network, so the repo-root
   `terramate script run deploy` — the command CLAUDE.md documents as "Deploy platform" — would
   build GCP. `drift detect` and `--reverse destroy` sweep them too. `llm-platform` guards precisely
   this with an `opt-in` tag plus `$TM_LLM_PLATFORM_ENABLED`; the GCP stacks copied neither.

The GCP support design deferred this refactor deliberately, on the grounds that it would be
"cheaper once the GCP shape is known rather than predicted". That precondition is now met: the shape
is known, and it produced the three problems above.

## Verified during design (evidence, not assumption)

| Question | Finding | How checked |
|---|---|---|
| Does moving a stack directory move its state? | **No.** Every backend block hardcodes a key (`key = "cloud-native-ref/network/opentofu.tfstate"`, `prefix = "cloud-native-ref/gcp/network"`). Relocating the directory leaves state untouched | read `backend.tf` in all stacks |
| Does moving a stack lose Terramate Cloud history? | **No.** Stack identity is the `id` UUID in `stack.tm.hcl`, not the path | read `stack.tm.hcl` in all stacks |
| Can the tailnet ACL be adopted by another stack safely? | **Yes.** `reset_acl_on_destroy` is Optional and unset in our config, so removal does not reset the tailnet policy; `overwrite_existing_content = true` "skips requirement to import acl before allowing changes" | provider source, `resource_acl.go` |
| Do the tailnet singletons support `import`? | **Yes** — `tailscale_acl` and `tailscale_dns_search_paths` both declare `ResourceWithImportState` / `ResourceImportedByID` | provider source |
| Are the stacks already tagged by cloud? | **Yes.** Every AWS stack carries `aws`, every GCP stack `gcp`. Cloud-scoped runs already work via `--tags`; the directory move is about legibility, not capability | `stack.tm.hcl` ×9 |
| Is `openbao/management` cloud-agnostic? | **No**, contrary to CLAUDE.md. It configures **both** the `vault` and `aws` providers and reads the root token from AWS Secrets Manager | `opentofu/aws/openbao/management/providers.tf` |
| Which relative paths break on a move? | Three call sites: `eks/init/workflows.tm.hcl` (×2), `openbao/management/workflows.tm.hcl` (×3). All use `../../../scripts/`, which is depth-dependent | grep over `opentofu/**/*.hcl` |
| How many files reference the AWS paths? | 57, including `.github/workflows/ci.yaml`, `.fluxschema.yml`, `CLAUDE.md` and `.claude/rules/opentofu.md` | grep over md/yaml/sh |

## Framing decisions

| Decision | Outcome |
|---|---|
| Partitioning principle | **By cloud, with a `shared/` peer** — `opentofu/{aws,gcp,shared}/`. Answers "where does this run", which is the question asked most often |
| Tailscale | A `shared/tailscale` stack owning **only** the tailnet-wide singletons. Per-device and per-domain resources stay with their cloud |
| OpenBao | Stays under `aws/`. It is AWS-coupled today via Secrets Manager; decoupling it is workstream 11, not this design |
| Gateway API | **Converge now** on a shared local module, re-keying AWS with `moved` blocks |
| GCP gating | `opt-in` tag + `$TM_GCP_ENABLED`, mirroring `llm-platform`, until both clouds work |
| Acceptance | **Plan-clean on AWS, applied on GCP** |
| Delivery | **Gated slices merged to `main`**, not one long-lived branch holding all of GCP support (see below) |

### Delivery: gated slices, not one long-lived branch

The tempting plan is to hold all of GCP support — infrastructure *and* applications, workstreams
1–15 — on one branch and merge when it all works. This design rejects that, for reasons measured
rather than asserted.

**`main` moves too fast to hold a rename against it.** In the six weeks to 2026-08-23 `main` took
**201 commits** (~5/day), touching **56 distinct files under `opentofu/`** — the same paths this
refactor renames. A branch holding a 57-file move rebases against that continuously, and every
rebase is a rename-versus-edit conflict.

**The repo already has the pattern for shipping unfinished work safely.** The self-hosted LLM
platform sits on `main` today, completely inert behind two independent gates: an `opt-in` Terramate
stack guarded by `$TM_LLM_PLATFORM_ENABLED`, and an umbrella Flux Kustomization with
`spec.suspend: true`. CLAUDE.md records the resulting property — *"the default
`terramate script run deploy` and the default Flux reconciliation both leave the cluster
LLM-free."* GCP support wants exactly that shape.

So changes are split by what they can break:

| Kind | Examples | Merge bar |
|---|---|---|
| **Touches AWS or shared paths** | the `aws/` move, `shared/tailscale`, Gateway API convergence | Criteria 1–7 and 14 (plan-clean on AWS). Does **not** wait on a GCP apply — GCP is inert while gated. Merge **promptly**; this is the piece that conflicts |
| **Additive GCP only** | `opentofu/gcp/**`, `clusters/gcp-0/**` | Criteria 8–10 and 14 (gates hold, nothing applies by default) |
| **Gate removal** | flipping `opt-in` / `$TM_GCP_ENABLED` and the suspended Kustomization | Criteria 11–13 — the full GCP end-to-end apply and clean teardown |

Each slice's bar is a subset of the success criteria below, not the whole list. Only the **final**
gate-removal PR needs a working GCP cluster; the refactor and the inert GCP code merge before that,
which is the entire point of gating them.

Merging the additive half early buys something a branch cannot: `./scripts/validate-manifests.sh`
renders and schema-validates the GCP tree on **every** PR, so it cannot silently rot while the rest
of the platform moves. On a branch it is validated only when someone remembers to rebase.

Two further arguments against the long branch, both specific to this repo:

- **The feature-branch-cluster footgun.** A cluster whose `FluxInstance` tracks `refs/heads/<branch>`
  loses its Git source when that branch is merged, because the repo auto-deletes head branches. A
  months-long branch doubles as a live Flux source, which makes that failure likely rather than
  hypothetical.
- **Reviewability.** `main` is CI-gated with six required checks and no admin bypass, so a
  fifteen-workstream PR lands whole or not at all.

The branch stays scoped to the **current** unit of work: this refactor plus the GCP foundation.
Later workstreams (`objectStore`, DNS/PKI, OpenBao on GCP, GPU/LLM) each get their own branch and
their own gated merge.

The accepted cost: `main` carries GCP code nobody runs for a while. The LLM platform demonstrates
that is tolerable; a rename war against five commits a day is not.

**Build order.** Safe work first, live-state work last, so the risky steps land on a layout that has
already stopped moving:

1. Terramate defect fixes and the GCP `opt-in` gate — no files move
2. The `opentofu/{aws,shared}/` move — large diff, state-neutral
3. `shared/tailscale` extraction — first live-state migration
4. Gateway API convergence — second live-state migration, on live CRDs
5. `clusters/gcp-0/` and the GCP apply — first real spend

Steps 3 and 4 are deliberately after the move so they are written once, in the final layout, rather
than written and then relocated.

### Why not partition by provider

The literal reading of "tailscale should live in its own directory like the other providers" would
give `aws/`, `gcp/`, `tailscale/`, and by the same logic `vault/`. It fragments: most stacks use
several providers. `openbao/management` uses `aws` + `vault`; both network stacks use a cloud
provider *and* `tailscale`. Under provider-partitioning, nearly every stack needs a judgement call
about its home. Under cloud-partitioning, only genuinely tailnet-wide or org-wide resources are
ambiguous, and `shared/` is their answer.

---

## Architecture

### Target layout

```
opentofu/
├── config.tm.hcl              globals (unchanged)
├── workflows.tm.hcl           root scripts (unchanged)
├── shared/
│   ├── tailscale/             tailnet-wide singletons
│   └── modules/
│       └── gateway-api-crds/  local module, called by both configure stacks
├── aws/
│   ├── network/
│   ├── eks/{init,configure}/
│   ├── openbao/{cluster,management}/
│   └── llm-platform/
└── gcp/
    ├── network/
    └── gke/{init,configure}/
```

`shared/modules/` holds local modules, not stacks — it contains no `stack.tm.hcl` and Terramate
never runs it directly.

### Path repairs the move requires

- **`after` references** — `/opentofu/aws/network` → `/opentofu/aws/network`, and the same for
  `eks/init`, `openbao/cluster`, `openbao/management`. Five references across five files.
- **Script call sites** — the three `../../../scripts/…` uses gain a directory level. Rather than
  re-count them, convert all to `${terramate.root.path.fs.absolute}/scripts/…`, which is already
  the pattern used for `terramate-destroy-confirm.sh` and is depth-independent. This is the one
  change that stops this class of breakage recurring at the next move.
- **Prose and config references** — 57 files. `scripts/verify-doc-paths.sh` and
  `./scripts/validate-links.sh` gate the documentation half; `.github/workflows/ci.yaml` (3 lines),
  `.fluxschema.yml`, `CLAUDE.md` and `.claude/rules/opentofu.md` are hand-checked.

### `shared/tailscale`

**Owns** (tailnet-wide, one per tailnet):

| Resource | Why it belongs here |
|---|---|
| `tailscale_acl` | Singleton. Two stacks declaring it overwrite each other silently |
| `tailscale_dns_nameservers` | Singleton |
| `tailscale_dns_search_paths` | Singleton, and a **list** — it must contain both clouds' domains |

**Leaves with each cloud** (per-device or per-domain, no collision possible):
`tailscale_dns_split_nameservers.*` (keyed by domain), `tailscale_tailnet_key`, and the subnet
router itself (an EC2 module on AWS, a `google_compute_instance` on GCP).

**Inputs are variables, not remote state.** Reading the clouds' CIDRs from their state would create
a cycle: each network needs the ACL's `autoApprovers` to exist before its router's routes are
usable, and the ACL needs the CIDRs. The CIDRs are static plan inputs, so a variable is both
simpler and acyclic.

**Ordering:** `shared/tailscale` has no `after`; both network stacks gain
`after = ["/opentofu/shared/tailscale"]`, so a registering router finds its routes already
auto-approved rather than pending manual approval.

**A live bug this fixes:** `tailscale_dns_search_paths` currently contains only
`eu-west-3.compute.internal` and `priv.aws.ogenki.io`. GCP's `priv.gcp.ogenki.io` is absent,
so tailnet devices would not resolve GCP private names even with the router up and its routes
approved. The shared stack takes both clouds' domains.

**Migration — `removed` + `import`, never destroy/create:**

```hcl
# opentofu/aws/network/tailscale.tf
removed {
  from = tailscale_acl.this
  lifecycle { destroy = false }
}
```

```hcl
# opentofu/shared/tailscale/import.tf
import {
  to = tailscale_acl.this
  id = "acl"
}
```

Verified safe above: removal does not reset the tailnet policy, and the new stack can adopt the ACL
without a prior import because `overwrite_existing_content = true`. The `import` block is still
used, because it makes the plan read **0 to change** rather than "1 to add" — on a resource that
gates access to every private endpoint, a visibly inert plan is worth the extra block.

### `shared/modules/gateway-api-crds`

Both `configure` stacks call one module:

```hcl
module "gateway_api_crds" {
  source              = "../../shared/modules/gateway-api-crds"
  gateway_api_version = var.gateway_api_version
}
```

The module applies the **whole `experimental-install.yaml` release bundle**, `for_each`-keyed by
manifest identity, with `server_side_apply`, `force_conflicts` and `wait`.

Three properties are load-bearing and each is a failure already observed:

- **The whole bundle, not an enumeration.** `cilium-operator` probes for the Gateway API CRDs once
  at startup and permanently disables its controller if any is missing — no crash, no alert, and
  only the leader replica logs it. Enumerating is what failed on 2026-08-19.
- **`server_side_apply`.** Client-side apply writes a `last-applied-configuration` annotation, and
  the `httproutes` CRD exceeds the 262144-byte limit. Confirmed on the Phase 1 gate cluster.
- **`for_each`, not `count`.** Keyed by manifest identity, so a future release that adds a CRD
  appends instead of shifting every index.

This is deliberately *unlike* the Cilium values, which the GCP design forks per-cloud precisely so
divergence stays visible. Here there is no intended divergence: same version, same experimental
channel, same bundle. A shared module is the single source of truth the refactor is for.

**AWS re-key.** AWS moves from `kubectl_manifest.gateway_api_crds[N]` (10 entries) to the module's
`for_each` form via `moved` blocks. The bundle also contains resources AWS does not list today —
a `ValidatingAdmissionPolicy` and the `gateway.networking.x-k8s.io` CRDs — which are clean creates.

> **Hard gate.** If the plan shows **any** destroy, stop and do not apply. A destroyed CRD takes
> every Gateway and HTTPRoute with it, and on this cluster that means both Tailscale gateways and
> every `App` claim that owns a route.

### Terramate model

- **GCP gating** — the three GCP stacks gain an `opt-in` tag and script overrides guarded on
  `$TM_GCP_ENABLED`, mirroring `opentofu/aws/llm-platform/workflows.tm.hcl`. Unset or not `"true"` means
  echo `[skip]` and exit 0, so sibling stacks are unaffected. This keeps the repo-root
  `terramate script run deploy` a safe one-shot for AWS while the GCP side is unproven, and is
  removed once both clouds work.
- **The missing configure workflow** — `gcp/gke/configure` has no `workflows.tm.hcl`, so it inherits
  the root `deploy` script and gets applied directly, without the `-var='cilium_version=…'` flags
  the init stack's stage-2 job passes. It gains its own, mirroring `eks/configure`.
- **Variable defaults** — `cilium_version`, `flux_operator_version` and `flux_instance_version` in
  `gcp/gke/configure` gain defaults mirroring the globals, matching the AWS pattern and its comment
  ("the local default is only consulted when running tofu directly").
- **Scoped entrypoints** — `--tags=aws` and `--tags=gcp` documented in `CLAUDE.md` and
  `.claude/rules/opentofu.md` as the way to run one cloud.

Both `terramate list --run-order` and its `--reverse` must produce a sane order after the move; the
reverse order is what `destroy` sweeps, so a wrong `after` destroys a dependency first.

---

## Goal & success criteria

Falsifiable. AWS is verified by plan; GCP by apply.

**Layout**

1. `terramate list` shows the nine stacks under `opentofu/{aws,gcp,shared}/`, none at the old paths.
2. `terramate list --run-order` places `shared/tailscale` before both network stacks, and each
   cloud's stacks in dependency order. `--reverse` inverts it correctly.
3. `./scripts/verify-doc-paths.sh` and `./scripts/validate-links.sh` exit 0 — no stale path survives
   in documentation.
4. No `../../../scripts/` remains in any `*.tm.hcl`; every script call site is root-absolute.

**State neutrality (the whole point of the AWS half)**

5. `terramate script run --tags=aws preview` shows **0 to destroy** and **0 to change** across every
   AWS stack, with only the expected `moved` and `import` entries.
6. Specifically for the tailnet: the plan shows no change to `tailscale_acl` content.
7. Specifically for Gateway API: the plan shows 0 CRDs destroyed. Additions from the bundle are
   expected and acceptable.

**Gating**

8. With `$TM_GCP_ENABLED` unset, `terramate script run deploy` from `opentofu/` reaches every GCP
   stack and each echoes `[skip]`, exit 0 — no GCP API call is made.
9. `terramate script run --no-tags=opt-in deploy` skips the GCP stacks and `llm-platform` entirely.
10. `TM_GCP_ENABLED=true terramate -C opentofu/gcp/gke/init script run deploy` runs both stages.

**GCP end-to-end**

11. A full apply from the new layout produces a reconciling cluster: `cilium status` OK,
    `flux get kustomizations -A` Ready, `kubectl get nodes` over the tailnet against the private
    endpoint.
12. The GCP private domain resolves from a tailnet device — proving the `search_paths` fix.
13. Teardown leaves **0 billable GCP compute resources**, verified by the orphan audit.

**Gates**

14. `tofu validate` and `tofu fmt -check -recursive opentofu/`, `trivy config`,
    `./scripts/validate-manifests.sh` (`Invalid: 0, Skipped: 0`), and `pre-commit run --all-files`
    all exit 0.

---

## Non-goals

- **OpenBao on GCP** (workstream 11), and decoupling `openbao/management` from AWS Secrets Manager.
  It stays under `aws/` and stays AWS-coupled.
- **Narrowing Crossplane's bootstrap `roles/editor`** — that belongs to the `GCPWorkloadIdentity`
  plan, where the permission model is designed.
- **Revisiting the Cilium values fork.** The per-cloud fork is deliberate and stays; only Gateway
  API converges, because only Gateway API has no intended divergence.
- **Applying anything on AWS.** The AWS half is verified by plan. Applying the `moved` and `import`
  blocks against the live cluster is a separate, deliberate act.
- **A cloud-neutral façade over the two network stacks.** They differ in behaviour, not just
  syntax; a shared surface would hide exactly what needs documenting.
- **Renaming stacks or changing their UUIDs.** Identity is preserved so Terramate Cloud history
  survives.

---

## Risks

| Risk | Mitigation |
|---|---|
| A `moved` key mismatch destroys a live Gateway API CRD, taking every Gateway and HTTPRoute | Hard gate: any destroy in the plan stops the work. Derive keys from `kubectl_file_documents` output, do not hand-write them |
| The tailnet ACL is emptied mid-migration, locking out the private EKS endpoint | `removed { destroy = false }` never calls the API; `reset_acl_on_destroy` is unset. Verified in provider source, not assumed |
| A missed path reference breaks CI after merge | `verify-doc-paths.sh` + `validate-links.sh` gate docs; CI, `.fluxschema.yml` and the rules files are hand-checked and listed in the plan |
| The `opt-in` gate is left on after both clouds work, silently skipping GCP forever | Removing it is an explicit, named task in the plan's final phase, tied to success criterion 11 |
| `opt-in` script overrides lose Terramate Cloud sync metadata | Accepted, and temporary — the same trade-off `llm-platform` already documents |
| Two sessions applying while stacks move | The work happens on one branch in one worktree; nothing merges until acceptance passes |

## Open questions

- **Does `shared/tailscale` need its own `opt-in` gate during the transition?** It is applied to a
  live tailnet on the first run. Leaning no — the migration is inert by construction — but the plan
  should make its first apply an explicit, reviewed step rather than part of a sweep.
- **Import ID for `tailscale_acl`.** The provider uses `ResourceImportedByID`; the exact ID string
  for a singleton must be confirmed against the provider before the plan's import block is written,
  not guessed.

## Quality gates the PR must pass before merge

- `tofu validate`, `tofu fmt -check -recursive opentofu/`
- `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .`
- `./scripts/validate-manifests.sh` → exit 0 with `Invalid: 0, Skipped: 0`
- `./scripts/validate-links.sh` and `./scripts/verify-doc-paths.sh` → exit 0
- `pre-commit run --all-files`
- `terramate list --run-order` and `--reverse` reviewed by eye
- Success criteria 1–14 evidenced inline per [`.claude/rules/process.md`](../../../.claude/rules/process.md)
