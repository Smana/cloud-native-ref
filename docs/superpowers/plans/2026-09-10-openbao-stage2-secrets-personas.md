# OpenBao Stage 2 — Secrets Store and Personas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make OpenBao the store of record for platform and application secrets — two root-namespace kv-v2 mounts, per-app human ownership through ZITADEL groups, a read-only External Secrets identity, and a non-destructive migration off AWS/GCP Secrets Manager.

**Architecture:** Two kv-v2 mounts (`platform/`, `apps/`) in OpenBao's **root** namespace, where the `oidc/` auth mount and every existing policy already live. Human authorisation is per-app: one OpenBao policy and one external identity group generated per app by `for_each`, matched on the OIDC `groups` claim. External Secrets keeps its existing `jwt/<cluster>` role and gains a read-only policy, so machines read and only humans write. Migration copies managed store → OpenBao without overwriting or deleting, and `ExternalSecret` documents are repointed one at a time.

**Tech Stack:** OpenTofu ≥ 1.8 with `hashicorp/vault ~> 5`; OpenBao 2.6.2 (kv-v2, JWT and OIDC auth, identity groups); External Secrets Operator (`vault` provider); ZITADEL (project roles → `groups` claim via the `groupsFromRoles` Action); Flux; bash under `scripts/`.

**Spec:** [`docs/superpowers/specs/2026-09-10-openbao-stage2-secrets-personas-design.md`](../specs/2026-09-10-openbao-stage2-secrets-personas-design.md). Read its "Target" and "Risks" sections before starting. Its parent, [`2026-09-02-openbao-store-of-record-design.md`](../specs/2026-09-02-openbao-store-of-record-design.md), defines the tiers and the bootstrap set.

## Status

| Phase | Tasks | State |
|---|---|---|
| 1 — Foundation | 1-4 | **Done**, applied and verified against the live `aws-0` OpenBao |
| 2 — Tooling | 5-6 | **Done**, dry-run verified; nothing written to any store |
| 3 — Repoint | 7-11 | **Not started.** First task that changes cluster behaviour |
| 4 — Records and cleanup | 12-13 | **Not started** |

Phases 1 and 2 are deliberately separable: they create mounts, policies and
groups that nothing consumes yet, plus a tooling change whose only new command
is dry-run by default. Merging them keeps `main` in step with the cluster —
after Phase 1 was applied from this branch, a `terramate script run deploy` from
`main` planned **10 destroys**, because the mounts and policies existed only
here.

Six defects in this plan were found by executing it. Each is recorded inline at
the step it affects, marked **Found during execution**.

## Global Constraints

- **Worktree.** Work in `.claude/worktrees/openbao-stage2-personas`, branch `worktree-openbao-stage2-personas`. Never commit on `main`.
- **Never add a `Co-Authored-By` trailer, and never add "Generated with Claude Code" to a PR** (user rule).
- **Commit with an explicit pathspec** — `git commit -F <msgfile> -- <paths>`. A bare `git commit` commits the whole index, so anything else staged rides along. Write the message to a **file**: a backtick in a `-m "..."` string is command substitution.
- **Mounts live in the ROOT namespace.** A policy binds only within the namespace it is created in. Do not create these mounts in the `app` namespace — that is the mistake this design exists to correct.
- **`destroy` is never granted to a per-app policy.** A compromised credential must not erase secret history.
- **External Secrets is read-only on both mounts.** No task grants it `create`, `update`, `patch` or `delete`.
- **Migration never overwrites and never deletes the source.** Old entries are removed by hand, in Task 13 only.
- **The bootstrap tier stays in the managed store**: `certificates/priv.aws.ogenki.io/ca-chain`, the OpenBao server TLS cert/key, root token, recovery keys, intermediate CA bundle. The `openbao-ca` ExternalSecret keeps reading AWS — the OpenBao-backed store depends on the CA Secret it produces, so repointing it would be circular.
- **`kubernetesServiceAccountToken` trips detect-secrets.** Append ` # pragma: allowlist secret` on that line.
- **A NEW file must be staged before a pathspec commit.** `git commit -- <path>` only considers *tracked* paths, so a newly created policy or manifest is silently skipped and the commit succeeds without it. Stage it first. Applies to Tasks 2, 3, 4 and 7.
- **There is exactly ONE OpenBao, and it is on AWS.** ADR-0027 classes it a primary-cloud singleton. The mounts, policies and identity groups are created **only** by `opentofu/aws/openbao/management` — do not mirror them into `opentofu/gcp/openbao/management`, which would create a second, divergent store. What GCP needs is parity on the *consumer* side only: its `external-secrets` JWT role gains the same policy name (Task 4), and its `ClusterSecretStore` objects are the same manifests with `${cluster_name}` resolving to `gcp-0` (Task 7).
- **`gcp-0` is not running today.** Its `[LIVE]` verification steps cannot be executed in this pass. Make the manifest and HCL changes, let CI validate them, and record in the PR that GCP's live verification is outstanding — do not claim it passed.
- **Validators** (from the repo root, exit 0 expected):
  - `./scripts/validate-manifests.sh` — after any change under `security/`, `clusters/`. Report must end `Invalid: 0, Skipped: 0`.
  - `python3 scripts/flux-schema/check-substitution.py` — after any `${var}` change in a manifest.
  - `./scripts/validate-links.sh` and `./scripts/validate-doc-claims.sh` — after any doc change.
  - `tofu fmt -recursive opentofu/` then `cd opentofu/aws/openbao/management && tofu init -backend=false && tofu validate` — after any HCL change.
  - `shellcheck -x -S warning scripts/secret-store.sh` — after script changes (CI's exact flags).
- **Live values** (do not invent alternatives):

  | Thing | Value |
  |---|---|
  | OpenBao address | `https://bao.priv.aws.ogenki.io:8200` (in-cluster: `openbao.security.svc.cluster.local:8200`) |
  | CA for the `vault` provider | Secret `openbao-ca` in namespace `security`, key `ca.crt` |
  | JWT mount / role / audience | `jwt/aws-0` (and `jwt/gcp-0`) / `external-secrets` / `openbao` |
  | ESO ServiceAccount | `external-secrets` in namespace `security` |
  | Existing OIDC group | `openbao-admin`, alias `admin`, policies `admin` + `pki-admin` |
  | Apps holding secrets today | `app-wizard`, `image-gallery` |

---

## Phase 1 — Foundation (OpenTofu only; nothing in the cluster changes)

### Task 1: The two kv-v2 mounts

**Files:**
- Modify: `opentofu/aws/openbao/management/mounts.tf`

**Interfaces:**
- Produces: `vault_mount.platform` (path `platform`) and `vault_mount.apps` (path `apps`), both kv-v2 in the root namespace. Later tasks reference `vault_mount.platform.path` and `vault_mount.apps.path`.

- [ ] **Step 1: Read the existing mount to copy its idiom**

Run: `sed -n '1,30p' opentofu/aws/openbao/management/mounts.tf`

Note how `vault_mount.app_secret` and `vault_mount.lineage` are written. Both use `type = "kv-v2"` — the provider's shorthand — **not** `type = "kv"` with `options = { version = "2" }`. `vault_mount.lineage` is also proof that a root-namespace kv-v2 mount already works here. The new mounts differ from `app_secret` in exactly one way: **no `namespace` argument**, which puts them in root.

> **Found during execution (2026-09-10):** this step's code block originally showed `type = "kv"` plus `options`, contradicting the instruction to copy the idiom. Corrected to `kv-v2`; both mounts verified as `version = 2` after apply.

- [ ] **Step 2: Append the two mounts**

```hcl
# Store of record for platform component secrets (Stage 2 of ADR-0033).
#
# Root namespace, deliberately. A policy binds only within the namespace it is
# created in, and the `oidc/` mount, the identity groups and every policy this
# platform has are in root. A mount in a child namespace cannot be reached by
# any of them -- which is exactly why the pre-existing `app` namespace mount was
# never usable by a human and never consumed by anything.
#
# Grammar: platform/<component>/<name>, one-to-one onto ADR-0023's dash names.
# `harbor-admin-password` becomes `platform/harbor/admin-password`.
resource "vault_mount" "platform" {
  path        = "platform"
  type        = "kv-v2"
  description = "Platform component secrets; store of record (ADR-0033 Stage 2)"
}

# Store of record for application secrets, owned per app.
#
# Separate from `platform/` because External Secrets' vault provider takes ONE
# mount per store (spec.provider.vault.path), so the split is what lets the two
# audiences carry different policies without prefix gymnastics inside a single
# policy document.
#
# Grammar: apps/<app>/<key>.
resource "vault_mount" "apps" {
  path        = "apps"
  type        = "kv-v2"
  description = "Application secrets, owned per app (ADR-0036)"
}
```

- [ ] **Step 3: Validate the HCL**

Run: `tofu fmt -recursive opentofu/ && cd opentofu/aws/openbao/management && tofu init -backend=false && tofu validate`

Expected: `Success! The configuration is valid.`

- [ ] **Step 4: Plan against the live cluster [LIVE]**

Run from `opentofu/aws/openbao/management`, with `AWS_REGION=eu-west-3` and a tailnet connection:

```bash
tofu init -input=false && tofu plan -lock=false -var-file=variables.tfvars
```

Expected: `Plan: 2 to add, 0 to change, 0 to destroy.` — exactly `vault_mount.platform` and `vault_mount.apps`. If anything else appears, stop and report; the stack should otherwise be converged.

- [ ] **Step 5: Apply [LIVE]**

Run: `tofu apply -auto-approve -var-file=variables.tfvars`

Expected: `Apply complete! Resources: 2 added, 0 changed, 0 destroyed.`

- [ ] **Step 6: Verify both mounts exist and are v2 [LIVE]**

```bash
bao secrets list -format=json | jq -r 'to_entries[] | select(.key|test("^(platform|apps)/")) | "\(.key) \(.value.type) v\(.value.options.version)"'
```

Expected two lines: `platform/ kv v2` and `apps/ kv v2`.

- [ ] **Step 7: Commit**

Write the message to `/tmp/msg`:

```
feat(openbao): add the platform/ and apps/ kv-v2 mounts

Root namespace, where the oidc mount and every policy already live. A mount in
a child namespace cannot be reached by any of them, which is why the
pre-existing app namespace mount was never usable by a human.
```

Then: `git commit -F /tmp/msg -- opentofu/aws/openbao/management/mounts.tf`

---

### Task 2: The `secrets-admin` policy, and attaching it to the admin group

**Files:**
- Create: `opentofu/aws/openbao/management/policies/secrets-admin.hcl`
- Modify: `opentofu/aws/openbao/management/policies.tf`
- Modify: `opentofu/aws/openbao/management/oidc.tf` (the `vault_identity_group.oidc_admin` `policies` list)

**Interfaces:**
- Consumes: `vault_mount.platform`, `vault_mount.apps` from Task 1.
- Produces: `vault_policy.secrets_admin` (name `secrets-admin`).

- [ ] **Step 1: Write the policy document**

Create `opentofu/aws/openbao/management/policies/secrets-admin.hcl`:

```hcl
# Full control of both secret mounts, for platform administrators.
#
# kv-v2 splits one logical mount across several API paths: values under `data/`,
# version history and soft-deletes under `metadata/`, `delete/`, `undelete/` and
# `destroy/`. A grant on `platform/*` alone is the classic kv-v2 mistake -- it
# reads correctly and matches nothing a client actually calls, because the
# client asks for `platform/data/<path>`.
#
# Unlike the per-app policies, this one DOES carry `destroy`: erasing a secret's
# history is an administrative act, and someone has to be able to do it.

path "platform/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "platform/metadata/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}

path "platform/delete/*" {
  capabilities = ["update"]
}

path "platform/undelete/*" {
  capabilities = ["update"]
}

path "platform/destroy/*" {
  capabilities = ["update"]
}

path "platform/config" {
  capabilities = ["read", "update"]
}

path "apps/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "apps/metadata/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}

path "apps/delete/*" {
  capabilities = ["update"]
}

path "apps/undelete/*" {
  capabilities = ["update"]
}

path "apps/destroy/*" {
  capabilities = ["update"]
}

path "apps/config" {
  capabilities = ["read", "update"]
}

# Listing the mounts themselves, so the UI can render the secrets tree.
path "sys/mounts" {
  capabilities = ["read"]
}
```

- [ ] **Step 2: Register the policy**

Append to `opentofu/aws/openbao/management/policies.tf`:

```hcl
# Full control of the two Stage 2 secret mounts. Held by the OIDC admin group
# alongside `admin` and `pki-admin`; see oidc.tf.
resource "vault_policy" "secrets_admin" {
  name   = "secrets-admin"
  policy = file("policies/secrets-admin.hcl")
}
```

- [ ] **Step 3: Attach it to the admin identity group**

In `opentofu/aws/openbao/management/oidc.tf`, change the `policies` line of `vault_identity_group.oidc_admin` from:

```hcl
  policies = [vault_policy.admin.name, vault_policy.pki_admin.name]
```

to:

```hcl
  policies = [vault_policy.admin.name, vault_policy.pki_admin.name, vault_policy.secrets_admin.name]
```

- [ ] **Step 4: Validate**

Run: `tofu fmt -recursive opentofu/ && cd opentofu/aws/openbao/management && tofu validate`

Expected: `Success! The configuration is valid.`

- [ ] **Step 5: Apply [LIVE]**

Run: `tofu apply -auto-approve -var-file=variables.tfvars`

Expected: `Apply complete! Resources: 1 added, 1 changed, 0 destroyed.` (policy added, group changed).

- [ ] **Step 6: Verify the grant resolves [LIVE]**

```bash
bao policy read secrets-admin | head -5
bao read -field=policies identity/group/name/openbao-admin
```

Expected: the policy prints, and the group's policies include `secrets-admin`.

- [ ] **Step 7: Commit**

Message:

```
feat(openbao): grant platform admins the two secret mounts

The admin policy deliberately carries no secret grant and could not reach one
anyway from root. secrets-admin covers both Stage 2 mounts, including every
kv-v2 sub-path a client actually calls.
```

Then: `git commit -F /tmp/msg -- opentofu/aws/openbao/management/policies/secrets-admin.hcl opentofu/aws/openbao/management/policies.tf opentofu/aws/openbao/management/oidc.tf`

---

### Task 3: Per-app policies and groups, generated with `for_each`

**Files:**
- Create: `opentofu/aws/openbao/management/apps.tf`
- Create: `opentofu/aws/openbao/management/policies/app-prefix.hcl`
- Modify: `opentofu/aws/openbao/management/variables.tf`
- Modify: `opentofu/aws/openbao/management/variables.tfvars`

**Interfaces:**
- Consumes: `vault_mount.apps` (Task 1), `vault_jwt_auth_backend.oidc[0].accessor` (existing, `oidc.tf`), `local.oidc_enabled` (existing).
- Produces: `vault_policy.app_prefix["<name>"]`, `vault_identity_group.app["<name>"]`, `vault_identity_group_alias.app["<name>"]` for each entry of `var.secret_owning_apps`.

> **Found during execution (2026-09-10), two defects in this task's original code:**
> 1. It used `resource "vault_policy" "app"`, which **collides** with the existing app-namespace tenant policy in `policies.tf`. Renamed to `app_prefix`.
> 2. `for_each = local.secret_owning_apps` failed with `Invalid for_each argument: local.secret_owning_apps has a sensitive value`, because `local.oidc_enabled` derives from the OIDC secret's payload. Fixed with the `oidc_on` local shown below.

- [ ] **Step 1: Declare the variable**

Append to `opentofu/aws/openbao/management/variables.tf`:

```hcl
# Apps that own a prefix under the `apps/` mount. One OpenBao policy, one
# external identity group and one alias are generated per entry.
#
# Generated per app rather than templated with {{identity.groups.names.*}} on
# purpose: templating collapses N policies into one, but the grant stops being
# visible -- it cannot be read off a plan diff, and one mistake in the template
# widens every app's reach at once. The cost is that onboarding an app touches
# Terraform, which is accepted (ADR-0036).
#
# An entry is only useful once a matching ZITADEL project role `app-<name>`
# exists and a human has been granted it; see scripts/zitadel-oidc-clients.sh.
variable "secret_owning_apps" {
  description = "Apps that own a prefix under the apps/ kv-v2 mount. Each gets a policy, an external identity group and an alias matched on the OIDC groups claim."
  type        = set(string)
  default     = []
}
```

- [ ] **Step 2: Set the day-one list**

Append to `opentofu/aws/openbao/management/variables.tfvars`:

```hcl
# Only apps that actually hold secrets today. `secret-store.sh check --cloud aws`
# resolves app-wizard to two keys (llm, oauth) and image-gallery to one (config);
# the other App claims consume none, so they get no group and no prefix.
secret_owning_apps = ["app-wizard", "image-gallery"]
```

- [ ] **Step 3: Write the generator**

Create `opentofu/aws/openbao/management/apps.tf`:

```hcl
# Per-app ownership of the `apps/` mount (ADR-0036).
#
# Everything here is gated on `local.oidc_enabled` for the same reason oidc.tf
# is: without the OIDC mount there is no accessor to alias against, and a
# cluster whose ZITADEL is not bootstrapped yet must still converge.
#
# The alias name is what must appear in the token's `groups` array, exactly.
# That claim only arrives when three things hold -- ZITADEL projectRoleAssertion
# true, the groupsFromRoles Action present, and the OIDC role requesting the
# `groups` scope. A group that appears to grant nothing should be diagnosed
# against those three before anything here is suspected.

locals {
  # `local.oidc_enabled` is computed from the OIDC secret's PAYLOAD, so OpenTofu
  # marks it sensitive -- and a sensitive value cannot be a for_each argument,
  # because instance keys become part of a resource address and would leak.
  #
  # The keys below come from a plain tfvars list, never from the secret, so it
  # is only the GATE that has to be unwrapped. try() covers the other case:
  # when the secret is absent, oidc_enabled was never sensitive to begin with,
  # and nonsensitive() errors on a value that is not sensitive.
  oidc_on = try(nonsensitive(local.oidc_enabled), local.oidc_enabled)

  # Empty when OIDC is off, so no policy or group is generated at all.
  secret_owning_apps = local.oidc_on == 1 ? var.secret_owning_apps : toset([])
}

# NOT `vault_policy.app` -- that name is already taken by the app-namespace
# tenant policy in policies.tf.
resource "vault_policy" "app_prefix" {
  for_each = local.secret_owning_apps

  name = "app-${each.value}"
  policy = templatefile("policies/app-prefix.hcl", {
    mount = vault_mount.apps.path
    app   = each.value
  })
}

resource "vault_identity_group" "app" {
  for_each = local.secret_owning_apps

  name     = "openbao-app-${each.value}"
  type     = "external"
  policies = [vault_policy.app_prefix[each.value].name]
}

resource "vault_identity_group_alias" "app" {
  for_each = local.secret_owning_apps

  # Must equal the ZITADEL project role name as it lands in the groups claim.
  name           = "app-${each.value}"
  mount_accessor = vault_jwt_auth_backend.oidc[0].accessor
  canonical_id   = vault_identity_group.app[each.value].id
}
```

- [ ] **Step 4: Write the templated policy document**

Create `opentofu/aws/openbao/management/policies/app-prefix.hcl`:

```hcl
# One app's own prefix under the apps/ mount. Rendered per app by apps.tf.
#
# kv-v2 splits the mount across several API paths; a grant on the bare app path
# alone matches nothing a client calls, because the client asks for
# `<mount>/data/<app>/<key>`.
#
# `destroy` is deliberately absent: a compromised credential must not be able to
# erase secret history. Soft-delete and undelete are enough for day-to-day work,
# and permanent destruction is an administrative act (see secrets-admin.hcl).

path "${mount}/data/${app}/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "${mount}/metadata/${app}/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}

path "${mount}/delete/${app}/*" {
  capabilities = ["update"]
}

path "${mount}/undelete/${app}/*" {
  capabilities = ["update"]
}

# Listing the mount root, so the UI can show this app's folder. kv-v2 metadata
# listing at the top level is what renders the tree; without it the app's own
# prefix is reachable only by typing its full path.
path "${mount}/metadata" {
  capabilities = ["list"]
}

path "sys/mounts" {
  capabilities = ["read"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
```

- [ ] **Step 5: Validate**

Run: `tofu fmt -recursive opentofu/ && cd opentofu/aws/openbao/management && tofu validate`

Expected: `Success! The configuration is valid.`

- [ ] **Step 6: Plan and confirm the count [LIVE]**

Run: `tofu plan -lock=false -var-file=variables.tfvars`

Expected: `Plan: 6 to add, 0 to change, 0 to destroy.` — a policy, a group and an alias for each of the two apps. If the count is not 6, the `for_each` or the tfvars list is wrong.

- [ ] **Step 7: Apply [LIVE]**

Run: `tofu apply -auto-approve -var-file=variables.tfvars`

Expected: `Apply complete! Resources: 6 added, 0 changed, 0 destroyed.`

- [ ] **Step 8: Verify the rendered policy is prefix-scoped [LIVE]**

```bash
bao policy read app-app-wizard | grep -E '^path'
```

Expected: every path is under `apps/.../app-wizard/` (plus `apps/metadata`, `sys/mounts` and the three `auth/token/*-self` paths). **There must be no `apps/destroy/` line.**

- [ ] **Step 9: Force-add the tfvars, then commit**

`.gitignore` carries a blanket `*.tfvars`, so `git commit -- <path>` silently skips it and the file stays untracked — it then does not exist on a fresh clone, while `deploy` passes `-var-file=variables.tfvars`.

```bash
git add -f opentofu/aws/openbao/management/variables.tfvars
git ls-files opentofu/aws/openbao/management/variables.tfvars
```

Expected: the second command prints the path. Empty output means it is still untracked — stop and fix.

Message:

```
feat(openbao): per-app ownership of the apps/ mount

One policy, one external group and one alias per app, generated by for_each so
every grant is visible in a plan diff. Templating would collapse them into one
document where a single mistake widens every app at once.

destroy is not granted: a compromised credential must not erase history.
```

Then: `git commit -F /tmp/msg -- opentofu/aws/openbao/management/apps.tf opentofu/aws/openbao/management/policies/app-prefix.hcl opentofu/aws/openbao/management/variables.tf opentofu/aws/openbao/management/variables.tfvars`

---

### Task 4: The read-only External Secrets policy

**Files:**
- Create: `opentofu/aws/openbao/management/policies/external-secrets.hcl`
- Modify: `opentofu/aws/openbao/management/policies.tf`
- Modify: the file found in Step 1 (the cluster's `external-secrets` JWT role)

**Interfaces:**
- Consumes: `vault_mount.platform`, `vault_mount.apps` (Task 1).
- Produces: `vault_policy.external_secrets` (name `external-secrets`), and that name attached to the `external-secrets` JWT role on every cluster.

- [ ] **Step 1: Find where the JWT role is defined**

Run: `grep -rn "external-secrets" opentofu/aws/eks/configure/*.tf opentofu/gcp/gke/configure/*.tf | grep -i role`

The role currently has `token_policies = ["default"]` — it authenticates and can read nothing. Note the exact resource name and file for Step 4.

- [ ] **Step 2: Write the policy document**

Create `opentofu/aws/openbao/management/policies/external-secrets.hcl`:

```hcl
# External Secrets reads both mounts. It writes NOTHING, anywhere.
#
# This is the property that makes per-app ownership mean something. If the
# controller could write, any workload able to shape an ExternalSecret could
# launder a value into another app's prefix -- the controller reads with its own
# identity, not the requester's, so a per-app human policy would be bypassed by
# anything that can create a namespaced ExternalSecret.
#
# `list` on metadata is required by the provider to resolve `dataFrom` extracts;
# `read` on data is what serves an ordinary `remoteRef.key`.

path "platform/data/*" {
  capabilities = ["read"]
}

path "platform/metadata/*" {
  capabilities = ["read", "list"]
}

path "apps/data/*" {
  capabilities = ["read"]
}

path "apps/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
```

- [ ] **Step 3: Register the policy**

Append to `opentofu/aws/openbao/management/policies.tf`:

```hcl
# External Secrets' read-only identity over both Stage 2 mounts. Attached to the
# per-cluster JWT role in each cluster's configure stack, which is the only
# stack that knows that cluster's OIDC issuer.
resource "vault_policy" "external_secrets" {
  name   = "external-secrets"
  policy = file("policies/external-secrets.hcl")
}
```

- [ ] **Step 4: Attach it to the JWT role**

In the file found in Step 1, change the role's `token_policies` from `["default"]` to `["default", "external-secrets"]`.

The policy is created by the **management** stack and referenced **by name** from the configure stack, which is a different Terraform state. That is deliberate and matches how `cert-manager` is already wired. Name drift is the risk; the name is `external-secrets` in both places.

- [ ] **Step 5: Validate both stacks**

```bash
tofu fmt -recursive opentofu/
(cd opentofu/aws/openbao/management && tofu validate)
(cd opentofu/aws/eks/configure && tofu init -backend=false && tofu validate)
```

Expected: `Success!` from both.

- [ ] **Step 6: Apply the management stack, then the configure stack [LIVE]**

```bash
(cd opentofu/aws/openbao/management && tofu apply -auto-approve -var-file=variables.tfvars)
(cd opentofu/aws/eks/configure && tofu apply -auto-approve -var-file=variables.tfvars)
```

Expected: 1 added in management; 1 changed in configure.

- [ ] **Step 7: Verify the role now carries the policy [LIVE]**

```bash
bao read -field=token_policies auth/jwt/aws-0/role/external-secrets
```

Expected: `[default external-secrets]`.

- [ ] **Step 8: Prove the identity cannot write [LIVE]**

```bash
kubectl create token external-secrets -n security --audience openbao > /tmp/eso.jwt
bao write -field=token auth/jwt/aws-0/login role=external-secrets jwt=@/tmp/eso.jwt > /tmp/eso.token
```

Then, with `VAULT_TOKEN` set to the contents of `/tmp/eso.token`:

```bash
bao kv put platform/canary probe=1
bao kv list platform/
```

Expected: the `put` is **denied** with `permission denied`; the `list` succeeds (or reports no values, which is not an error). If the write succeeds, stop — the policy is wrong and no later task may proceed.

- [ ] **Step 9: Commit**

Message:

```
feat(openbao): give External Secrets a read-only identity

Stage 1 created the JWT role with token_policies = [default] -- it could
authenticate and read nothing. It reads with its own identity rather than the
requester's, so write access would let anything that can create a namespaced
ExternalSecret launder a value into another app's prefix.
```

Then commit the three paths from **Files** above.

---

## Phase 2 — Tooling

### Task 5: `secret-store.sh` learns the OpenBao store

**Files:**
- Modify: `scripts/secret-store.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks at runtime; targets the mounts from Task 1.
- Produces: a `--store aws|gcp|openbao` flag; `store_has`, `store_value` and `store_create` dispatch on it. Default when unset: the managed store for `--cloud`, so every existing invocation behaves exactly as before.

- [ ] **Step 1: Read the three dispatchers**

Run: `sed -n '102,160p' scripts/secret-store.sh` and `sed -n '573,590p' scripts/secret-store.sh`

All three `case` on `$CLOUD`. The change adds a `$STORE` variable that defaults to `$CLOUD` and is what they switch on.

- [ ] **Step 2: Add the flag and the helpers**

After the `CLOUD=""` declaration near line 64:

```bash
STORE=""          # aws|gcp|openbao; defaults to $CLOUD (the managed store)
```

In the argument loop beside `--cloud`:

```bash
        --store)   STORE="$2"; shift 2 ;;
```

After argument parsing completes:

```bash
# The managed store is the default so every existing invocation is unchanged.
[ -n "$STORE" ] || STORE="$CLOUD"
case "$STORE" in
    aws|gcp|openbao) ;;
    *) echo "--store must be aws, gcp or openbao" >&2; exit 2 ;;
esac

# kv-v2 reads and writes go through `bao kv`, which needs VAULT_ADDR, VAULT_CACERT
# and a token, all from the environment exactly as the OpenBao section of
# CLAUDE.md documents. This script never reads a token from a store.
bao_kv() {
    bao kv "$@"
}
```

- [ ] **Step 3: Add the `openbao` arm to `store_has`**

Rename `case "$CLOUD"` to `case "$STORE"` and add, before the `*)` arm:

```bash
        openbao)
            out=$(bao_kv metadata get -format=json "$1" 2>&1) && return 0 || rc=$?
            case "$out" in
                *"No value found"*|*"Code: 404"*) return 1 ;;
            esac
            ;;
```

- [ ] **Step 4: Add the `openbao` arm to `store_value`**

Rename its `case "$CLOUD"` to `case "$STORE"` and add:

```bash
        openbao)
            out=$(bao_kv get -format=json "$1" 2>&1) \
                && { printf '%s' "$out" | jq -r '.data.data | tojson'; return 0; } || rc=$?
            ;;
```

- [ ] **Step 5: Add the `openbao` arm to `store_create`**

> **Corrected during execution (2026-09-10):** `store_create` takes the JSON body on **stdin** and only the name in `$1` — there is no `$2`. Its header says so ("Create one secret from a JSON body on stdin") and the `gcp` arm already uses `--data-file=-`. The original code block here used `"$2"`, which would have written an empty secret.

```bash
        openbao)
            # `-` makes `bao kv put` read a JSON object from stdin, which is the
            # same contract the gcp arm's --data-file=- uses. kv-v2 wraps it
            # under data/ on the way in, so store_value's unwrap is the inverse.
            bao_kv put "$1" - >/dev/null
            ;;
```

- [ ] **Step 6: Update the usage block**

In the header comment, add to the flags section:

```
#   --store aws|gcp|openbao
#       Which store to act on. Defaults to the managed store for --cloud, so
#       every existing invocation is unchanged. `--store openbao` needs
#       VAULT_ADDR, VAULT_CACERT and VAULT_TOKEN in the environment.
```

- [ ] **Step 7: Lint with CI's exact flags**

Run: `shellcheck -x -S warning scripts/secret-store.sh`

Expected: exit 0, no output.

- [ ] **Step 8: Prove the default is unchanged [LIVE]**

Run: `./scripts/secret-store.sh check --cloud aws --region eu-west-3`

Expected: the same 23-key table as before this task, ending `2/23 key(s) missing`. The two missing are `cnpg/xplane-zitadel/superuser` and `cnpg/xplane-harbor/roles/harbor`, written at runtime by the CNPG seed — legitimately absent on a fresh cluster.

- [ ] **Step 9: Prove the new store answers [LIVE]**

> **Corrected during execution (2026-09-10).** The original expectation here — `check --store openbao` listing every key as `MISSING` — was wrong, and the command **is expected to abort**:
>
> ```
> ERROR: could not query the openbao secret store for 'apps-app-wizard-llm' (exit 2).
> URL: GET .../v1/sys/internal/ui/mounts/apps-app-wizard-llm
> Refusing to continue: an unreachable store is not an empty one.
> ```
>
> A managed-store key carries no mount prefix, so it is not a valid kv path and OpenBao answers "no mount here" rather than 404. `store_has` is right to refuse: reporting that as "absent" is exactly the failure its comment warns about. `check --store openbao` only becomes meaningful once keys are repointed. This does **not** affect `migrate`, which probes mapped target paths that do have a mount.

Verify the dispatch against a path that has a mount instead:

```bash
bao kv metadata get platform/harbor/admin-password    # absent -> "No value found" -> store_has returns 1
echo '{"probe":"1"}' | bao kv put platform/_canary -  # then metadata get finds it -> store_has returns 0
bao kv metadata delete platform/_canary
```

Expected: the absent probe prints `No value found at platform/metadata/harbor/admin-password`; the canary is found; the canary is removed.

- [ ] **Step 10: Commit**

Message:

```
feat(scripts): teach secret-store.sh the OpenBao store

A --store flag defaulting to the managed store for --cloud, so every existing
invocation is unchanged. store_has, store_value and store_create dispatch on it
rather than on the cloud.
```

Then: `git commit -F /tmp/msg -- scripts/secret-store.sh`

---

### Task 6: `migrate` — copy the managed store into OpenBao

**Files:**
- Modify: `scripts/secret-store.sh`

**Interfaces:**
- Consumes: `store_has`, `store_value`, `store_create` from Task 5.
- Produces: `cmd_migrate`, dispatched from `migrate)`. Dry-run unless `--apply`.

- [ ] **Step 1: Read the existing `cmd_migrate_aws` for its idiom**

Run: `sed -n '347,410p' scripts/secret-store.sh`

It is additive, dry-run by default, and prints a DRY RUN banner. `cmd_migrate` follows the same shape; the difference is that source and destination are different **stores** rather than different names in one store.

- [ ] **Step 2: Write the path mapping**

```bash
# Managed-store key -> OpenBao path. Explicit, because the managed store's names
# are not uniform: ADR-0023 introduced the dash form, slash-form names predate
# it, and the cnpg/* ones are generated at runtime.
#
# Anything not listed is SKIPPED and reported, never guessed. A wrong guess here
# writes a platform secret into an app's prefix, which is a privilege boundary.
bao_target_for() {
    case "$1" in
        harbor-admin-password)   printf 'platform/harbor/admin-password' ;;
        harbor-oidc)             printf 'platform/harbor/oidc' ;;
        harbor-valkey-password)  printf 'platform/harbor/valkey-password' ;;
        headlamp-envvars)        printf 'platform/headlamp/envvars' ;;
        zitadel-envvars)         printf 'platform/zitadel/envvars' ;;
        runlore-credentials)     printf 'platform/runlore/credentials' ;;
        runlore-slack-app)       printf 'platform/runlore/slack-app' ;;
        runlore-webhook)         printf 'platform/runlore/webhook' ;;
        security-flux-ui-oidc)   printf 'platform/flux/ui-oidc' ;;
        observability-flux-slack-app) printf 'platform/flux/slack-app' ;;
        observability-victoria-metrics-k8s-stack-grafana-envvars) printf 'platform/victoria-metrics/grafana-envvars' ;;
        observability-victoria-metrics-k8s-stack-alertmanager-slack-app) printf 'platform/victoria-metrics/alertmanager-slack-app' ;;
        tailscale-k8s-operator-oauth-client) printf 'platform/tailscale/operator-oauth-client' ;;
        apps-app-wizard-llm)     printf 'apps/app-wizard/llm' ;;
        apps-app-wizard-oauth)   printf 'apps/app-wizard/oauth' ;;
        apps/image-gallery/config) printf 'apps/image-gallery/config' ;;
        *)                       return 1 ;;
    esac
}

# The keys to consider: every key the cluster's ExternalSecrets ask for.
migrate_source_keys() {
    kctl get externalsecrets -A -o json \
        | jq -r '.items[]
                 | ((.spec.data // [])[]?.remoteRef.key,
                    (.spec.dataFrom // [])[]?.extract.key)
                 | select(. != null)' \
        | sort -u
}
```

- [ ] **Step 3: Write `cmd_migrate`**

```bash
# Copy every mapped key from the managed store into OpenBao.
#
# Additive and idempotent: a destination that already exists is left alone and
# reported as `exists`, and the source is never deleted. Removing the migrated
# managed-store entries is a deliberate, separate, manual act.
cmd_migrate() {
    [ -n "$CLOUD" ] || { echo "--cloud is required" >&2; exit 2; }
    local copied=0 exists=0 skipped=0 absent=0 key target payload

    printf '%-58s %-46s %s\n' "SOURCE KEY" "OPENBAO PATH" "ACTION"
    while IFS= read -r key; do
        [ -z "$key" ] && continue

        if ! target=$(bao_target_for "$key"); then
            printf '%-58s %-46s %s\n' "$key" "-" "skipped (unmapped)"
            skipped=$((skipped + 1))
            continue
        fi

        STORE="$CLOUD"
        if ! store_has "$key"; then
            printf '%-58s %-46s %s\n' "$key" "$target" "absent at source"
            absent=$((absent + 1))
            continue
        fi
        payload=$(store_value "$key")

        STORE="openbao"
        if store_has "$target"; then
            printf '%-58s %-46s %s\n' "$key" "$target" "exists (left alone)"
            exists=$((exists + 1))
            continue
        fi

        if [ "$APPLY" = "true" ]; then
            # store_create reads the body on stdin; it takes no payload argument.
            printf '%s' "$payload" | store_create "$target"
            printf '%-58s %-46s %s\n' "$key" "$target" "copied"
        else
            printf '%-58s %-46s %s\n' "$key" "$target" "would copy"
        fi
        copied=$((copied + 1))
    done <<< "$(migrate_source_keys)"

    echo
    echo "copied: ${copied}, exists: ${exists}, absent: ${absent}, skipped: ${skipped}"
    [ "$APPLY" = "true" ] || echo $'\nThis was a DRY RUN. Nothing was written. Re-run with --apply.'
}
```

- [ ] **Step 4: Dispatch it**

In the `case "$COMMAND"` block, beside `migrate-aws)`:

```bash
    migrate)     cmd_migrate ;;
```

- [ ] **Step 5: Lint**

Run: `shellcheck -x -S warning scripts/secret-store.sh`

Expected: exit 0.

- [ ] **Step 6: Dry run [LIVE]**

Run: `./scripts/secret-store.sh migrate --cloud aws --region eu-west-3`

Expected: a table ending `This was a DRY RUN`. Every platform and app key shows `would copy`; the three `cnpg/*` keys and `certificates/priv.aws.ogenki.io/ca-chain` show `skipped (unmapped)`. **The CA must be skipped** — it is bootstrap tier, and copying it would invite someone to repoint it later, which is circular.

- [ ] **Step 7: Commit**

Message:

```
feat(scripts): migrate the managed store into OpenBao

Additive and idempotent -- an existing destination is left alone and the source
is never deleted. The key mapping is explicit rather than derived: a wrong guess
writes a platform secret into an app's prefix.
```

Then: `git commit -F /tmp/msg -- scripts/secret-store.sh`

---

## Phase 3 — Repoint, one secret at a time

### Task 7: The OpenBao-backed ClusterSecretStores

**Files:**
- Create: `security/base/openbao/clustersecretstore-platform.yaml`
- Create: `security/base/openbao/clustersecretstore-apps.yaml`
- Modify: the kustomization that includes them (run `ls security/base/openbao/ security/aws-0/openbao/` first — today only the `aws-0` and `gcp-0` overlays exist, so decide base-vs-overlay by where the store's `${cluster_name}` substitution is available)

**Interfaces:**
- Consumes: the `external-secrets` JWT role policy from Task 4; the `openbao-ca` Secret in namespace `security` (key `ca.crt`), produced by the existing AWS-backed ExternalSecret, which must stay that way.
- Produces: `ClusterSecretStore/openbao-platform` and `ClusterSecretStore/openbao-apps`, referenced by name from Tasks 8-10.

- [ ] **Step 1: Write the platform store**

```yaml
# Reads the `platform/` kv-v2 mount as External Secrets' own cluster identity.
#
# Auth is the per-cluster JWT mount Stage 1 created, not an AppRole: the
# controller presents a projected ServiceAccount token with audience `openbao`
# and gets back a token carrying the read-only `external-secrets` policy. There
# is no long-lived credential anywhere in this path.
#
# The CA comes from the `openbao-ca` Secret, which is itself produced by an
# ExternalSecret reading the CLOUD store. That is deliberate and must not be
# "cleaned up": this store cannot verify OpenBao's certificate without a CA it
# obtained before OpenBao was usable, so the CA stays bootstrap tier.
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao-platform
spec:
  provider:
    vault:
      server: "https://openbao.security.svc.cluster.local:8200"
      path: "platform"
      version: "v2"
      caProvider:
        type: Secret
        name: openbao-ca
        namespace: security
        key: ca.crt
      auth:
        jwt:
          path: "jwt/${cluster_name}"
          role: "external-secrets"
          kubernetesServiceAccountToken: # pragma: allowlist secret
            serviceAccountRef:
              name: external-secrets
              namespace: security
            audiences:
              - openbao
```

- [ ] **Step 2: Write the apps store**

Identical except the name and the mount. Repeated in full rather than referenced — a reader may open either file first.

```yaml
# Reads the `apps/` kv-v2 mount. Same identity and CA rationale as
# clustersecretstore-platform.yaml; a separate store because the vault provider
# takes ONE mount per store (spec.provider.vault.path).
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao-apps
spec:
  provider:
    vault:
      server: "https://openbao.security.svc.cluster.local:8200"
      path: "apps"
      version: "v2"
      caProvider:
        type: Secret
        name: openbao-ca
        namespace: security
        key: ca.crt
      auth:
        jwt:
          path: "jwt/${cluster_name}"
          role: "external-secrets"
          kubernetesServiceAccountToken: # pragma: allowlist secret
            serviceAccountRef:
              name: external-secrets
              namespace: security
            audiences:
              - openbao
```

- [ ] **Step 3: Confirm `${cluster_name}` is a defined substitution variable**

Run: `python3 scripts/flux-schema/check-substitution.py`

Expected: exit 0. If it reports `cluster_name` as undefined for either cluster, use the variable that cluster's `flux_cluster_vars` actually defines — grep `opentofu/aws/eks/configure/kubernetes.tf` for the key list. Flux substitutes an **empty string** for an undefined variable, which would silently produce `jwt/` and fail authentication with a confusing 400.

- [ ] **Step 4: Wire both into the kustomization**

Add both filenames to `resources:`, and make sure the directory is reachable from each cluster's `security` Kustomization.

- [ ] **Step 5: Validate the bundle**

Run: `./scripts/validate-manifests.sh`

Expected: exit 0, report ends `Invalid: 0, Skipped: 0`.

- [ ] **Step 6: Commit and let Flux apply [LIVE]**

Message:

```
feat(secrets): add OpenBao-backed ClusterSecretStores

Two stores because the vault provider takes one mount per store. Auth is the
per-cluster JWT mount with a projected ServiceAccount token -- no long-lived
credential. Nothing is repointed onto them yet.
```

- [ ] **Step 7: Verify both stores go Ready [LIVE]**

```bash
kubectl get clustersecretstore openbao-platform openbao-apps
```

Expected: `STATUS=Valid` and `READY=True` for both. `Ready=False` with an auth error means the JWT role, the audience or the Task 4 policy is wrong — fix that before Task 8.

---

### Task 8: Migrate and repoint ONE secret, end to end

**Files:**
- Modify: `tooling/base/headlamp/externalsecret-headlamp-envvars.yaml`

`headlamp-envvars` is the proof case: one key, one consumer, and a failure is visible immediately (Headlamp's OIDC login breaks) without taking down a dependency chain.

**Interfaces:**
- Consumes: `ClusterSecretStore/openbao-platform` (Task 7), `cmd_migrate` (Task 6).

- [ ] **Step 1: Copy the mapped keys [LIVE]**

```bash
./scripts/secret-store.sh migrate --cloud aws --region eu-west-3 --apply
```

Expected: the table shows `headlamp-envvars -> platform/headlamp/envvars  copied`. This copies every mapped key, which is intentional — copying is harmless, and only the repoint changes behaviour.

- [ ] **Step 2: Verify the value landed intact [LIVE]**

```bash
bao kv get -format=json platform/headlamp/envvars | jq -r '.data.data | keys'
aws secretsmanager get-secret-value --region eu-west-3 --secret-id headlamp-envvars --query SecretString --output text | jq -r 'keys'
```

Expected: the two key lists are **identical**. If they differ, stop — the payload shape is being mangled by `store_create`.

- [ ] **Step 3: Repoint the ExternalSecret**

Change:

```yaml
  secretStoreRef:
    kind: ClusterSecretStore
    name: clustersecretstore
```

to:

```yaml
  secretStoreRef:
    kind: ClusterSecretStore
    name: openbao-platform
```

and change the key from `headlamp-envvars` to `headlamp/envvars` — **the mount is not part of the key**; the store already points at `platform`.

- [ ] **Step 4: Validate**

Run: `./scripts/validate-manifests.sh`

Expected: exit 0, `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit and let Flux reconcile [LIVE]**

Message:

```
feat(secrets): read headlamp-envvars from OpenBao

The proof case for the repoint: one key, one consumer, and a failure is visible
immediately without taking down a dependency chain.
```

- [ ] **Step 6: Verify the Secret is rebuilt from OpenBao [LIVE]**

```bash
kubectl get externalsecret headlamp-envvars -n tooling -o jsonpath='{.status.conditions[*].type}={.status.conditions[*].status}{"\n"}'
kubectl get secret headlamp-envvars -n tooling -o jsonpath='{.data}' | jq -r 'keys'
```

Expected: `Ready=True`, and the same key set as before the repoint.

- [ ] **Step 7: Verify the consumer still works [LIVE]**

Log in to `https://headlamp.priv.aws.ogenki.io` through ZITADEL. Expected: the OIDC round trip completes. This is the real assertion — the Secret existing is not the same as its contents being right.

---

### Task 9: Repoint the remaining platform secrets

**Files:**
- Modify, one per commit: the `ExternalSecret` documents for `harbor-admin-password`, `harbor-oidc`, `harbor-valkey-password`, `zitadel-envvars`, `runlore-credentials`, `runlore-slack-app`, `runlore-webhook`, `security-flux-ui-oidc`, `observability-flux-slack-app`, and the two `victoria-metrics-k8s-stack-*` keys.

Find each with: `grep -rln "<key>" --include=*.yaml security/ observability/ tooling/ apps/ flux/`

- [ ] **Step 1: Repoint in dependency order, lowest blast radius first**

Order: `runlore-*` (isolated), then `observability-*`, then `harbor-*`, then `security-flux-ui-oidc`, then `zitadel-envvars` **last**.

`zitadel-envvars` is last on purpose. ZITADEL is the IdP for the OIDC login this whole design depends on, including access to OpenBao itself. Breaking it while holding no `userpass` session turns a recovery into an incident — confirm `bao login -method=userpass username=admin` works before touching it.

- [ ] **Step 2: For each key, apply the Task 8 pattern**

Change `secretStoreRef.name` to `openbao-platform`, strip the `platform/` prefix from the key, validate, commit alone, wait for `Ready=True`, and confirm the consuming workload is healthy before moving to the next.

- [ ] **Step 3: After each, verify**

```bash
kubectl get externalsecret -A | grep -v "SecretSynced" || echo "all ExternalSecrets synced"
flux get kustomizations | awk '$4!="True"'
```

Expected: no unsynced ExternalSecret, and no Kustomization off `Ready=True`.

- [ ] **Step 4: Commit each repoint separately**

One key per commit, so a bad one is a single revert.

---

### Task 10: Repoint the app secrets

> **BLOCKED — found during execution (2026-09-10). Do not attempt this task from this repository.**
>
> App secrets are **not** standalone `ExternalSecret` manifests. They are declared inside the `App` claim as `spec.externalSecrets[].remoteRef`, and the Crossplane composition generates the `ExternalSecret` — hardcoding `secretStoreRef.name: clustersecretstore`. The XRD schema exposes no store field at all:
>
> ```
> FIELD: externalSecrets <[]Object>
>   name           -required-   Kubernetes Secret name
>   refreshInterval
>   remoteRef      -required-   Path to secret in AWS Secrets Manager
> ```
>
> The description is explicit that the source is AWS Secrets Manager. Repointing therefore needs, in order:
>
> 1. A composition change in [`Smana/crossplane-configuration`](https://github.com/Smana/crossplane-configuration): add an optional `store` (and probably `property`) to `externalSecrets`, defaulting to `clustersecretstore` so existing claims are unaffected.
> 2. `task check` there, then a release.
> 3. A pin bump in `infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml` **and** the matching app-wizard tag, which must move together.
> 4. Only then, `store: openbao-apps` on the three claim entries.
>
> The three keys are already migrated and hash-verified in `apps/`, so the mount is ready and waiting. Nothing is lost by deferring.
>
> This also means **the `apps/` mount has no consumer yet**, and the per-app groups grant access to data only humans can reach. That is a coherent intermediate state, not a broken one.

**Files:**
- Modify: the `ExternalSecret` documents for `apps-app-wizard-llm`, `apps-app-wizard-oauth`, `apps/image-gallery/config`

- [ ] **Step 1: Repoint each onto `openbao-apps`**

`secretStoreRef.name: openbao-apps`, and keys become `app-wizard/llm`, `app-wizard/oauth`, `image-gallery/config`.

- [ ] **Step 2: Validate and commit each**

Run `./scripts/validate-manifests.sh` between each; commit one per key.

- [ ] **Step 3: Verify the apps still start [LIVE]**

```bash
kubectl get pods -n apps
kubectl get apps.cloud.ogenki.io -A
```

Expected: no `CreateContainerConfigError`, and every `App` claim `READY=True`.

- [ ] **Step 4: Prove the per-app boundary holds [LIVE]**

This is the security assertion of the whole design. As a human holding **only** the `app-app-wizard` role:

```bash
bao kv get apps/app-wizard/llm
bao kv get apps/image-gallery/config
```

Expected: the first succeeds, the second is **denied**. If the second succeeds, the policy is not prefix-scoped and Task 3 must be fixed before this task is accepted.

---

### Task 11: Decide where the runtime-generated `cnpg/*` secrets live

**Files:**
- Modify: `docs/superpowers/specs/2026-09-10-openbao-stage2-secrets-personas-design.md`

Three keys — `cnpg/xplane-image-gallery/roles/image-gallery-app`, `cnpg/xplane-zitadel/superuser`, `cnpg/xplane-harbor/roles/harbor` — are **written at runtime** by the CNPG seeding path, not curated by a human. The design did not anticipate them.

- [ ] **Step 1: Find what writes them**

Run: `grep -rn "cnpg/" --include=*.sh --include=*.yaml scripts/ security/ infrastructure/ apps/ | grep -v externalsecret`

- [ ] **Step 2: Choose and record**

Two defensible options; pick one and write it into the design as a "Runtime-generated secrets" section:

- **Leave them in the managed store.** They are generated by infrastructure rather than curated, and the writer would need OpenBao write access — which contradicts "machines read, humans write".
- **Move them, and give the writer a narrowly-scoped write policy** on `platform/cnpg/*` only.

The recommendation is **leave them**: granting any machine write access to a mount is the property Task 4 deliberately removed, and these secrets are reconstructible by re-running the seed.

- [ ] **Step 3: Commit the decision**

Message: `docs(openbao): record where the runtime-generated cnpg secrets live`

---

## Phase 4 — Records and cleanup

### Task 12: ADR-0036 and the documentation updates

**Files:**
- Create: `website/content/docs/decisions/0036-per-app-secret-ownership-through-zitadel-groups.md`
- Modify: `CLAUDE.md` (the "OpenBao" and "Namespace layout" sections)
- Modify: `.doc-claims.yaml`

- [ ] **Step 1: Write the ADR**

Follow the format of `website/content/docs/decisions/0035-own-headlamp-plugin-for-the-app-view.md`. Decision: per-app secret ownership through ZITADEL groups, generated per app rather than templated. Rejected alternatives, each with its reason:

- **Identity templating** (`{{identity.groups.names.*}}`) — one policy instead of N, but the grant stops being visible in a plan diff and one template mistake widens every app at once.
- **Flat reader/writer/admin tiers** over the whole store — simpler, but a writer reaches every app's secrets, so the tier says nothing about blast radius.
- **A namespace per app** — reintroduces the cross-namespace identity problem for no gain over a path prefix.
- **Leaving app secrets in the cloud managed store** — the status quo; no single policy or audit model, and humans and machines see different stores.

- [ ] **Step 2: Correct CLAUDE.md**

The "Namespace layout" section says `app` is the only namespace and holds the only kv-v2 mount, reachable via its own AppRole. After this work both mounts are in **root**. Rewrite that paragraph, and note that human access is per-app through the `groups` claim.

- [ ] **Step 3: Add doc claims**

Add claims for the two mount names, so a rename fails a check rather than silently rotting the docs.

- [ ] **Step 4: Validate the docs**

```bash
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
```

Expected: exit 0 from both.

- [ ] **Step 5: Commit**

Message: `docs(openbao): ADR-0036 and the Stage 2 documentation`

---

### Task 13: Remove the dead `app` namespace, and the migrated managed-store entries

**Files:**
- Modify: `opentofu/aws/openbao/management/namespaces.tf`, `mounts.tf`, `auth.tf`, `policies.tf` — remove `vault_namespace.app`, `vault_mount.app_secret`, `vault_auth_backend.approle_app`, `vault_approle_auth_backend_role.app`, `vault_policy.app`
- Delete: `opentofu/aws/openbao/management/policies/app.hcl`

- [ ] **Step 1: Prove the namespace holds no data [LIVE]**

```bash
bao kv list -namespace=app secret/
```

Expected: `No value found` or an empty list. **If it lists anything, stop** — the design assumed it was empty and that assumption is now wrong. Report rather than delete.

- [ ] **Step 2: Remove the resources and validate**

Run: `tofu fmt -recursive opentofu/ && cd opentofu/aws/openbao/management && tofu validate`

Expected: `Success!`

- [ ] **Step 3: Plan and read the destroy list carefully [LIVE]**

Run: `tofu plan -lock=false -var-file=variables.tfvars`

Expected: `5 to destroy`, all of them `app`-namespace resources. **If `vault_mount.platform`, `vault_mount.apps` or any policy from Tasks 2-4 appears in the destroy list, stop.**

- [ ] **Step 4: Apply [LIVE]**

Run: `tofu apply -auto-approve -var-file=variables.tfvars`

- [ ] **Step 5: Delete the migrated managed-store entries by hand [LIVE]**

Only after every repointed `ExternalSecret` has been `Ready=True` for a full working day. For each migrated key:

```bash
aws secretsmanager delete-secret --region eu-west-3 --secret-id <key> --recovery-window-in-days 30
```

Record every command in the PR body. `--recovery-window-in-days 30` is not optional: it is what makes this reversible.

**Do not delete** the bootstrap tier — `certificates/priv.aws.ogenki.io/ca-chain`, the OpenBao TLS cert/key, root token, recovery keys, intermediate CA bundle — nor the three `cnpg/*` keys, per Task 11.

- [ ] **Step 6: Final verification [LIVE]**

```bash
./scripts/secret-store.sh check --cloud aws --region eu-west-3
./scripts/secret-store.sh check --cloud aws --store openbao --region eu-west-3
flux get kustomizations | awk '$4!="True"'
./scripts/validate-manifests.sh
```

Expected: the AWS store lists only the bootstrap tier and the `cnpg/*` keys; the OpenBao store lists everything else as `ok`; no Kustomization off `Ready=True`; the manifest report ends `Invalid: 0, Skipped: 0`.

- [ ] **Step 7: Commit**

Message:

```
refactor(openbao): remove the unused app namespace

It held no data and nothing consumed it. Both Stage 2 mounts are in root, where
the oidc mount and every policy live, so the namespace is a decoy that suggests
a working tenant model that was never wired up.
```

---

## Appendix: the live key inventory this plan was written against

`./scripts/secret-store.sh check --cloud aws --region eu-west-3`, 2026-09-10, 23 keys:

| Managed-store key | Destination | Note |
|---|---|---|
| `certificates/priv.aws.ogenki.io/ca-chain` | **stays** | bootstrap tier; two consumers |
| `cnpg/xplane-image-gallery/roles/image-gallery-app` | **stays** | runtime-generated (Task 11) |
| `cnpg/xplane-zitadel/superuser` | **stays** | runtime-generated; absent on a fresh cluster |
| `cnpg/xplane-harbor/roles/harbor` | **stays** | runtime-generated; absent on a fresh cluster |
| `harbor-admin-password` | `platform/harbor/admin-password` | |
| `harbor-oidc` | `platform/harbor/oidc` | |
| `harbor-valkey-password` | `platform/harbor/valkey-password` | |
| `headlamp-envvars` | `platform/headlamp/envvars` | Task 8 proof case |
| `zitadel-envvars` | `platform/zitadel/envvars` | two consumers; repoint **last** |
| `runlore-credentials` | `platform/runlore/credentials` | |
| `runlore-slack-app` | `platform/runlore/slack-app` | |
| `runlore-webhook` | `platform/runlore/webhook` | two consumers |
| `security-flux-ui-oidc` | `platform/flux/ui-oidc` | |
| `observability-flux-slack-app` | `platform/flux/slack-app` | |
| `observability-victoria-metrics-k8s-stack-grafana-envvars` | `platform/victoria-metrics/grafana-envvars` | |
| `observability-victoria-metrics-k8s-stack-alertmanager-slack-app` | `platform/victoria-metrics/alertmanager-slack-app` | |
| `tailscale-k8s-operator-oauth-client` | `platform/tailscale/operator-oauth-client` | |
| `apps-app-wizard-llm` | `apps/app-wizard/llm` | |
| `apps-app-wizard-oauth` | `apps/app-wizard/oauth` | |
| `apps/image-gallery/config` | `apps/image-gallery/config` | |

Two keys report `MISSING` on a fresh cluster (`cnpg/xplane-zitadel/superuser`, `cnpg/xplane-harbor/roles/harbor`) because the CNPG seed writes them after the databases come up. That is expected and is not something this plan fixes.
