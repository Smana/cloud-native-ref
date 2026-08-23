# Cloud-Partitioned OpenTofu Layout Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure `opentofu/` into `{aws,gcp,shared}/`, extract the tailnet-wide Tailscale singletons into a stack neither cloud owns, converge Gateway API onto one shared module, and gate the GCP stacks so a repo-root Terramate run stays AWS-only — without changing one byte of AWS state.

**Architecture:** Four phases ordered safe-work-first. Phase 1 fixes three defects in the already-committed GCP stacks and gates them. Phase 2 moves directories, which is state-neutral because every backend key is an explicit string and every stack identity is a UUID. Phases 3 and 4 are the two live-state migrations — `removed`+`import` for the tailnet singletons, `moved` blocks for the Gateway API CRDs — done last so they are written once, in the final layout.

**Tech Stack:** OpenTofu 1.12.6, Terramate 0.17.2, `tailscale/tailscale ~> 0.29`, `gavinbunney/kubectl ~> 1.14`, Trivy 0.74.0, pre-commit.

**Branch:** `worktree-gcp-foundation` (continues the GCP foundation work).

**Spec:** [`docs/superpowers/specs/2026-08-23-cloud-partitioned-layout-design.md`](../specs/2026-08-23-cloud-partitioned-layout-design.md)

**Scope:** The refactor only — design phases 1–4. Building `clusters/gcp-mycluster-0/` and applying GCP are **Phases 5–6 of the [GCP foundation plan](2026-08-18-gcp-foundation.md)**, which resume after this plan lands with their paths updated by Task 8. Do not duplicate them here.

## Global Constraints

Every task's requirements implicitly include these.

- **Nothing is applied to AWS by this plan.** AWS is verified by `plan`/`preview` only. Applying the `removed`/`import`/`moved` blocks against the live cluster is a separate, deliberate act after this plan's acceptance passes.
- **AWS credentials are required** for Tasks 7, 10 and 14 (state reads and plans). They were **not** available in the authoring session — `aws eks list-clusters` returned "Unable to locate credentials". Whoever executes those tasks must have them, and must be on the tailnet for anything touching the private EKS endpoint.
- **Stack `id` UUIDs must never change.** Identity is the UUID, not the path; changing one loses Terramate Cloud history and orphans deployment records.
- **Backend `key`/`prefix` strings must never change.** They are what keeps state in place across the move. If a backend block is edited in this plan, it is a bug.
- **Every stack whose Terramate scripts run trivy needs its own `.trivyignore.yaml`.** The command is `--ignorefile=./.trivyignore.yaml`, resolved relative to the stack directory, not the repo root.
- **`main` is CI-gated** with six required checks, strict mode and `enforce_admins`. There is no admin bypass.
- Run every command from the repository root unless the step says otherwise.

---

## Pre-flight context (verified during plan writing — no action needed)

- **Three defects exist in the already-committed GCP stacks**, all found while reviewing Terramate:
  1. The GCP stacks carry no `opt-in` tag and no env gate, so `terramate list --run-order` puts `opentofu/gcp/network` **first**, before the AWS network, and a repo-root `deploy` would build GCP.
  2. `opentofu/gcp/gke/configure` has no `workflows.tm.hcl`, so it inherits the root `deploy` script and is applied without the `-var='cilium_version=…'` flags the init stack's stage-2 job passes. Its three version variables have no defaults, so that path fails with "No value for required variable".
  3. Neither GCP stack has a `.trivyignore.yaml`, so the trivy step in their scripts fails with `ignore file not found: ./.trivyignore.yaml`.
- **The five `after` references** that name AWS stack paths: `eks/init` (→ `/opentofu/network`, `/opentofu/openbao/management`), `eks/configure` (→ `/opentofu/eks/init`), `openbao/cluster` (→ `/opentofu/network`), `openbao/management` (→ `/opentofu/openbao/cluster`), `llm-platform` (→ `/opentofu/eks/init`).
- **The five depth-dependent script call sites**: `eks/init/workflows.tm.hcl` lines 60 and 115 (`../../../scripts/eks-recycle-bootstrap-nodes.sh`, `../../../scripts/eks-prepare-destroy.sh`), `openbao/management/workflows.tm.hcl` lines 18, 115, 135 (`../../../scripts/openbao-config.sh`). All other script calls already use `${terramate.root.path.fs.absolute}`, which is depth-independent.
- **Directories to move:** `opentofu/{network,eks,openbao,llm-platform}` → `opentofu/aws/`. Per-stack `.trivyignore.yaml` files exist in `network`, `eks/init`, `openbao/cluster`, `openbao/management` and `llm-platform` and move with them.
- **Tailscale singleton IDs are provider-generated UUIDs**, not stable strings: `resource_acl.go` sets `plan.ID = types.StringValue(createUUID())`, and import is `ImportStatePassthroughID` on `id`. The import ID must be **read from live state**, never guessed.
- **`reset_acl_on_destroy` is Optional and unset** in `opentofu/network/tailscale.tf`, so removing the resource does not reset the tailnet policy. `overwrite_existing_content = true` is set, which the provider documents as "skip requirement to import acl before allowing changes".
- **`kubectl_file_documents.manifests` is keyed by `manifest.GetSelfLink()`**, so `moved` block keys must be read from real output, not constructed by hand.
- **AWS enumerates 10 Gateway API CRD URLs** in `opentofu/eks/configure/locals.tf`, `count`-indexed, already with `server_side_apply`, `force_conflicts` and `wait = true`.

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `opentofu/gcp/gke/configure/workflows.tm.hcl` | Create | Stage-2 scripts so the root script never applies this stack bare |
| `opentofu/gcp/gke/configure/variables.tf` | Modify | Defaults for the three version vars, mirroring the AWS pattern |
| `opentofu/gcp/{network,gke/init}/.trivyignore.yaml` | Create | Per-stack ignorefile the trivy step requires |
| `opentofu/gcp/*/stack.tm.hcl` | Modify | Add the `opt-in` tag |
| `opentofu/gcp/*/workflows.tm.hcl` | Create/Modify | `$TM_GCP_ENABLED` gate |
| `opentofu/{network,eks,openbao,llm-platform}` | Move | → `opentofu/aws/` |
| `opentofu/aws/**/stack.tm.hcl` | Modify | Repoint the five `after` references |
| `opentofu/aws/{eks/init,openbao/management}/workflows.tm.hcl` | Modify | Root-absolute script paths |
| `opentofu/shared/tailscale/*` | Create | The tailnet-wide singleton stack |
| `opentofu/aws/network/tailscale.tf` | Modify | `removed` blocks; keep per-device resources |
| `opentofu/shared/modules/gateway-api-crds/*` | Create | One CRD-bundle module both clouds call |
| `opentofu/{aws/eks,gcp/gke}/configure/*` | Modify | Call the module; AWS adds `moved` blocks |
| `CLAUDE.md`, `.claude/rules/opentofu.md`, `.github/workflows/ci.yaml`, `.fluxschema.yml` | Modify | Path references |

---

## Phase 1 — Fix the GCP stacks and gate them

No files move in this phase. It closes three defects and makes the repo-root Terramate commands safe again.

### Task 1: Give the GCP stacks their trivy ignorefiles and the missing configure workflow

**Files:**
- Create: `opentofu/gcp/network/.trivyignore.yaml`, `opentofu/gcp/gke/init/.trivyignore.yaml`, `opentofu/gcp/gke/configure/workflows.tm.hcl`
- Modify: `opentofu/gcp/gke/configure/variables.tf`

- [ ] **Step 1: Reproduce the trivy failure**

Run:
```bash
cd opentofu/gcp/network && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml . ; cd -
```
Expected: `FATAL ... ignore file not found: ./.trivyignore.yaml`. This is what `terramate script run deploy` hits.

- [ ] **Step 2: Create both ignorefiles**

The GCP stacks suppress findings with inline `#trivy:ignore:` comments, so these files only need to exist with a valid shape.

```bash
cat > opentofu/gcp/network/.trivyignore.yaml <<'EOF'
# Per-stack ignorefile. The Terramate scripts run
#   trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
# from the STACK directory, so this file must exist here even when empty --
# without it trivy exits FATAL "ignore file not found" and the deploy fails
# before a single resource is planned.
#
# Findings in this stack are suppressed with inline `#trivy:ignore:` comments
# next to the resource they apply to, which keeps the justification with the
# code. Add ids here only for findings that have no single owning resource.
misconfigurations: []
EOF
sed 's|Per-stack ignorefile|Per-stack ignorefile|' opentofu/gcp/network/.trivyignore.yaml > opentofu/gcp/gke/init/.trivyignore.yaml
```

- [ ] **Step 3: Verify trivy now passes from both stack directories**

Run:
```bash
cd opentofu/gcp/network && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml . > /dev/null; echo "network: $?"; cd -
cd opentofu/gcp/gke/init && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml . > /dev/null; echo "init: $?"; cd -
```
Expected: `network: 0` and `init: 0`.

- [ ] **Step 4: Add defaults to the configure version variables**

The AWS side gives these defaults so a direct `tofu` run works; Terramate passes `-var` at run time and wins. Replace the three variable blocks in `opentofu/gcp/gke/configure/variables.tf`:

```hcl
variable "cilium_version" {
  description = "Cilium chart version. SHARED with AWS via opentofu/config.tm.hcl so both clouds upgrade together"
  type        = string
  # Default mirrors `cilium_version` in opentofu/config.tm.hcl. The Terramate
  # scripts pass -var=cilium_version=... at run time, so this is only consulted
  # when running tofu directly in this directory. Same pattern, and same reason,
  # as opentofu/aws/eks/configure/variables.tf.
  default = "1.20.0"
}

variable "flux_operator_version" {
  description = "Flux Operator chart version. Shared with AWS"
  type        = string
  default     = "0.55.0"
}

variable "flux_instance_version" {
  description = "Flux Instance chart version. Shared with AWS"
  type        = string
  default     = "0.55.0"
}
```

- [ ] **Step 5: Create the configure stack's own workflows**

Without this the stack inherits the root `deploy` script and is applied bare. Mirrors `opentofu/eks/configure/workflows.tm.hcl`.

```bash
cat > opentofu/gcp/gke/configure/workflows.tm.hcl <<'EOF'
# GKE Configure - Stage 2 Terramate scripts
# Must run AFTER opentofu/gcp/gke/init (Stage 1).
#
# This stack exists as its own Terramate stack so `terramate script run deploy`
# from the repo root does not apply it bare: the root script would run
# `tofu apply` without the -var flags the init stack's stage-2 job passes.
#
# No trivy step here, matching eks/configure: this stack creates no cloud
# resources, only in-cluster ones, and has no .trivyignore.yaml.

script "deploy" {
  name        = "GKE Configure Deployment (Stage 2)"
  description = "Apply the Gateway API CRDs, then install Cilium and Flux"

  job {
    name        = "deploy-configure"
    description = "Apply Cilium and Flux configuration"
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "apply", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}

script "preview" {
  name        = "GKE Configure Preview"
  description = "Preview Cilium and Flux changes"

  job {
    commands = [
      [global.provisioner, "init"],
      [global.provisioner, "validate"],
      [global.provisioner, "plan", "-out=out.tfplan", "-var-file=variables.tfvars", {
        sync_preview   = true
        tofu_plan_file = "out.tfplan"
      }],
    ]
  }
}

script "destroy" {
  name        = "GKE Configure Destroy"
  description = "Remove Cilium and Flux (WARNING: will break cluster networking)"

  job {
    commands = [
      ["bash", "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"],
      # `destroy` is a standalone entrypoint: unlike `deploy` it can be the first
      # tofu command run in a stack, so it has to init itself.
      [global.provisioner, "init", "-lock-timeout=5m"],
      [global.provisioner, "destroy", "-auto-approve", "-var-file=variables.tfvars"],
    ]
  }
}
EOF
```

- [ ] **Step 6: Verify Terramate still parses and the stack validates**

Run:
```bash
terramate list
tofu -chdir=opentofu/gcp/gke/configure validate
```
Expected: nine stacks listed, and `Success! The configuration is valid.`

- [ ] **Step 7: Commit**

```bash
git add opentofu/gcp
git commit -m "fix(gcp): give the GCP stacks their trivy ignorefiles and configure workflow

Three defects from the foundation commits:
- no per-stack .trivyignore.yaml, so the trivy step in the Terramate
  scripts exits FATAL 'ignore file not found' before anything is planned
- gcp/gke/configure had no workflows.tm.hcl, so the root deploy script
  applied it bare, without the -var flags the stage-2 job passes
- its three version variables had no defaults, so that path failed with
  'No value for required variable'"
```

### Task 2: Gate the GCP stacks behind `opt-in` and `$TM_GCP_ENABLED`

**Files:**
- Modify: `opentofu/gcp/network/stack.tm.hcl`, `opentofu/gcp/gke/init/stack.tm.hcl`, `opentofu/gcp/gke/configure/stack.tm.hcl`
- Create: `opentofu/gcp/network/workflows.tm.hcl`
- Modify: `opentofu/gcp/gke/init/workflows.tm.hcl`, `opentofu/gcp/gke/configure/workflows.tm.hcl`

- [ ] **Step 1: Prove the problem first**

Run: `terramate list --run-order`
Expected: `opentofu/gcp/network` appears **first**, before `opentofu/network`. That is the defect — a repo-root `deploy` would build GCP before the AWS network exists.

- [ ] **Step 2: Add the `opt-in` tag to all three GCP stacks**

Append `"opt-in"` to the `tags` list in each of the three `stack.tm.hcl` files, with this comment above it (same wording as `opentofu/llm-platform/stack.tm.hcl`):

```hcl
    # `opt-in` lets `terramate script run --no-tags=opt-in deploy` skip this
    # stack entirely (CI/audit path). The script overrides in workflows.tm.hcl
    # additionally guard on $TM_GCP_ENABLED so `terramate script run deploy`
    # from the opentofu/ root is also safe by default -- the script runs but
    # no-ops with a [skip] message.
    #
    # REMOVE THIS TAG AND THE GUARDS once GCP works end to end. Leaving them on
    # silently skips GCP forever, which looks identical to success.
    "opt-in",
```

- [ ] **Step 3: Write the gated scripts for `gcp/network`**

```bash
cat > opentofu/gcp/network/workflows.tm.hcl <<'HCL'
# GCP network — opt-in Terramate scripts.
#
# Why override the global scripts (opentofu/workflows.tm.hcl)?
#   Both clouds share one Terramate run order, so without a guard
#   `terramate script run deploy` from the opentofu/ root builds GCP -- and
#   because this stack sorts first, it builds GCP BEFORE the AWS network.
#   The gate keeps that command an AWS one-shot while GCP is unproven.
#
# How the gate works:
#   $TM_GCP_ENABLED unset or != "true"  -> echo [skip] + exit 0 (success, so
#                                          sibling stacks are unaffected)
#   $TM_GCP_ENABLED == "true"           -> run the real sequence
#
#   The double-`$$` escape keeps Terramate from interpolating `${VAR:-default}`;
#   the literal `${...}` must reach bash. `${global.provisioner}` interpolations
#   are intentional (Terramate-evaluated -> "tofu").
#
# Usage:
#   terramate script run deploy                                   # skipped
#   TM_GCP_ENABLED=true terramate script run deploy               # runs
#   terramate script run --no-tags=opt-in deploy                  # skipped, no env var
#
# Trade-off: these overrides lose Terramate Cloud sync metadata
# (sync_deployment / sync_preview), which are command-level annotations that do
# not compose with a single bash heredoc. Accepted while the gate is temporary;
# removing the gate restores the global scripts and their cloud sync.

script "deploy" {
  name        = "GCP Network Deployment (opt-in)"
  description = "Deploy the GCP network stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network: set TM_GCP_ENABLED=true to deploy"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "preview" {
  name        = "GCP Network Preview (opt-in)"
  description = "Preview GCP network changes when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network preview: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} validate
        trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
        ${global.provisioner} plan -out=out.tfplan -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "drift" "detect" {
  name        = "GCP Network Drift Check (opt-in)"
  description = "Detect drift when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network drift: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        ${global.provisioner} init
        ${global.provisioner} plan -out=out.tfplan -detailed-exitcode -lock=false -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}

script "destroy" {
  name        = "GCP Network Destroy (opt-in)"
  description = "Destroy the GCP network stack when TM_GCP_ENABLED=true"

  job {
    commands = [
      ["bash", "-c", <<-BASH
        if [ "$${TM_GCP_ENABLED:-}" != "true" ]; then
          echo "[skip] GCP network destroy: set TM_GCP_ENABLED=true"
          exit 0
        fi
        set -euo pipefail
        bash "${terramate.root.path.fs.absolute}/scripts/terramate-destroy-confirm.sh"
        ${global.provisioner} init -lock-timeout=5m
        ${global.provisioner} destroy -auto-approve -var-file=variables.tfvars
      BASH
      ],
    ]
  }
}
HCL
```

- [ ] **Step 4: Wrap the existing `gke/init` scripts in the same guard**

`opentofu/gcp/gke/init/workflows.tm.hcl` already defines `deploy`, `deploy-stage1`, `preview` and `destroy`. Convert each `job`'s `commands` to the single guarded bash form above, preserving the existing sequence inside the `else` branch — including the stage-2 `cd ../configure && …` line with its `-var` flags. Add the same guard to `gcp/gke/configure/workflows.tm.hcl` from Task 1.

Keep every existing comment in those files. They explain why the two-stage split exists and why there is no stage 3.

- [ ] **Step 5: Verify the gate holds with the env var unset**

Run:
```bash
terramate script run deploy 2>&1 | grep -E "^\[skip\]" | sort -u
```
Expected: three `[skip]` lines, one per GCP stack, and **no** GCP API call. If any AWS stack starts applying, abort immediately — this command is only safe because the AWS stacks are unchanged and this is a plan-writing environment. Prefer `terramate script run --tags=gcp deploy` to test the gate in isolation.

- [ ] **Step 6: Verify the tag filter also works**

Run:
```bash
terramate list --tags=gcp
terramate list --no-tags=opt-in
```
Expected: the first lists exactly the three GCP stacks; the second lists the AWS stacks with **no** GCP stack and no `llm-platform`.

- [ ] **Step 7: Commit**

```bash
git add opentofu/gcp
git commit -m "feat(gcp): gate the GCP stacks behind opt-in and TM_GCP_ENABLED

Both clouds share one Terramate run order, and gcp/network sorted FIRST --
so a repo-root 'terramate script run deploy' would have built GCP before
the AWS network. Mirrors the llm-platform gate: an opt-in tag for the
CI/audit path and a TM_GCP_ENABLED guard so the bare root command no-ops.

Both come off once GCP works end to end; the tag comment says so, because
a gate left on is indistinguishable from success."
```

### Task 3: Make every script call site depth-independent

Doing this **before** the move means Task 4 does not have to re-count `../` levels, and it stops this breaking again at the next move.

**Files:**
- Modify: `opentofu/eks/init/workflows.tm.hcl`, `opentofu/openbao/management/workflows.tm.hcl`

- [ ] **Step 1: List the depth-dependent call sites**

Run: `grep -rn '\.\./\.\./\.\./scripts' opentofu/ --include=*.hcl`
Expected: exactly five hits — `eks/init/workflows.tm.hcl` ×2, `openbao/management/workflows.tm.hcl` ×3.

- [ ] **Step 2: Replace them with the root-absolute form**

`${terramate.root.path.fs.absolute}` is already used for `terramate-destroy-confirm.sh` in the same files, so this is the established pattern, not a new one. Apply:

```bash
sed -i 's|"\.\./\.\./\.\./scripts/|"${terramate.root.path.fs.absolute}/scripts/|g' \
  opentofu/eks/init/workflows.tm.hcl \
  opentofu/openbao/management/workflows.tm.hcl
sed -i 's|\.\./\.\./\.\./scripts/eks-recycle-bootstrap-nodes\.sh|${terramate.root.path.fs.absolute}/scripts/eks-recycle-bootstrap-nodes.sh|g' \
  opentofu/eks/init/workflows.tm.hcl
```

- [ ] **Step 3: Verify none remain**

Run: `grep -rn '\.\./\.\./\.\./scripts' opentofu/ --include=*.hcl`
Expected: no output.

- [ ] **Step 4: Verify Terramate still parses**

Run: `terramate list && terramate script list > /dev/null && echo "scripts parse"`
Expected: nine stacks, then `scripts parse`.

- [ ] **Step 5: Commit**

```bash
git add opentofu/eks/init/workflows.tm.hcl opentofu/openbao/management/workflows.tm.hcl
git commit -m "refactor(terramate): make script call sites depth-independent

Five call sites used ../../../scripts/, which encodes the stack's depth
from the repo root and breaks the moment a stack moves. Every other call
already used \${terramate.root.path.fs.absolute}; these now match.

Prerequisite for the opentofu/aws/ move, which changes that depth."
```

---

## Phase 2 — The move

### Task 4: Move the AWS stacks under `opentofu/aws/`

**Files:**
- Move: `opentofu/{network,eks,openbao,llm-platform}` → `opentofu/aws/`
- Modify: the five `stack.tm.hcl` files carrying `after` references

- [ ] **Step 1: Record the pre-move state for comparison**

Run:
```bash
terramate list --run-order > /tmp/run-order-before.txt
grep -rn 'key *=\|prefix *=' opentofu --include=backend.tf | sort > /tmp/backends-before.txt
grep -rn '^  id ' opentofu --include=stack.tm.hcl | sort > /tmp/ids-before.txt
cat /tmp/backends-before.txt
```
Expected: nine backend entries. Keep these files; Task 7 diffs against them.

- [ ] **Step 2: Move the directories with `git mv`**

`git mv` preserves history as a rename rather than delete+add.

```bash
mkdir -p opentofu/aws
git mv opentofu/network      opentofu/aws/network
git mv opentofu/eks          opentofu/aws/eks
git mv opentofu/openbao      opentofu/aws/openbao
git mv opentofu/llm-platform opentofu/aws/llm-platform
```

- [ ] **Step 3: Repoint the five `after` references**

```bash
sed -i 's|"/opentofu/network"|"/opentofu/aws/network"|g;
        s|"/opentofu/eks/init"|"/opentofu/aws/eks/init"|g;
        s|"/opentofu/openbao/cluster"|"/opentofu/aws/openbao/cluster"|g;
        s|"/opentofu/openbao/management"|"/opentofu/aws/openbao/management"|g' \
  opentofu/aws/eks/init/stack.tm.hcl \
  opentofu/aws/eks/configure/stack.tm.hcl \
  opentofu/aws/openbao/cluster/stack.tm.hcl \
  opentofu/aws/openbao/management/stack.tm.hcl \
  opentofu/aws/llm-platform/stack.tm.hcl
```

- [ ] **Step 4: Confirm no stale `after` path survives**

Run: `grep -rn 'after' opentofu --include=stack.tm.hcl -A3 | grep '"/opentofu/' | grep -v '/opentofu/aws/\|/opentofu/gcp/\|/opentofu/shared/'`
Expected: no output.

- [ ] **Step 5: Confirm backends and IDs are untouched**

Run:
```bash
grep -rn 'key *=\|prefix *=' opentofu --include=backend.tf | sed 's|opentofu/aws/|opentofu/|' | sort > /tmp/backends-after.txt
diff <(sed 's|^opentofu/|opentofu/|' /tmp/backends-before.txt) /tmp/backends-after.txt && echo "BACKENDS UNCHANGED"
grep -rn '^  id ' opentofu --include=stack.tm.hcl | sed 's|.*id|id|' | sort > /tmp/ids-after.txt
diff <(sed 's|.*id|id|' /tmp/ids-before.txt | sort) /tmp/ids-after.txt && echo "IDS UNCHANGED"
```
Expected: `BACKENDS UNCHANGED` and `IDS UNCHANGED`. **If either differs, stop** — a changed backend key orphans state and a changed UUID orphans Terramate Cloud history.

- [ ] **Step 6: Verify the run order**

Run: `terramate list --run-order`
Expected: nine stacks, all under `opentofu/{aws,gcp}/`, with `aws/network` before `aws/openbao/cluster` before `aws/openbao/management` before `aws/eks/init` before `aws/eks/configure`, and the GCP chain intact.

- [ ] **Step 7: Commit**

```bash
git add -A opentofu
git commit -m "refactor(opentofu): move the AWS stacks under opentofu/aws/

Cloud-partitioned layout: opentofu/{aws,gcp,shared}/. Pure relocation --
no backend key and no stack UUID changes, so no state moves and Terramate
Cloud history is preserved. Verified by diffing both sets before and after.

The five 'after' references are repointed; script call sites were made
depth-independent in the previous commit so none needed re-counting."
```

### Task 5: Update every reference outside `opentofu/`

**Files:**
- Modify: `CLAUDE.md`, `.claude/rules/opentofu.md`, `.claude/rules/superpowers.md`, `.github/workflows/ci.yaml`, `.fluxschema.yml`, and any doc the gates flag

- [ ] **Step 1: Find every surviving reference**

Run:
```bash
grep -rn "opentofu/\(network\|eks\|openbao\|llm-platform\)" \
  --include="*.md" --include="*.yaml" --include="*.yml" --include="*.sh" --include="*.tf" \
  . | grep -v "^./.claude/worktrees" | grep -v "^./docs/specs/" | tee /tmp/stale-refs.txt | wc -l
```
Expected: a non-zero count. `docs/specs/` is the read-only archive and is excluded deliberately — it records history and must not be rewritten.

- [ ] **Step 2: Rewrite them**

```bash
cut -d: -f1 /tmp/stale-refs.txt | sort -u | while read -r f; do
  sed -i 's|opentofu/network|opentofu/aws/network|g;
          s|opentofu/eks|opentofu/aws/eks|g;
          s|opentofu/openbao|opentofu/aws/openbao|g;
          s|opentofu/llm-platform|opentofu/aws/llm-platform|g' "$f"
done
```

- [ ] **Step 3: Guard against double-rewriting**

Run: `grep -rn "opentofu/aws/aws/\|opentofu/gcp/aws/" . | grep -v "^./.claude/worktrees" | head`
Expected: no output. If any appear, the sed ran twice on a file — fix those paths by hand.

- [ ] **Step 4: Run both documentation gates**

Run:
```bash
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
```
Expected: both exit 0. These are what catch a path that exists in prose but not on disk.

- [ ] **Step 5: Check CI explicitly**

Run: `grep -n "opentofu" .github/workflows/ci.yaml`
Expected: the three `.tls` placeholder lines now read `opentofu/aws/openbao/cluster/.tls/…`. CI writes those files so `tofu validate` can run without real certificates; a stale path means CI fails after merge, not before.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "docs(opentofu): repoint every reference at the aws/ layout

57 files referenced the old paths, including CI (the openbao .tls
placeholders), .fluxschema.yml, CLAUDE.md and the rules files.

docs/specs/ is deliberately untouched: it is the read-only archive of the
retired SDD workflow and records what the paths were at the time.

Verified with verify-doc-paths.sh and validate-links.sh, which are what
catch a path that exists in prose but no longer on disk."
```

---

## Phase 3 — Extract the tailnet singletons

> **Live-state migration.** Everything here touches a tailnet that is the only route to the private EKS endpoint. The design verified the two facts that make it safe: `reset_acl_on_destroy` is unset, so removal does not reset the policy, and `removed { destroy = false }` never calls the API at all.

### Task 6: Create the `shared/tailscale` stack

**Files:**
- Create: `opentofu/shared/tailscale/{versions,providers,backend,variables,main,outputs}.tf`, `variables.tfvars`, `stack.tm.hcl`, `.trivyignore.yaml`

- [ ] **Step 1: Read what is being moved**

Run: `grep -n "^resource" opentofu/aws/network/tailscale.tf`
Expected: seven resources. Three are tailnet-wide singletons and move: `tailscale_acl.this`, `tailscale_dns_nameservers.this`, `tailscale_dns_search_paths.this`. Four stay with AWS: both `tailscale_dns_split_nameservers` (keyed by domain, no collision), `tailscale_tailnet_key.this`, and the subnet-router module.

- [ ] **Step 2: Write the stack scaffolding**

```bash
mkdir -p opentofu/shared/tailscale
cat > opentofu/shared/tailscale/versions.tf <<'EOF'
terraform {
  required_version = "~> 1.5"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "~> 0.29"
    }
  }
}
EOF
cat > opentofu/shared/tailscale/providers.tf <<'EOF'
provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailnet
}
EOF
cat > opentofu/shared/tailscale/backend.tf <<'EOF'
# S3, matching the AWS stacks: this stack predates any GCP bucket and the
# tailnet is not owned by either cloud. The choice of backend does not make it
# an AWS stack -- it makes it a stack whose state lives where the other state
# already lives.
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/shared/tailscale/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
EOF
cat > opentofu/shared/tailscale/.trivyignore.yaml <<'EOF'
# Required by the trivy step in the Terramate scripts, which resolves
# ./.trivyignore.yaml relative to the stack directory.
misconfigurations: []
EOF
```

- [ ] **Step 3: Write `variables.tf`**

CIDRs arrive as variables, not remote state — reading them from the cloud stacks would create a cycle, because each network needs this stack's `autoApprovers` before its router's routes are usable.

```hcl
variable "tailscale_api_key" {
  description = "Tailscale API key"
  type        = string
  sensitive   = true
}

variable "tailnet" {
  description = "Tailscale tailnet name"
  type        = string
}

variable "admin_users" {
  description = "Members of group:admin, which is the only group allowed to reach tag:admin services such as Hubble UI"
  type        = list(string)
}

variable "advertised_routes" {
  description = <<-EOT
    Every CIDR any subnet router advertises into this tailnet, across all clouds.

    Passed as a variable rather than read from the cloud stacks' state on
    purpose: those stacks depend on THIS one (a route is advertised but unusable
    until autoApprovers permits it), so reading their state here would make the
    dependency circular. The CIDRs are static plan inputs anyway.

    Must stay in sync with:
      opentofu/aws/network  vpc_cidr
      opentofu/gcp/network  advertised_routes output
  EOT
  type        = map(list(string))

  validation {
    condition     = alltrue([for _, cidrs in var.advertised_routes : alltrue([for c in cidrs : can(cidrhost(c, 0))])])
    error_message = "Every advertised route must be a valid IPv4 CIDR block."
  }
}

variable "search_domains" {
  description = "DNS search paths for the whole tailnet. A LIST, and tailnet-wide: every cloud's private domain must appear here or its names do not resolve from a tailnet device"
  type        = list(string)
}

variable "split_dns_domains" {
  description = "Not used here. Split-DNS is per-domain and therefore owned by each cloud's network stack, where the resolver address lives"
  type        = map(string)
  default     = {}
}
```

- [ ] **Step 4: Write `main.tf` with the three singletons**

Copy the ACL body verbatim from `opentofu/aws/network/tailscale.tf` so the migration is content-identical, replacing only the hardcoded CIDR and admin list with the variables:

```hcl
# The three tailnet-wide singletons.
#
# These live here, and nowhere else, because there is exactly ONE of each per
# tailnet. When they lived in the AWS network stack, the GCP subnet router's
# routes had to be authorised from AWS -- and a second tailscale_acl in the GCP
# stack would have made each apply silently overwrite the other's, last apply
# winning, with no error.
resource "tailscale_acl" "this" {
  overwrite_existing_content = true

  acl = jsonencode({
    groups = {
      "group:admin" = var.admin_users
    }

    acls = concat([
      { action = "accept", src = ["group:admin"], dst = ["tag:admin:*"] },
      { action = "accept", src = ["autogroup:member"], dst = ["tag:ci:*"] },
      { action = "accept", src = ["autogroup:member"], dst = ["tag:k8s:*"] },
      { action = "accept", src = ["autogroup:member"], dst = ["autogroup:member:*"] },
      { action = "accept", src = ["tag:k8s-operator"], dst = ["tag:k8s:*", "tag:admin:*"] },
      ],
      # One rule per cloud, generated from the same map that drives
      # autoApprovers below, so a route can never be auto-approved yet
      # unreachable -- the failure mode that looks like a routing bug.
      [for cidr in flatten(values(var.advertised_routes)) : {
        action = "accept"
        src    = ["autogroup:member"]
        dst    = ["${cidr}:*"]
      }]
    )

    ssh = [
      {
        action = "check"
        src    = ["autogroup:member"]
        dst    = ["autogroup:self"]
        users  = ["autogroup:nonroot"]
      }
    ]

    autoApprovers = {
      routes = { for cidr in flatten(values(var.advertised_routes)) : cidr => [var.tailnet] }
    }

    tagOwners = {
      "tag:ci"           = [var.tailnet]
      "tag:k8s"          = ["tag:k8s-operator"]
      "tag:k8s-operator" = [var.tailnet]
      "tag:admin"        = ["tag:k8s-operator"]
    }
  })
}

resource "tailscale_dns_nameservers" "this" {
  nameservers = [
    "1.1.1.1" # Cloudflare
  ]
}

# A LIST, and tailnet-wide. Before this stack existed it held only the AWS
# entries, so GCP private names would not have resolved from a tailnet device
# even with the GCP router up and its routes approved.
resource "tailscale_dns_search_paths" "this" {
  search_paths = var.search_domains
}
```

- [ ] **Step 5: Write `stack.tm.hcl` with a fresh UUID**

Generate one — do not copy another stack's:

```bash
python3 -c "import uuid; print(uuid.uuid4())"
```

```hcl
stack {
  name        = "Shared Tailscale"
  description = "Tailnet-wide singletons: ACL, DNS nameservers, DNS search paths. Owned by neither cloud"
  id          = "<uuid-from-the-command-above>"

  # No `after`. Both network stacks depend on THIS one: a subnet router that
  # registers before autoApprovers exists advertises routes that stay pending
  # manual approval, which presents as a routing failure rather than a policy gap.

  tags = [
    "shared",
    "tailscale",
    "network"
  ]
}
```

- [ ] **Step 6: Write `variables.tfvars`**

```hcl
tailnet     = "smainklh@gmail.com"
admin_users = ["smainklh@gmail.com"]

# Must match opentofu/aws/network vpc_cidr and opentofu/gcp/network's
# advertised_routes output. Re-run the overlap check in the GCP foundation
# plan's Task 3 Step 2 before changing any of these.
advertised_routes = {
  aws = ["10.0.0.0/16"]
  gcp = ["10.10.0.0/16", "100.65.0.0/16", "10.11.0.0/20", "172.16.0.0/28"]
}

search_domains = [
  "eu-west-3.compute.internal",
  "priv.cloud.ogenki.io",
  "priv.gcp.cloud.ogenki.io",
]
```

- [ ] **Step 7: Validate and commit**

Run:
```bash
tofu -chdir=opentofu/shared/tailscale init -backend=false
tofu -chdir=opentofu/shared/tailscale validate
tofu fmt -check -recursive opentofu/shared/
terramate list | grep shared/tailscale
```
Expected: `Success!`, fmt exit 0, and the stack listed.

```bash
git add opentofu/shared
git commit -m "feat(tailscale): add the shared stack owning the tailnet singletons

tailscale_acl, tailscale_dns_nameservers and tailscale_dns_search_paths
are one-per-tailnet. Owned by the AWS network stack they forced GCP's
routes to be authorised from AWS, and a second tailscale_acl anywhere
would make each apply silently overwrite the other's.

CIDRs arrive as a variable, not from the cloud stacks' remote state:
those stacks depend on this one, so reading their state would be circular.

Also fixes a live bug -- search_paths held only the AWS domains, so GCP
private names would not resolve from a tailnet device.

Not yet adopted: the removed/import migration is the next commit."
```

### Task 7: Migrate the singletons with `removed` and `import`

> **Requires AWS credentials** to read the current state.

**Files:**
- Modify: `opentofu/aws/network/tailscale.tf`
- Create: `opentofu/shared/tailscale/import.tf`

- [ ] **Step 1: Read the three resource IDs from live state**

The IDs are provider-generated UUIDs (`createUUID()`), so they must be read, never guessed:

```bash
cd opentofu/aws/network
tofu init -lock-timeout=5m
for r in tailscale_acl.this tailscale_dns_nameservers.this tailscale_dns_search_paths.this; do
  echo -n "$r = "
  tofu state show "$r" | grep -E '^\s+id\s+=' | head -1
done
cd -
```
Expected: three UUID strings. **Record them**; Step 3 needs them verbatim.

- [ ] **Step 2: Add `removed` blocks to the AWS network stack**

Delete the three `resource` blocks from `opentofu/aws/network/tailscale.tf` and add:

```hcl
# The three tailnet-wide singletons moved to opentofu/shared/tailscale.
#
# `destroy = false` means FORGET, not delete: OpenTofu drops them from this
# stack's state without calling the Tailscale API at all. That is what makes
# this safe on a tailnet that is the only route to the private EKS endpoint.
#
# Two facts verified in the provider source before writing this:
#   - reset_acl_on_destroy is Optional and was never set here, so even a real
#     destroy would not reset the tailnet policy
#   - overwrite_existing_content = true, which the provider documents as
#     "skip requirement to import acl before allowing changes"
#
# These blocks can be deleted once the migration has been applied and the plan
# is clean, but leaving them costs nothing and documents where the resources went.
removed {
  from = tailscale_acl.this
  lifecycle { destroy = false }
}

removed {
  from = tailscale_dns_nameservers.this
  lifecycle { destroy = false }
}

removed {
  from = tailscale_dns_search_paths.this
  lifecycle { destroy = false }
}
```

Leave `tailscale_dns_split_nameservers.private`, `.ec2`, `tailscale_tailnet_key.this` and the router module exactly as they are.

- [ ] **Step 3: Add matching `import` blocks**

Substituting the UUIDs from Step 1:

```hcl
# Adoption of the three singletons from opentofu/aws/network.
#
# The import blocks are not strictly required -- overwrite_existing_content
# lets this stack create the ACL over the existing one -- but they make the
# plan read "0 to change" instead of "1 to add". On a resource that gates access
# to every private endpoint, a visibly inert plan is worth the extra block.
#
# The IDs are provider-generated UUIDs (resource_acl.go: createUUID()), read
# from the AWS stack's state. They are NOT stable well-known strings; do not
# copy these into another environment.
import {
  to = tailscale_acl.this
  id = "<uuid-from-step-1>"
}

import {
  to = tailscale_dns_nameservers.this
  id = "<uuid-from-step-1>"
}

import {
  to = tailscale_dns_search_paths.this
  id = "<uuid-from-step-1>"
}
```

- [ ] **Step 4: Plan the shared stack and check it is inert**

Run:
```bash
cd opentofu/shared/tailscale
tofu init -lock-timeout=5m
tofu plan -var-file=variables.tfvars -out=/tmp/tailscale.tfplan
cd -
```
Expected: `3 to import, 0 to add, 0 to change, 0 to destroy` — **except** `tailscale_dns_search_paths`, which legitimately shows a change because it gains `priv.gcp.cloud.ogenki.io`. The ACL must show **no change to content**.

**If the ACL shows a diff**, stop and compare it against the original `jsonencode` body. A reordered `acls` list is a real diff to the API and must be reconciled before applying.

- [ ] **Step 5: Plan the AWS network stack and check nothing is destroyed**

Run:
```bash
cd opentofu/aws/network && tofu plan -var-file=variables.tfvars; cd -
```
Expected: `3 to forget, 0 to add, 0 to change, 0 to destroy`. **Any destroy is a stop condition.**

- [ ] **Step 6: Point both network stacks at the shared stack**

Add to `opentofu/aws/network/stack.tm.hcl` and `opentofu/gcp/network/stack.tm.hcl`:

```hcl
  after = [
    "/opentofu/shared/tailscale"
  ]
```
(For `aws/network`, which has no `after` today, this creates the block; for `gcp/network` likewise.)

Then run `terramate list --run-order` and confirm `opentofu/shared/tailscale` sorts before both.

- [ ] **Step 7: Remove the now-redundant `gcp_routes` plumbing**

Task-8-era commit `0451eedb` added `gcp_routes` to the AWS network stack as the interim fix. The shared stack supersedes it. Delete `variable "gcp_routes"` from `opentofu/aws/network/variables.tf` and the two ACL usages — they are inside the resource blocks removed in Step 2, so verify none remain:

```bash
grep -rn "gcp_routes" opentofu/
```
Expected: no output.

- [ ] **Step 8: Commit**

```bash
git add opentofu/aws/network opentofu/gcp/network/stack.tm.hcl opentofu/shared/tailscale
git commit -m "refactor(tailscale): migrate the tailnet singletons to shared/tailscale

removed { destroy = false } forgets them from the AWS network stack
without calling the Tailscale API; matching import blocks adopt them into
shared/tailscale so the plan reads '0 to change' rather than '1 to add'
on a resource that gates access to every private endpoint.

The IDs are provider-generated UUIDs read from live state, not guessed --
resource_acl.go sets them with createUUID().

Supersedes the interim gcp_routes variable from 0451eedb: GCP's routes are
now authorised by a stack neither cloud owns, rather than from AWS.

Both network stacks now run after shared/tailscale, so a registering
router finds its routes already auto-approved."
```

---

## Phase 4 — Converge Gateway API

> **Live-state migration.** A destroyed CRD deletes every custom resource of that kind — on this cluster, both Tailscale Gateways and every `App` claim that owns an HTTPRoute.

### Task 8: Build the shared CRD module and adopt it on GCP first

GCP goes first because it is greenfield: if the module is wrong, nothing live breaks.

**Files:**
- Create: `opentofu/shared/modules/gateway-api-crds/{main,variables,versions,outputs}.tf`
- Modify: `opentofu/gcp/gke/configure/{gateway_api.tf,data.tf,main.tf}`

- [ ] **Step 1: Write the module**

```bash
mkdir -p opentofu/shared/modules/gateway-api-crds
```

`versions.tf`:
```hcl
terraform {
  required_version = "~> 1.5"

  required_providers {
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
    http = {
      source  = "hashicorp/http"
      version = ">= 3.4"
    }
  }
}
```

`variables.tf`:
```hcl
variable "gateway_api_version" {
  description = "Gateway API release tag. MUST equal flux/sources/gitrepo-gateway-api.yaml's ref.tag so both clouds run one Gateway API surface"
  type        = string

  validation {
    condition     = can(regex("^v[0-9]+\\.[0-9]+\\.[0-9]+$", var.gateway_api_version))
    error_message = "Gateway API version must be a full release tag, e.g. v1.6.1."
  }
}
```

`main.tf`:
```hcl
# The Gateway API CRDs, applied identically on every cloud.
#
# This module exists because the two clouds previously applied these CRDs two
# different ways, which meant fixing a Gateway API problem in one directory did
# not fix it in the other. Unlike the Cilium values -- which are deliberately
# forked per cloud so divergence stays visible -- there is no intended
# divergence here: same version, same channel, same bundle.
#
# THE WHOLE BUNDLE, NOT AN ENUMERATION. cilium-operator probes for these CRDs
# exactly once at startup and permanently disables its Gateway API controller if
# any is absent -- no crash, no alert, and only the leader replica logs it. On
# 2026-08-19 that fired over a two-second gap because the hand-written list had
# ten entries and Cilium 1.20 also wants BackendTLSPolicy. A bundle cannot drift
# from what Cilium expects; a list can, and did.
#
# Experimental channel, matching what the cluster already runs, so a route using
# an experimental field cannot work on one cloud and fail on the other.
data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/experimental-install.yaml"
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}

# for_each keyed by manifest self-link, NOT count: a future release that adds a
# CRD appends a key instead of shifting every index. A count-indexed list makes
# OpenTofu destroy and recreate live CRDs on any reordering, taking every
# Gateway and HTTPRoute with them.
resource "kubectl_manifest" "this" {
  for_each  = data.kubectl_file_documents.gateway_api_crds.manifests
  yaml_body = each.value

  # server_side_apply is REQUIRED, not preferred: client-side apply writes a
  # last-applied-configuration annotation and the httproutes CRD exceeds the
  # 262144-byte limit. Confirmed on the GCP gate cluster.
  #
  # force_conflicts because Flux also reconciles these from the gateway-api
  # GitRepository; whoever applies second must not fight the first.
  server_side_apply = true
  force_conflicts   = true
  wait              = true
}
```

`outputs.tf`:
```hcl
output "manifest_keys" {
  description = "Self-link keys of every applied manifest. Printed so the AWS moved blocks can be written from real output rather than constructed by hand"
  value       = keys(data.kubectl_file_documents.gateway_api_crds.manifests)
}
```

- [ ] **Step 2: Point the GCP configure stack at the module**

Replace the body of `opentofu/gcp/gke/configure/gateway_api.tf` with:

```hcl
module "gateway_api_crds" {
  source = "../../../shared/modules/gateway-api-crds"

  gateway_api_version = var.gateway_api_version
}
```

Delete the `data "http" "gateway_api_crds"` and `data "kubectl_file_documents" "gateway_api_crds"` blocks from `opentofu/gcp/gke/configure/data.tf` — they live in the module now.

Update the Cilium dependency in `opentofu/gcp/gke/configure/main.tf`:

```hcl
  depends_on = [
    module.gateway_api_crds, # Gateway API CRDs must exist before Cilium starts
  ]
```

- [ ] **Step 3: Validate GCP**

Run:
```bash
tofu -chdir=opentofu/gcp/gke/configure init -backend=false
tofu -chdir=opentofu/gcp/gke/configure validate
tofu fmt -check -recursive opentofu/
```
Expected: `Success!` and fmt exit 0.

- [ ] **Step 4: Commit**

```bash
git add opentofu/shared/modules opentofu/gcp/gke/configure
git commit -m "feat(gateway-api): add the shared CRD module, adopt it on GCP

One module both clouds call, so a Gateway API fix lands on both at once.
Applies the whole release bundle for_each-keyed by manifest self-link --
never an enumerated list, which is what silently lost BackendTLSPolicy and
disabled Gateway API on 2026-08-19.

GCP adopts it first because it is greenfield: if the module is wrong,
nothing live breaks."
```

### Task 9: Re-key AWS onto the module with `moved` blocks

> **Requires AWS credentials.** This is the step that can destroy live CRDs.

**Files:**
- Modify: `opentofu/aws/eks/configure/{kubernetes.tf,locals.tf,data.tf,main.tf}`
- Create: `opentofu/aws/eks/configure/moved.tf`

- [ ] **Step 1: Print the module's real manifest keys**

Do not hand-write these.

```bash
cd opentofu/gcp/gke/configure
tofu init -backend=false >/dev/null
tofu console <<'EOF'
module.gateway_api_crds.manifest_keys
EOF
cd -
```

If `tofu console` cannot evaluate a module output without state, use the equivalent standalone evaluation:

```bash
cd /tmp && mkdir -p gwkeys && cd gwkeys
cat > main.tf <<'EOF'
terraform {
  required_providers {
    kubectl = { source = "gavinbunney/kubectl", version = "~> 1.14" }
    http    = { source = "hashicorp/http", version = ">= 3.4" }
  }
}
data "http" "b" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.1/experimental-install.yaml"
}
data "kubectl_file_documents" "d" { content = data.http.b.response_body }
output "keys" { value = keys(data.kubectl_file_documents.d.manifests) }
EOF
tofu init >/dev/null && tofu apply -auto-approve >/dev/null && tofu output -json keys
cd -
```
Expected: a JSON array of self-link strings. **Record it.**

- [ ] **Step 2: Map each existing index to its new key**

Run:
```bash
cd opentofu/aws/eks/configure && tofu init -lock-timeout=5m >/dev/null
tofu state list | grep gateway_api_crds
cd -
```
Expected: ten addresses, `kubectl_manifest.gateway_api_crds[0]` … `[9]`, in the order of `local.gateway_api_crds_urls`: gatewayclasses, gateways, httproutes, referencegrants, tcproutes, tlsroutes, udproutes, grpcroutes, backendtlspolicies, listenersets.

Pair each index with the Step 1 key whose self-link ends in that CRD name.

- [ ] **Step 3: Write `moved.tf`**

One block per index, substituting the real keys:

```hcl
# Re-key the Gateway API CRDs from this stack's count-indexed list onto the
# shared module's for_each map.
#
# WITHOUT these blocks OpenTofu reads the change as "destroy ten CRDs, create
# fourteen" -- and destroying a CRD deletes every custom resource of that kind.
# On this cluster that is both Tailscale Gateways and every App claim that owns
# an HTTPRoute.
#
# Keys are the manifest self-links printed by the module, not hand-written. A
# typo here does not fail loudly: it silently leaves one CRD un-moved, which
# then shows up as a destroy in the plan. That is why the plan gate in Step 5
# is "0 to destroy", not "looks reasonable".
moved {
  from = kubectl_manifest.gateway_api_crds[0]
  to   = module.gateway_api_crds.kubectl_manifest.this["<self-link-for-gatewayclasses>"]
}
# ... one block per index 0-9, in the same order as local.gateway_api_crds_urls
```

- [ ] **Step 4: Swap the resource for the module**

Delete `resource "kubectl_manifest" "gateway_api_crds"` from `opentofu/aws/eks/configure/kubernetes.tf`, `local.gateway_api_crds_urls` from `locals.tf`, and `data "http" "gateway_api_crds"` from `data.tf`. Add to `kubernetes.tf`:

```hcl
module "gateway_api_crds" {
  source = "../../../shared/modules/gateway-api-crds"

  gateway_api_version = var.gateway_api_version
}
```

Update the Cilium `depends_on` in `main.tf` from `kubectl_manifest.gateway_api_crds` to `module.gateway_api_crds`.

- [ ] **Step 5: THE GATE — plan and require zero destroys**

Run:
```bash
cd opentofu/aws/eks/configure
tofu init -lock-timeout=5m
tofu plan -var-file=variables.tfvars -var="cilium_version=1.20.0" | tee /tmp/gwplan.txt
grep -E "^Plan:|will be destroyed|has moved to" /tmp/gwplan.txt
cd -
```
Expected: ten `has moved to` lines, additions for the bundle-only resources (the `ValidatingAdmissionPolicy` and the `gateway.networking.x-k8s.io` CRDs), and `0 to destroy`.

**STOP CONDITION: if the plan destroys anything, do not apply.** Re-check the key mapping from Step 2 — a mismatched key is the cause, and it is recoverable at plan time and catastrophic after apply.

- [ ] **Step 6: Commit**

```bash
git add opentofu/aws/eks/configure
git commit -m "refactor(gateway-api): re-key AWS onto the shared CRD module

Moves from a count-indexed list of ten enumerated CRD URLs to the shared
module's for_each map, via moved blocks so no live CRD is destroyed --
destroying one deletes every custom resource of that kind, which here means
both Tailscale Gateways and every App claim owning an HTTPRoute.

Keys come from the module's manifest_keys output, not hand-written.

Both clouds now apply the whole release bundle through one module, so the
class of failure that hit on 2026-08-19 -- a CRD Cilium starts requiring
going silently missing from a hand-maintained list -- is closed on both."
```

---

## Phase 5 — Acceptance

### Task 10: Verify every success criterion and hand off

**Files:** none (verification), plus `CLAUDE.md` and `.claude/rules/opentofu.md`

- [ ] **Step 1: Layout criteria 1–4**

```bash
terramate list
terramate list --run-order
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
grep -rn '\.\./\.\./\.\./scripts' opentofu/ --include=*.hcl
```
Expected: ten stacks under `opentofu/{aws,gcp,shared}/`, `shared/tailscale` before both networks, both gates exit 0, and no output from the grep.

- [ ] **Step 2: Reverse order**

Run: `terramate list --run-order --reverse`
Expected: the exact inverse. This is what `destroy` sweeps — a wrong `after` destroys a dependency first.

- [ ] **Step 3: State-neutrality criteria 5–7 (requires AWS credentials)**

Run: `terramate script run --tags=aws preview 2>&1 | tee /tmp/aws-preview.txt`
Expected: across every AWS stack, `0 to destroy`. The only non-zero counts are the ten Gateway API moves, the three tailnet forgets, and the bundle-only CRD additions.

Then: `grep -cE "will be destroyed" /tmp/aws-preview.txt`
Expected: `0`.

- [ ] **Step 4: Gating criteria 8–10**

```bash
terramate script run --tags=gcp deploy 2>&1 | grep -c "^\[skip\]"
terramate list --no-tags=opt-in
TM_GCP_ENABLED=true terramate -C opentofu/gcp/gke/init script list | head -5
```
Expected: `3` skips; the second lists only AWS stacks plus `shared/tailscale`; the third lists the GCP scripts.

- [ ] **Step 5: Gate criterion 14**

```bash
tofu fmt -check -recursive opentofu/
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml --skip-dirs "**/.terraform" .
./scripts/validate-manifests.sh
pre-commit run --all-files
```
Expected: all exit 0, and the manifest report shows `Invalid: 0, Skipped: 0`.

- [ ] **Step 6: Document the scoped entrypoints**

Add to `CLAUDE.md` under *Common Commands* and to `.claude/rules/opentofu.md`:

````markdown
```bash
# opentofu/ is cloud-partitioned: aws/, gcp/, shared/. Scope runs by tag.
terramate script run --tags=aws deploy      # AWS only
terramate script run --no-tags=opt-in deploy # everything not gated
TM_GCP_ENABLED=true terramate script run --tags=gcp deploy  # GCP (gated)
```

> The GCP stacks are tagged `opt-in` and guarded by `$TM_GCP_ENABLED` until GCP
> works end to end. A bare `terramate script run deploy` reaches them and they
> no-op with `[skip]`. **Remove both the tag and the guards** when the gate comes
> off — a gate left on is indistinguishable from success.
````

- [ ] **Step 7: Commit and hand off**

```bash
git add -A
git commit -m "docs(opentofu): document the cloud-scoped Terramate entrypoints

opentofu/ is now partitioned aws/ gcp/ shared/, and both clouds share one
run order, so the bare root command is no longer the entrypoint. Records
the tag-scoped forms and the removal condition for the GCP gate."
```

Then resume **Phases 5–6 of the [GCP foundation plan](2026-08-18-gcp-foundation.md)** — `clusters/gcp-mycluster-0/` and the GCP apply — whose paths this refactor has now settled.

---

## Self-review

**Spec coverage.** Design criteria 1–4 map to Task 10 Step 1–2; 5–7 to Task 10 Step 3 (with the per-migration gates in Tasks 7 and 9); 8–10 to Task 10 Step 4; 14 to Task 10 Step 5. Criteria 11–13 (GCP applied end-to-end, private domain resolves, clean teardown) are **deliberately out of scope** — they belong to the GCP foundation plan's Phases 5–6, per this plan's Scope note, and are the bar for the final gate-removal PR rather than for this refactor. The design's three named problems each have a task: the tailnet singleton (6–7), Gateway API divergence (8–9), ungated run order (2). Both design open questions are resolved: the `tailscale_acl` import ID is read from state in Task 7 Step 1, and `shared/tailscale` gets no gate of its own — its first apply is Task 7 Step 4, an explicit reviewed plan, not part of a sweep.

**Placeholders.** Four `<...>` substitutions remain by design, each with a step that produces the value: the `shared/tailscale` stack UUID (Task 6 Step 5 generates it), the three tailnet import IDs (Task 7 Step 1 reads them from state), and the ten Gateway API self-link keys (Task 9 Step 1 prints them). Each is accompanied by an explicit instruction not to guess, because all four are values that fail silently when wrong. No "TBD", no "add error handling", no "similar to Task N".

**Consistency.** Verified across tasks: `opentofu/aws/` prefix used uniformly after Task 4; module source paths are `../../../shared/modules/gateway-api-crds` from both `configure` stacks (both three levels deep — `aws/eks/configure` and `gcp/gke/configure`); `module.gateway_api_crds` is the call name in both clouds so the `depends_on` and `moved` targets match; `advertised_routes` is the variable name in both `shared/tailscale` and the GCP network stack's output; `$TM_GCP_ENABLED` spelled identically in all five script files and both doc updates.

**Known risk carried deliberately:** Task 9 is the only step that can destroy live infrastructure, and its stop condition is stated twice — in the step and in the `moved.tf` comment — because a mismatched key produces a plan that looks plausible.
