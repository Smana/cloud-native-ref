# OpenBao Stage 2 on GCP — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give GCP's own OpenBao the Stage 2 store of record: the `platform/` and `apps/` mounts, the policies and the logins. After that, a GCP-only platform (the occasional test topology), and gcp-0 in AWS + GCP mode, can run the 14 consumers that fail on gcp-0 today.

**Architecture:**
- **The module.** The Stage 2 OpenBao configuration moves into one shared OpenTofu module, `opentofu/shared/modules/openbao-store-of-record`. Only `opentofu/gcp/openbao/management` calls it for now; AWS is not touched.
- **First boot.** A new, explicit `OPENBAO_NEW_LINEAGE=true` switch in `scripts/openbao-config.sh rehydrate` lets a brand-new GCP-sealed lineage boot beside the AWS-sealed mirror.
- **The guard.** A static check ties every policy a cluster's JWT roles name to the management stack that must define it.
- **Live validation.** A throwaway branch that makes GCP primary is used for the live run.

**Tech Stack:**
- OpenTofu 1.12.6, with `tofu test` and `mock_provider`
- hashicorp/vault ~> 5.x, hashicorp/google ~> 7.17, hashicorp/random ~> 3.6
- bash with jq
- python3, stdlib only
- Terramate 0.17.2
- GitHub Actions
- Hugo docs

**Spec:** `docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-design.md`, approved 2026-09-11. Read it alongside this plan: it records the decisions (D1–D5), the rejected alternatives, and the three topologies.

## Global Constraints

- **AWS primary is the nominal topology. No file under `opentofu/aws/` changes in this plan.**
- **Worktree.** `.claude/worktrees/openbao-stage2-gcp`, branch `worktree-openbao-stage2-gcp`. It is stacked on `worktree-workspace-access-matrix`, and that PR merges first. Never commit on `main`. Never `git stash`. Never `cd` into another checkout.
- **Attribution.** Never add a `Co-Authored-By` trailer or a `Claude-Session:` line. Never write "Generated with Claude Code" in a commit or PR.
- **Committing.** Write the message to a file, then `git commit -F <file> -- <paths>`. A NEW file must be `git add`ed first, because a pathspec commit silently skips untracked paths.
- **Pre-commit.** If the hook rejects a commit, stop and report the exact output. Never `--no-verify`, and never edit `.secrets.baseline` to get past it.
- **OpenBao applies.** Every `tofu apply` against OpenBao uses `-parallelism=1`. OpenBao 2.6.x deadlocks under concurrent writes (openbao/openbao#3411).
- **The rehydrate refusal stays.** Its default behaviour must not change. The new switch is honoured only when no top-level object carries this node's seal. It never bypasses the "moved aside" (`rc 2`) or "cannot list" refusals, and it never combines with `OPENBAO_SNAPSHOT_KEY`.
- **GCP Secret Manager names** are dash-separated. The bootstrap tier stays in Secret Manager: `openbao-priv-gcp-*`, `flux-github-app`, `tailscale-k8s-operator-oauth` and `headlamp-oauth2-proxy`.
- **Break-glass credentials on GCP** are stored in Secret Manager as `openbao-priv-gcp-admin-credentials`, with the JSON shape `{username, password, address}`.
- **The OIDC store key** is `openbao-oidc`, shaped `{client_id, client_secret, endpoint}` and written by `scripts/zitadel-oidc-clients.sh`.
- **Live work.**
  - No teardown without the owner's explicit consent.
  - `TM_LINEAGE_DESTROY` is never set.
  - The test branch `test/gcp-only-live` is never merged.
- **Validators.** Run these from the repository root; each must exit 0.
  - `shellcheck -x -S warning <each changed .sh>`
  - `./scripts/validate-links.sh`, `./scripts/validate-doc-claims.sh` and `./scripts/verify-doc-paths.sh` after any doc change
  - `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml <dir>` on each changed OpenTofu directory
- **Live values.** Do not invent alternatives.

  | Thing | Value |
  |---|---|
  | GCP project | `ogenki-435905` (number `323586397743`) |
  | GCP OpenBao | `https://bao.priv.gcp.ogenki.io:8200` |
  | ZITADEL on GCP | `https://auth.gcp.cloud.ogenki.io` |
  | GCP ZITADEL seed | `zitadel-20260828`, already pinned in `security/gcp-0/zitadel/kustomization.yaml` |
  | Snapshot bucket | `ogenki-435905-ogenki-openbao-snapshot` (it also holds the AWS mirror) |
  | Reconciler service account | `access-matrix-sync@ogenki-435905.iam.gserviceaccount.com` |
  | Per-app personas | `secret_owning_apps = ["app-wizard", "image-gallery"]`, the same as AWS |

---

## File Structure

| File | Responsibility |
|---|---|
| `opentofu/shared/modules/openbao-store-of-record/versions.tf` | provider requirements (vault, random) |
| `…/variables.tf` | module inputs |
| `…/mounts.tf` | `platform/` and `apps/` kv-v2 mounts |
| `…/policies.tf` | `admin`, `pki-admin`, `secrets-admin` and `external-secrets` |
| `…/apps.tf` | per-app policy, identity group and alias (ADR-0036) |
| `…/auth.tf` | `userpass` break-glass backend, generated password and admin user |
| `…/oidc.tf` | ZITADEL OIDC mount and role, the `openbao-admin` group and its alias |
| `…/outputs.tf` | `admin_password` (sensitive), mount paths and policy names |
| `…/policies/*.hcl` | the five policy documents, copied verbatim from the AWS stack |
| `…/tests/store_of_record.tftest.hcl` | offline `tofu test` with mocked providers |
| `opentofu/gcp/openbao/management/store-of-record.tf` | reads `openbao-oidc`, calls the module, publishes the break-glass credentials |
| `opentofu/gcp/openbao/management/{variables,outputs,versions}.tf`, `variables.tfvars`, `policies.tf`, `auth.tf` | new inputs, a new output, the random provider, and corrected comments |
| `scripts/validate-openbao-policies.sh` | static policy-parity check |
| `scripts/test-validate-openbao-policies.sh` | fixture tests for that check |
| `scripts/openbao-config.sh` | `new_lineage_verdict()`, the switch at the seal gate, and the usage text |
| `scripts/test-openbao-new-lineage.sh` | the verdict and wiring tests |
| `scripts/secret-store.sh` | `--keys` and `migrate_keys()` |
| `scripts/test-secret-store-migrate-keys.sh` | the `migrate_keys` tests |
| `.github/workflows/ci.yaml` | runs the three new test files and the new check |
| `website/content/docs/decisions/0037-gcp-only-runs-its-own-openbao-lineage-and-directory.md` | new ADR |
| `website/content/docs/decisions/{_index.md,0027-…,0033-…}` | the index row and one pointer in each ADR |
| `website/content/docs/{platform/security/secrets.md,guides/openbao-cross-cloud-failover.md,get-started/sso.md}`, `CLAUDE.md` | doc updates |
| `docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-verification.md` | live evidence, written in Task 12 |

Tasks 1–6 need no cloud and are fit for subagents. **Tasks 7–12 are [LIVE].** The controller runs them with the owner present: they need Google logins, the ZITADEL console and edits to Workspace groups.

---

### Task 1: The shared module, tested offline

**Files:**
- Create: `opentofu/shared/modules/openbao-store-of-record/{versions,variables,mounts,policies,apps,auth,oidc,outputs}.tf`
- Create: `opentofu/shared/modules/openbao-store-of-record/policies/{admin,pki-admin,secrets-admin,external-secrets,app-prefix}.hcl`, copied verbatim from AWS
- Test: `opentofu/shared/modules/openbao-store-of-record/tests/store_of_record.tftest.hcl`

**Interfaces:**
- Consumes: nothing.
- Produces a module with these inputs:
  - `pki_mount_path` (string)
  - `openbao_address` (string)
  - `admin_username` (string, default `"admin"`)
  - `admin_group_alias` (string, default `"platform"`)
  - `secret_owning_apps` (set(string), default `[]`)
  - `oidc_client_id` (string, default `""`)
  - `oidc_client_secret` (string, sensitive, default `""`)
  - `oidc_issuer` (string, default `""`)
- And these outputs:
  - `admin_password` (sensitive)
  - `platform_mount_path`
  - `apps_mount_path`
  - `policy_names` (list of the four policy names)
  - `oidc_enabled` (number, 0 or 1)
- The policy names are exactly `admin`, `pki-admin`, `secrets-admin` and `external-secrets`. These are the names `opentofu/gcp/gke/configure/openbao.tf` already references.

- [ ] **Step 1: Copy the policy documents verbatim**

```bash
mkdir -p opentofu/shared/modules/openbao-store-of-record/policies opentofu/shared/modules/openbao-store-of-record/tests
cp opentofu/aws/openbao/management/policies/admin.hcl \
   opentofu/aws/openbao/management/policies/pki-admin.hcl \
   opentofu/aws/openbao/management/policies/secrets-admin.hcl \
   opentofu/aws/openbao/management/policies/external-secrets.hcl \
   opentofu/aws/openbao/management/policies/app-prefix.hcl \
   opentofu/shared/modules/openbao-store-of-record/policies/
```

The files are copies, not moves: AWS keeps its own until it moves onto the module, which is a follow-up. `pki-admin.hcl` is templated on `${pki_mount}`, and `app-prefix.hcl` on `${mount}` and `${app}`.

- [ ] **Step 2: Write the failing test**

Create `opentofu/shared/modules/openbao-store-of-record/tests/store_of_record.tftest.hcl`:

```hcl
# Offline: mocked providers, so no OpenBao is needed. `command = apply` because
# the break-glass user's data_json embeds the generated password, which is only
# known after an apply -- and under mock providers an apply calls nothing real.
mock_provider "vault" {}
mock_provider "random" {}

variables {
  pki_mount_path  = "pki_private_issuer"
  openbao_address = "https://bao.priv.gcp.ogenki.io:8200"
}

run "mounts_policies_and_break_glass_without_oidc" {
  command = apply

  assert {
    condition     = vault_mount.platform.path == "platform" && vault_mount.apps.path == "apps"
    error_message = "the two Stage 2 mounts must be platform/ and apps/"
  }
  assert {
    condition     = vault_policy.external_secrets.name == "external-secrets"
    error_message = "the JWT roles reference this policy BY NAME: it must be external-secrets"
  }
  assert {
    condition     = length(vault_jwt_auth_backend.oidc) == 0 && length(vault_identity_group.oidc_admin) == 0
    error_message = "OIDC must stay off without a client id and an issuer"
  }
  assert {
    condition     = length(vault_policy.app_prefix) == 0
    error_message = "per-app personas alias the OIDC mount, so they must not exist without it"
  }
  assert {
    condition     = contains(jsondecode(vault_generic_endpoint.admin_user.data_json).policies, "secrets-admin")
    error_message = "the break-glass login must carry secrets-admin, or it cannot read what it exists to recover"
  }
}

run "oidc_group_and_personas_when_configured" {
  command = apply

  variables {
    oidc_client_id     = "fixture-client"
    oidc_client_secret = "fixture-value" # pragma: allowlist secret
    oidc_issuer        = "https://auth.gcp.cloud.ogenki.io"
    secret_owning_apps = ["app-wizard", "image-gallery"]
  }

  assert {
    condition     = length(vault_jwt_auth_backend.oidc) == 1 && vault_jwt_auth_backend.oidc[0].path == "oidc"
    error_message = "the OIDC mount must exist, at the pinned path oidc/"
  }
  assert {
    condition     = vault_identity_group_alias.oidc_admin[0].name == "platform"
    error_message = "the openbao-admin group must alias the matrix's platform team"
  }
  assert {
    condition     = contains(vault_identity_group.oidc_admin[0].policies, "secrets-admin")
    error_message = "openbao-admin must carry secrets-admin"
  }
  assert {
    condition     = length(vault_policy.app_prefix) == 2
    error_message = "one policy per secret-owning app"
  }
}
```

- [ ] **Step 3: Run the test and watch it fail**

```bash
tofu -chdir=opentofu/shared/modules/openbao-store-of-record init -backend=false
tofu -chdir=opentofu/shared/modules/openbao-store-of-record test
```

Expected: FAIL. No resource is declared yet, so every assertion references an undeclared resource. `init` may also warn that no required providers are declared. Both are the expected red.

- [ ] **Step 4: Write `versions.tf`**

```hcl
terraform {
  required_version = "~> 1.5"

  required_providers {
    # The OpenBao API is Vault-compatible, so the vault provider drives it.
    # `~> 5.0` admits both callers: AWS pins ~> 5.0, GCP ~> 5.4.
    vault = {
      source  = "hashicorp/vault"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
```

- [ ] **Step 5: Write `variables.tf`**

```hcl
variable "pki_mount_path" {
  description = "The PKI mount this OpenBao issues from. Templated into the pki-admin policy so the policy cannot drift from the mount it governs."
  type        = string
}

variable "openbao_address" {
  description = "https://bao.<private domain>:8200. Builds the OIDC UI callback, which must match what scripts/zitadel-oidc-clients.sh registers."
  type        = string
}

variable "admin_username" {
  description = "Username of the userpass break-glass login"
  type        = string
  default     = "admin"
}

variable "admin_group_alias" {
  description = "The value in the token's `groups` claim that maps to openbao-admin. It is the access matrix's platform team."
  type        = string
  default     = "platform"
}

variable "secret_owning_apps" {
  description = "Apps that own a prefix under apps/. Each gets a policy, an external identity group and an alias (ADR-0036). Only created when OIDC is configured, because the alias is bound to the OIDC mount."
  type        = set(string)
  default     = []
}

variable "oidc_client_id" {
  description = "ZITADEL client id for OpenBao's OIDC login. Empty disables OIDC, so a first deploy converges before ZITADEL exists."
  type        = string
  default     = ""
}

variable "oidc_client_secret" {
  description = "ZITADEL client secret for OpenBao's OIDC login"
  type        = string
  default     = ""
  sensitive   = true
}

variable "oidc_issuer" {
  description = "ZITADEL issuer URL. Empty disables OIDC."
  type        = string
  default     = ""
}
```

- [ ] **Step 6: Write `mounts.tf`**

```hcl
# The Stage 2 store of record (ADR-0033). Root namespace, deliberately: a policy
# binds only within the namespace it is created in, and the oidc/ mount, the
# identity groups and every policy live in root.
#
# Grammar: platform/<component>/<name>, one-to-one onto ADR-0023's dash names.
resource "vault_mount" "platform" {
  path        = "platform"
  type        = "kv-v2"
  description = "Platform component secrets; store of record (ADR-0033 Stage 2)"
}

# Separate from platform/ because External Secrets' vault provider takes ONE
# mount per store, so the split is what lets the two audiences carry different
# policies. Grammar: apps/<app>/<key>.
resource "vault_mount" "apps" {
  path        = "apps"
  type        = "kv-v2"
  description = "Application secrets, owned per app (ADR-0036)"
}
```

- [ ] **Step 7: Write `policies.tf`**

```hcl
# Platform administrators. Grants no secret path on its own; secrets-admin does.
resource "vault_policy" "admin" {
  name   = "admin"
  policy = file("${path.module}/policies/admin.hcl")
}

# PKI administration, templated so it tracks the mount it governs.
resource "vault_policy" "pki_admin" {
  name = "pki-admin"
  policy = templatefile("${path.module}/policies/pki-admin.hcl", {
    pki_mount = var.pki_mount_path
  })
}

# Full control of both Stage 2 mounts: the break-glass login and openbao-admin.
resource "vault_policy" "secrets_admin" {
  name   = "secrets-admin"
  policy = file("${path.module}/policies/secrets-admin.hcl")
}

# External Secrets' read-only identity over both mounts. Attached by NAME to
# the per-cluster JWT role in each cluster's configure stack -- a different
# state -- so the name must stay `external-secrets` in both places.
# scripts/validate-openbao-policies.sh enforces that pairing.
resource "vault_policy" "external_secrets" {
  name   = "external-secrets"
  policy = file("${path.module}/policies/external-secrets.hcl")
}
```

- [ ] **Step 8: Write `apps.tf`**

```hcl
# Per-app ownership of apps/ (ADR-0036). Gated on OIDC: without the OIDC mount
# there is no accessor to alias against.
locals {
  oidc_enabled = var.oidc_client_id != "" && var.oidc_issuer != "" ? 1 : 0

  # The gate is derived from the caller's OIDC secret payload, so it may arrive
  # marked sensitive -- and a sensitive value cannot be a for_each argument.
  # The keys come from a plain list; only the gate needs unwrapping. try()
  # covers the non-sensitive case, where nonsensitive() would error.
  oidc_on            = try(nonsensitive(local.oidc_enabled), local.oidc_enabled)
  secret_owning_apps = local.oidc_on == 1 ? var.secret_owning_apps : toset([])
}

resource "vault_policy" "app_prefix" {
  for_each = local.secret_owning_apps

  name = "app-${each.value}"
  policy = templatefile("${path.module}/policies/app-prefix.hcl", {
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

- [ ] **Step 9: Write `auth.tf`**

```hcl
# The break-glass login. It stays alongside OIDC on purpose (ADR-0034): ZITADEL's
# own credential lives in platform/zitadel/envvars, so an OIDC-only login would
# have no way back in when ZITADEL is down. It MUST carry secrets-admin, or it
# authenticates and then reads nothing it exists to recover.
resource "vault_auth_backend" "userpass" {
  type = "userpass"
  path = "userpass"
}

# Lands in state, as the root token already does. The caller publishes it to
# its own cloud's secret store from the `admin_password` output.
resource "random_password" "admin" {
  length           = 32
  special          = true
  override_special = "!#%*-_=+"
}

resource "vault_generic_endpoint" "admin_user" {
  path = "auth/${vault_auth_backend.userpass.path}/users/${var.admin_username}"
  # The password is never readable back, so a read would always look like drift.
  disable_read         = true
  disable_delete       = false
  ignore_absent_fields = true

  data_json = jsonencode({
    policies      = [vault_policy.admin.name, vault_policy.pki_admin.name, vault_policy.secrets_admin.name]
    password      = random_password.admin.result
    token_ttl     = 3600
    token_max_ttl = 28800
  })
}
```

- [ ] **Step 10: Write `oidc.tf`**

```hcl
# Human login through ZITADEL, authorised by project roles (ADR-0034). Everything
# is count-gated on the caller supplying a client id and an issuer, so a cluster
# whose ZITADEL is not bootstrapped yet applies cleanly with no OIDC method.
locals {
  # BOTH callbacks are required, and must match the `openbao` entry in
  # scripts/zitadel-oidc-clients.sh. The UI path embeds the mount path twice,
  # which is why `path` below is pinned to "oidc".
  oidc_redirect_uris = [
    "${var.openbao_address}/ui/vault/auth/oidc/oidc/callback",
    "http://localhost:8250/oidc/callback",
  ]
}

resource "vault_jwt_auth_backend" "oidc" {
  count = local.oidc_enabled

  path               = "oidc"
  type               = "oidc"
  description        = "ZITADEL OIDC for human operators (ADR-0034)"
  oidc_discovery_url = var.oidc_issuer
  oidc_client_id     = var.oidc_client_id
  oidc_client_secret = var.oidc_client_secret

  # A LITERAL, not a reference to the role below: referencing it would order the
  # role before the mount it lives in, and a fresh apply fails with
  # `no handler for route "auth/oidc/role/default"`.
  default_role = "default"

  # checkov:skip=CKV_SECRET_6:False positive on `token_type = "default-service"` -- an OpenBao token-type constant, not a base64 secret.
  tune {
    listing_visibility = "unauth"
    default_lease_ttl  = "1h"
    max_lease_ttl      = "8h"
    token_type         = "default-service"
  }
}

resource "vault_jwt_auth_backend_role" "oidc_default" {
  count = local.oidc_enabled

  backend   = vault_jwt_auth_backend.oidc[0].path
  role_name = "default"
  role_type = "oidc"

  allowed_redirect_uris = local.oidc_redirect_uris
  user_claim            = "email"
  # Without these ZITADEL issues a token with neither `email` nor `groups`, and
  # the login dies on `claim "email" not found in token`.
  oidc_scopes     = ["profile", "email", "groups"]
  groups_claim    = "groups"
  bound_audiences = [var.oidc_client_id]

  # Authorisation comes from the external group below, never from the role.
  token_policies = []
  token_ttl      = 3600
  token_max_ttl  = 28800
}

resource "vault_identity_group" "oidc_admin" {
  count = local.oidc_enabled

  name     = "openbao-admin"
  type     = "external"
  policies = [vault_policy.admin.name, vault_policy.pki_admin.name, vault_policy.secrets_admin.name]
}

resource "vault_identity_group_alias" "oidc_admin" {
  count = local.oidc_enabled

  # Must equal the value in the token's `groups` array, exactly.
  name           = var.admin_group_alias
  mount_accessor = vault_jwt_auth_backend.oidc[0].accessor
  canonical_id   = vault_identity_group.oidc_admin[0].id
}
```

- [ ] **Step 11: Write `outputs.tf`**

```hcl
output "admin_password" {
  description = "The break-glass userpass password. The caller publishes it to its own cloud's secret store."
  value       = random_password.admin.result
  sensitive   = true
}

output "platform_mount_path" {
  description = "Path of the platform/ kv-v2 mount"
  value       = vault_mount.platform.path
}

output "apps_mount_path" {
  description = "Path of the apps/ kv-v2 mount"
  value       = vault_mount.apps.path
}

output "policy_names" {
  description = "The four policies this module defines, by the names other states reference"
  value = [
    vault_policy.admin.name,
    vault_policy.pki_admin.name,
    vault_policy.secrets_admin.name,
    vault_policy.external_secrets.name,
  ]
}

output "oidc_enabled" {
  description = "1 when the OIDC login is configured, 0 otherwise"
  value       = local.oidc_on
}
```

- [ ] **Step 12: Run the tests and watch them pass**

```bash
tofu -chdir=opentofu/shared/modules/openbao-store-of-record init -backend=false
tofu -chdir=opentofu/shared/modules/openbao-store-of-record validate
tofu -chdir=opentofu/shared/modules/openbao-store-of-record test
tofu fmt -check -recursive opentofu/shared/modules/openbao-store-of-record
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml opentofu/shared/modules/openbao-store-of-record
```

Expected:
- `validate` reports `Success!`.
- `tofu test` reports `2 passed, 0 failed`.
- `fmt -check` prints nothing.
- trivy exits 0.

- [ ] **Step 13: Commit**

```bash
git add opentofu/shared/modules/openbao-store-of-record
git commit -F <msgfile> -- opentofu/shared/modules/openbao-store-of-record
```

Message: `feat(openbao): the Stage 2 store of record as a shared module, tested offline`

Do not commit `.terraform/` or `.terraform.lock.hcl`; both are gitignored. Check with `git status --short`.

---

### Task 2: GCP's management stack uses the module

**Files:**
- Create: `opentofu/gcp/openbao/management/store-of-record.tf`
- Modify: `opentofu/gcp/openbao/management/variables.tf` (append)
- Modify: `opentofu/gcp/openbao/management/variables.tfvars` (append)
- Modify: `opentofu/gcp/openbao/management/outputs.tf` (append)
- Modify: `opentofu/gcp/openbao/management/versions.tf` (add random)
- Modify: the comment blocks at the top of `opentofu/gcp/openbao/management/policies.tf` and `opentofu/gcp/openbao/management/auth.tf`

**Interfaces:**
- Consumes: the module from Task 1: its inputs, and its `admin_password` output.
- Produces: in GCP's OpenBao, the policies `admin`, `pki-admin`, `secrets-admin` and `external-secrets`. The last one is what `jwt/gcp-0`'s `external-secrets` role names. It also produces the Secret Manager entry `openbao-priv-gcp-admin-credentials`, and the output `admin_credentials_secret_name`.

- [ ] **Step 1: Write `store-of-record.tf`**

```hcl
# Stage 2 on GCP (docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-design.md,
# ADR-0037): the same mounts, policies and logins AWS defines, from the shared
# module. Until this existed, jwt/gcp-0's external-secrets role named a policy
# no GCP OpenBao ever had, and the 14 OpenBao-backed ExternalSecrets on gcp-0
# authenticated and then read nothing.

# OIDC is gated on the `openbao-oidc` entry EXISTING, not on the variable
# being set. Reading a version of a missing secret is a hard error; listing
# first turns "ZITADEL not bootstrapped yet" into "OIDC off", so a first deploy
# converges and the second apply after zitadel-oidc-clients.sh picks it up --
# the same two-pass shape as opentofu/aws/openbao/management/oidc.tf.
data "google_secret_manager_secrets" "project" {
  project = var.project_id
}

locals {
  oidc_secret_present = var.openbao_oidc_secret_id != "" && contains(
    [for s in data.google_secret_manager_secrets.project.secrets : s.secret_id],
    var.openbao_oidc_secret_id
  )
}

data "google_secret_manager_secret_version" "openbao_oidc" {
  count   = local.oidc_secret_present ? 1 : 0
  secret  = var.openbao_oidc_secret_id
  project = var.project_id
}

locals {
  oidc_raw           = try(jsondecode(data.google_secret_manager_secret_version.openbao_oidc[0].secret_data), {})
  oidc_client_id     = try(local.oidc_raw["client_id"], "")
  oidc_client_secret = try(local.oidc_raw["client_secret"], "")
  # Falls back to the `endpoint` the registration script stores alongside the
  # credentials, so the IdP hostname is not configured twice.
  oidc_issuer = var.openbao_oidc_issuer != "" ? var.openbao_oidc_issuer : try(local.oidc_raw["endpoint"], "")
}

module "store_of_record" {
  source = "../../../shared/modules/openbao-store-of-record"

  pki_mount_path     = vault_mount.pki.path
  openbao_address    = local.openbao_address
  admin_username     = var.admin_username
  admin_group_alias  = "platform"
  secret_owning_apps = var.secret_owning_apps
  oidc_client_id     = local.oidc_client_id
  oidc_client_secret = local.oidc_client_secret
  oidc_issuer        = local.oidc_issuer
}

# Published so an operator can retrieve the break-glass password -- the GCP
# twin of opentofu/aws/openbao/management/secrets.tf. Google-managed key,
# matching the AVD-AWS-0098 decision recorded in .trivyignore.yaml.
resource "google_secret_manager_secret" "admin_credentials" {
  project   = var.project_id
  secret_id = var.admin_credentials_secret_name

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "admin_credentials" {
  secret = google_secret_manager_secret.admin_credentials.id
  secret_data = jsonencode({
    username = var.admin_username
    password = module.store_of_record.admin_password
    address  = local.openbao_address
  })
}
```

- [ ] **Step 2: Append to `variables.tf`**

```hcl
variable "admin_username" {
  description = "Username of the userpass break-glass login, carrying admin, pki-admin and secrets-admin"
  type        = string
  default     = "admin"
}

variable "admin_credentials_secret_name" {
  description = "GCP Secret Manager entry this stack publishes the break-glass credentials to, as {username, password, address}"
  type        = string
  default     = "openbao-priv-gcp-admin-credentials"
}

variable "openbao_oidc_secret_id" {
  description = "GCP Secret Manager entry holding {client_id, client_secret, endpoint} for OpenBao's ZITADEL OIDC client, written by scripts/zitadel-oidc-clients.sh. An entry that does not exist yet disables OIDC rather than failing."
  type        = string
  default     = "openbao-oidc"
}

variable "openbao_oidc_issuer" {
  description = "ZITADEL issuer URL. Defaults to the `endpoint` field of openbao_oidc_secret_id."
  type        = string
  default     = ""
}

variable "secret_owning_apps" {
  description = "Apps that own a prefix under apps/ (ADR-0036). Each gets a policy, an external identity group and an alias once OIDC is configured."
  type        = set(string)
  default     = []
}
```

- [ ] **Step 3: Append to `variables.tfvars`**

```hcl
# The same apps as AWS (opentofu/aws/openbao/management/variables.tfvars), so a
# persona behaves identically on either cloud's OpenBao.
secret_owning_apps = ["app-wizard", "image-gallery"]
```

- [ ] **Step 4: Append to `outputs.tf`**

```hcl
output "admin_credentials_secret_name" {
  description = "GCP Secret Manager entry holding the break-glass userpass credentials"
  value       = google_secret_manager_secret.admin_credentials.secret_id
}
```

- [ ] **Step 5: Add random to `versions.tf`**

Inside `required_providers`, after the `vault` block, add:

```hcl
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
```

- [ ] **Step 6: Correct the two comments that now state untruths**

In `policies.tf`, replace the first comment paragraph, which begins `# Two policies now. The AWS stack also carries admin, pki-admin and app`, with:

```hcl
# The cert-manager and snapshot policies below are GCP's own. The Stage 2
# policies -- admin, pki-admin, secrets-admin, external-secrets and the per-app
# ones -- come from the shared module in store-of-record.tf, the same set AWS
# defines inline.
```

In `auth.tf`, replace the last two lines, `# No human auth method on GCP yet; operators use the root token from` and `# openbao-priv-gcp-root-token, as documented.`, with:

```hcl
# Human logins -- the userpass break-glass and the ZITADEL OIDC method -- come
# from the shared module (store-of-record.tf). The break-glass password is
# published to openbao-priv-gcp-admin-credentials.
```

- [ ] **Step 7: Validate offline**

```bash
tofu -chdir=opentofu/gcp/openbao/management init -backend=false
tofu -chdir=opentofu/gcp/openbao/management validate
tofu fmt -check -recursive opentofu/gcp/openbao/management
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml opentofu/gcp/openbao/management
```

Expected: `validate` reports `Success!`, `fmt -check` prints nothing, and trivy exits 0.

If `validate` reports that `secret_id` is not an attribute of the `secrets` list elements, use the always-present `name` attribute (`projects/<n>/secrets/<id>`) instead:

```hcl
[for s in data.google_secret_manager_secrets.project.secrets : element(split("/", s.name), 3)]
```

If trivy or Checkov flags the secret for lacking a customer-managed key, add this line as the first line inside the `google_secret_manager_secret "admin_credentials"` block:

```hcl
  #checkov:skip=CKV_GCP_CMEK:Google-managed key, matching the AVD-AWS-0098 decision recorded in .trivyignore.yaml; the platform is ephemeral.
```

For a trivy finding, add the finding's ID to `.trivyignore.yaml` with the same reason, in the same style as the existing AVD-AWS-0098 entry. Use the exact ID the tool printed.

- [ ] **Step 8: Commit**

```bash
git add opentofu/gcp/openbao/management/store-of-record.tf
git commit -F <msgfile> -- opentofu/gcp/openbao/management
```

Message: `feat(openbao): GCP's OpenBao gets the Stage 2 mounts, policies and logins`

The commit must include the `.trivyignore.yaml` change if Step 7 needed one.

---

### Task 3: The policy-parity check, proven on the tree it would have caught

**Files:**
- Create: `scripts/validate-openbao-policies.sh`
- Create: `scripts/test-validate-openbao-policies.sh`
- Modify: `.github/workflows/ci.yaml`, in the `links` job after the step `Run identity provider topology tests`

**Interfaces:**
- Consumes: the file layout. Roles are in `opentofu/<cloud>/*/configure/openbao.tf` (`policies = [...]`). Policies are defined in `opentofu/<cloud>/openbao/management/*.tf` (`resource "vault_policy"` with `name = "<literal>"`) and in any module those files call with a relative `source`.
- Produces: `scripts/validate-openbao-policies.sh [ROOT_DIR]`. It exits 0 with the line `==> OpenBao policy parity: every policy a JWT role names is defined (N cloud(s)).`. Otherwise it prints one `FAIL:` line per gap and exits 1.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-validate-openbao-policies.sh`:

```bash
#!/usr/bin/env bash
#
# Fixture-driven tests for validate-openbao-policies.sh.
#
# The state it exists to catch -- a JWT role naming a policy its OpenBao never
# defines -- shipped silently when Stage 2 landed (gcp-0's external-secrets
# role). Reproducing that live costs a GCP deploy, so it is tested against
# synthetic trees instead.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VALIDATOR="${SCRIPT_DIR}/validate-openbao-policies.sh"
failures=0

# role_policies <root> <cloud> <quoted,list> -- a configure stack naming policies
role_policies() {
  mkdir -p "$1/opentofu/$2/k8s/configure"
  cat >"$1/opentofu/$2/k8s/configure/openbao.tf" <<EOF
locals {
  openbao_roles = {
    external-secrets = {
      policies = [$3]
    }
  }
}
EOF
}

# define_policy <dir> <name> -- a vault_policy with a literal name
define_policy() {
  mkdir -p "$1"
  cat >>"$1/policies.tf" <<EOF
resource "vault_policy" "p_${2//-/_}" {
  name   = "$2"
  policy = "{}"
}
EOF
}

# expect <label> <exit-code> <root> [substring]
expect() {
  local label="$1" want="$2" root="$3" needle="${4:-}" out rc=0
  out="$("$VALIDATOR" "$root" 2>&1)" || rc=$?
  if [ "$rc" != "$want" ]; then
    echo "FAIL ${label}: exit ${rc}, expected ${want}"; echo "$out" | sed 's/^/       /'
    failures=$((failures + 1)); return
  fi
  if [ -n "$needle" ] && ! grep -qF -- "$needle" <<<"$out"; then
    echo "FAIL ${label}: output lacks: ${needle}"; echo "$out" | sed 's/^/       /'
    failures=$((failures + 1)); return
  fi
  echo "ok   ${label}"
}

t=$(mktemp -d); trap 'rm -rf "$t"' EXIT

r="$t/defined"; role_policies "$r" aws '"default", "external-secrets"'
define_policy "$r/opentofu/aws/openbao/management" external-secrets
expect "a defined policy passes" 0 "$r"

r="$t/missing"; role_policies "$r" gcp '"default", "external-secrets"'
define_policy "$r/opentofu/gcp/openbao/management" cert-manager
expect "the Stage 2 gap fails, naming cloud and policy" 1 "$r" 'gcp: a JWT role names policy "external-secrets"'

r="$t/module"; role_policies "$r" gcp '"external-secrets"'
mkdir -p "$r/opentofu/gcp/openbao/management"
cat >"$r/opentofu/gcp/openbao/management/store.tf" <<'EOF'
module "store" {
  source = "../../../shared/modules/store"
}
EOF
define_policy "$r/opentofu/shared/modules/store" external-secrets
expect "a policy defined through a called module passes" 0 "$r"

r="$t/default"; role_policies "$r" aws '"default"'
mkdir -p "$r/opentofu/aws/openbao/management"
expect "the built-in default policy is never required" 0 "$r"

r="$t/templated"; role_policies "$r" aws '"app-x"'
mkdir -p "$r/opentofu/aws/openbao/management"
cat >"$r/opentofu/aws/openbao/management/apps.tf" <<'EOF'
resource "vault_policy" "app" {
  name   = "app-${each.value}"
  policy = "{}"
}
EOF
expect "a templated name does not count as defining a literal one" 1 "$r" 'policy "app-x"'

r="$t/nomgmt"; role_policies "$r" gcp '"external-secrets"'
expect "a cloud with roles but no management stack fails" 1 "$r" "no opentofu/gcp/openbao/management"

r="$t/empty"; mkdir -p "$r/opentofu"
expect "a tree with no configure stack at all fails" 1 "$r" "no opentofu/<cloud>/*/configure/openbao.tf"

expect "the repository itself passes" 0 "$(cd "${SCRIPT_DIR}/.." && pwd)"

if [ "$failures" -ne 0 ]; then echo "==> ${failures} failure(s)"; exit 1; fi
echo "==> all checks passed"
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
chmod +x scripts/test-validate-openbao-policies.sh
bash scripts/test-validate-openbao-policies.sh
```

Expected: FAIL. Every case reports a non-zero exit, because `validate-openbao-policies.sh` does not exist yet.

- [ ] **Step 3: Write the validator**

Create `scripts/validate-openbao-policies.sh`:

```bash
#!/usr/bin/env bash
#
# Every policy a cluster's OpenBao JWT roles name must be DEFINED by that cloud's
# OpenBao management stack -- directly, or through a module it calls.
#
# WHY THIS EXISTS
#
# A JWT role references its policies BY NAME, from a different state: the roles
# live in opentofu/<cloud>/<k8s>/configure/openbao.tf, the policies in
# opentofu/<cloud>/openbao/management. OpenBao accepts a role naming a policy
# that does not exist, and the login succeeds -- it just grants nothing. When
# Stage 2 shipped (2026-09-10), jwt/gcp-0's external-secrets role named
# `external-secrets`, which only the AWS management stack defined, so all 14
# OpenBao-backed ExternalSecrets on gcp-0 authenticated and read nothing. CI
# rendered every manifest and stayed green; nothing tied the two states.
#
# This reads committed HCL, not a live OpenBao, so it answers "would this
# configuration leave a role pointing at nothing?", not "does it right now?".
# Templated policy names (app-${each.value}) are not literal names and never
# satisfy a role; the built-in `default` policy is never required.
#
# Usage: validate-openbao-policies.sh [ROOT_DIR]
set -euo pipefail

ROOT="${1:-$(git rev-parse --show-toplevel)}"

exec python3 - "$ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
QUOTED = re.compile(r'"([^"$]+)"')
fails = []

def referenced(path):
    names = set()
    for m in re.finditer(r'policies\s*=\s*\[([^\]]*)\]', path.read_text()):
        names.update(QUOTED.findall(m.group(1)))
    names.discard("default")
    return names

def literal_policy_names(directory):
    names = set()
    for tf in sorted(directory.glob("*.tf")):
        for block in re.finditer(r'resource\s+"vault_policy"\s+"[^"]+"\s*\{(.*?)\n\}', tf.read_text(), re.S):
            n = re.search(r'^\s*name\s*=\s*"([^"$]+)"\s*$', block.group(1), re.M)
            if n:
                names.add(n.group(1))
    return names

def called_module_dirs(directory):
    dirs = []
    for tf in sorted(directory.glob("*.tf")):
        for block in re.finditer(r'module\s+"[^"]+"\s*\{(.*?)\n\}', tf.read_text(), re.S):
            s = re.search(r'^\s*source\s*=\s*"(\.[^"]+)"', block.group(1), re.M)
            if s:
                dirs.append((directory / s.group(1)).resolve())
    return dirs

opentofu = root / "opentofu"
clouds = sorted(p.name for p in opentofu.iterdir() if p.is_dir() and p.name != "shared") if opentofu.is_dir() else []
checked = 0
for cloud in clouds:
    configs = sorted((opentofu / cloud).glob("*/configure/openbao.tf"))
    if not configs:
        continue
    mgmt = opentofu / cloud / "openbao" / "management"
    if not mgmt.is_dir():
        fails.append(f"{cloud}: {configs[0].relative_to(root)} names OpenBao policies, but there is no opentofu/{cloud}/openbao/management")
        continue
    wanted = set().union(*(referenced(c) for c in configs))
    defined = literal_policy_names(mgmt)
    for d in called_module_dirs(mgmt):
        if d.is_dir():
            defined |= literal_policy_names(d)
    checked += 1
    for name in sorted(wanted - defined):
        fails.append(f'{cloud}: a JWT role names policy "{name}", but opentofu/{cloud}/openbao/management does not define it (directly or through a module it calls)')

if checked == 0 and not fails:
    fails.append("no opentofu/<cloud>/*/configure/openbao.tf found -- nothing to check, which is itself wrong")

for f in fails:
    print(f"FAIL: {f}")
if fails:
    print(f"==> OpenBao policy parity: {len(fails)} problem(s). A role naming an undefined policy logs in and reads nothing.")
    sys.exit(1)
print(f"==> OpenBao policy parity: every policy a JWT role names is defined ({checked} cloud(s)).")
PY
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
chmod +x scripts/validate-openbao-policies.sh
bash scripts/test-validate-openbao-policies.sh
./scripts/validate-openbao-policies.sh
shellcheck -x -S warning scripts/validate-openbao-policies.sh scripts/test-validate-openbao-policies.sh
```

Expected:
- The test script ends with `==> all checks passed` (8 ok lines).
- The validator prints `==> OpenBao policy parity: every policy a JWT role names is defined (2 cloud(s)).`
- shellcheck prints nothing.

- [ ] **Step 5: Prove it catches the real gap on the pre-port tree**

```bash
base=$(mktemp -d)
git archive 5ee550ed | tar -x -C "$base"
./scripts/validate-openbao-policies.sh "$base"; echo "exit=$?"
rm -rf "$base"
```

`5ee550ed` is this branch's spec commit, from before Task 2.

Expected: `FAIL: gcp: a JWT role names policy "external-secrets", but opentofu/gcp/openbao/management does not define it …`, then `exit=1`. Paste this output into the Task 3 report: it is the success criterion "fails on the tree before this work and passes after it".

- [ ] **Step 6: Wire it into CI**

In `.github/workflows/ci.yaml`, directly after the step `- name: Run identity provider topology tests` / `run: ./scripts/test-validate-idp-topology.sh`, insert:

```yaml

      # OpenBao policy parity: every policy a JWT role names must be defined by
      # that cloud's management stack, or a module it calls. The gap it closes
      # shipped silently with Stage 2 -- jwt/gcp-0's external-secrets role named a
      # policy GCP's OpenBao never had. Named explicitly, like the IdP suites
      # above: stdlib python3 only, no pyyaml.
      - name: Check OpenBao policy parity
        run: ./scripts/validate-openbao-policies.sh

      - name: Run OpenBao policy parity tests
        run: ./scripts/test-validate-openbao-policies.sh
```

- [ ] **Step 7: Commit**

```bash
git add scripts/validate-openbao-policies.sh scripts/test-validate-openbao-policies.sh
git commit -F <msgfile> -- scripts/validate-openbao-policies.sh scripts/test-validate-openbao-policies.sh .github/workflows/ci.yaml
```

Message: `feat(ci): a JWT role may only name a policy its OpenBao defines`

---

### Task 4: A new GCP lineage can boot beside the AWS mirror

**Files:**
- Modify: `scripts/openbao-config.sh`:
  - add `new_lineage_verdict()` directly after `latest_snapshot_sealed()`;
  - add the switch block in `rehydrate_openbao()`;
  - add to the usage text.
- Create: `scripts/test-openbao-new-lineage.sh`
- Modify: `.github/workflows/ci.yaml`, the named shell-test loop in the `shellcheck` job, and its comment list

**Interfaces:**
- Consumes: from `rehydrate_openbao()`, the existing `latest`, `node_seal`, `snap_seal` and `latest_snapshot_sealed "$node_seal"`, and the existing `init_openbao`. From `usage()`, the existing `ROOT_TOKEN_SECRET_NAME` and `RECOVERY_KEYS_SECRET_NAME`.
- Produces: the environment variable `OPENBAO_NEW_LINEAGE=true`. It also produces the pure function `new_lineage_verdict <node_seal> <snap_seal> <own_seal_latest> <snapshot_key>`, which prints exactly one of `proceed`, `refuse-named-key`, `refuse-same-seal` or `refuse-own-seal-exists`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-openbao-new-lineage.sh`:

```bash
#!/usr/bin/env bash
#
# May OPENBAO_NEW_LINEAGE=true start a NEW lineage? And is the switch wired where
# it has to be?
#
# WHY THIS MATTERS. GCP's snapshot bucket also holds the AWS mirror, whose every
# object is AWS-sealed. A gcpckms node that finds no object under its own seal
# has no path in: rehydrate refuses the foreign seal and -- with
# OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true -- refuses a plain init, correctly,
# because that overwrites a lineage's stored keys on a guess. The switch is the
# operator saying "start this lineage" out loud. Getting its rule wrong in the
# permissive direction discards a lineage's history; in the strict direction a
# GCP-only platform cannot boot at all.
#
# new_lineage_verdict() is lifted out of the script rather than restated, so this
# tests the code that ships. Everything around it in rehydrate needs a live node.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}
contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: %q not found\n' "$1" "$3"; fail=1; fi
}
for _h in check contains; do
    declare -F "$_h" >/dev/null || { echo "harness incomplete: $_h() is not defined" >&2; exit 2; }
done

SRC="${OPENBAO_CONFIG_SCRIPT:-$HERE/openbao-config.sh}"
body="$(sed -n '/^new_lineage_verdict() {/,/^}/p' "$SRC")"
[ -n "$body" ] || { echo "could not extract new_lineage_verdict() from $SRC" >&2; exit 1; }
eval "$body"

echo "== the case the switch exists for: a GCP node beside an AWS-only mirror"
check "proceeds" "proceed" "$(new_lineage_verdict gcpckms awskms "" "")"

echo "== an object under this node's seal exists: restore it, never start over"
check "refuses" "refuse-own-seal-exists" \
    "$(new_lineage_verdict gcpckms awskms "2026-09-01T000000Z-gcpckms.snap" "")"

echo "== the newest object is already restorable here"
check "refuses" "refuse-same-seal" \
    "$(new_lineage_verdict gcpckms gcpckms "2026-09-01T000000Z-gcpckms.snap" "")"

echo "== a legacy object with no seal segment, and nothing under this seal"
check "proceeds" "proceed" "$(new_lineage_verdict gcpckms "" "" "")"

echo "== a named object contradicts a new lineage"
check "refuses" "refuse-named-key" \
    "$(new_lineage_verdict gcpckms awskms "" "2026-09-05T092947Z-awskms.snap")"

echo "== wiring inside rehydrate_openbao"
fn="$(sed -n '/^rehydrate_openbao() {/,/^}/p' "$SRC")"
contains "reads the switch" "$fn" 'OPENBAO_NEW_LINEAGE:-false'
contains "asks the verdict with the node's own-seal listing" "$fn" \
    'new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest"'
arm="$(printf '%s\n' "$fn" | sed -n '/^[[:space:]]*proceed)/,/;;/p')"
contains "the proceed arm initialises" "$arm" 'init_openbao'
for v in refuse-named-key refuse-same-seal refuse-own-seal-exists; do
    varm="$(printf '%s\n' "$fn" | sed -n "/^[[:space:]]*${v})/,/;;/p")"
    contains "the ${v} arm exits non-zero" "$varm" 'exit 1'
done
switch_line=$(printf '%s\n' "$fn" | grep -nF 'OPENBAO_NEW_LINEAGE:-false' | head -1 | cut -d: -f1)
gate_line=$(printf '%s\n' "$fn" | grep -nF '"${OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL:-false}" != "true"' | head -1 | cut -d: -f1)
if [ -n "$switch_line" ] && [ -n "$gate_line" ] && [ "$switch_line" -lt "$gate_line" ]; then
    printf '  ok   the switch is consulted before the foreign-seal refusal\n'
else
    printf '  FAIL the switch must be consulted before the foreign-seal refusal (switch=%s gate=%s)\n' "$switch_line" "$gate_line"; fail=1
fi

echo "== documented"
usage_fn="$(sed -n '/^usage() {/,/^}/p' "$SRC")"
contains "usage names the switch" "$usage_fn" 'OPENBAO_NEW_LINEAGE=true'

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
chmod +x scripts/test-openbao-new-lineage.sh
bash scripts/test-openbao-new-lineage.sh; echo "exit=$?"
```

Expected: `could not extract new_lineage_verdict() from …/openbao-config.sh`, then `exit=1`.

- [ ] **Step 3: Add `new_lineage_verdict()`**

In `scripts/openbao-config.sh`, insert this directly after the closing `}` of `latest_snapshot_sealed()`, before the comment block that introduces `verify_pki_present()`:

```bash

# May OPENBAO_NEW_LINEAGE=true start a NEW lineage on this node? A pure decision,
# lifted into scripts/test-openbao-new-lineage.sh, so the rule is tested without a
# live node.
#
#   $1 this node's seal type     $2 the newest object's seal segment (may be empty)
#   $3 the newest object carrying $1's seal, or empty when none does
#   $4 OPENBAO_SNAPSHOT_KEY, empty when unset
#
# Prints exactly one verdict:
#   proceed                 nothing in the bucket carries this node's seal: init
#   refuse-named-key        a named restore was asked for; a new lineage contradicts it
#   refuse-same-seal        the newest object IS restorable here; restore it instead
#   refuse-own-seal-exists  an older object carries this seal -- this lineage's own
#                           history; restore it with OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL
new_lineage_verdict() {
    local node_seal=$1 snap_seal=$2 own_latest=$3 snapshot_key=$4
    if [ -n "$snapshot_key" ]; then printf 'refuse-named-key'; return 0; fi
    if [ "$snap_seal" = "$node_seal" ]; then printf 'refuse-same-seal'; return 0; fi
    if [ -n "$own_latest" ]; then printf 'refuse-own-seal-exists'; return 0; fi
    printf 'proceed'
}
```

- [ ] **Step 4: Add the switch at the seal gate**

In `rehydrate_openbao()`, find the line:

```bash
    log_message "INFO" "This node's seal is '${node_seal}'; ${latest} carries '${snap_seal:-none}'."
```

Insert this block directly after it, before `    if [ "$snap_seal" != "$node_seal" ]; then`:

```bash

    # THE NEW-LINEAGE SWITCH (docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-design.md).
    # A GCP-sealed node whose bucket holds only AWS-mirrored objects has no path
    # in: the gate below refuses the foreign seal, and with the skip it refuses a
    # plain init -- correctly, since that overwrites a lineage's stored keys on a
    # guess. OPENBAO_NEW_LINEAGE=true is the operator saying "start this lineage"
    # out loud, and it is honoured ONLY when nothing in the bucket carries this
    # node's seal. The moved-aside (rc 2) and could-not-list refusals above have
    # already exited before this point, so the switch can never bypass them.
    if [ "${OPENBAO_NEW_LINEAGE:-false}" = "true" ]; then
        local own_latest verdict
        if ! own_latest=$(latest_snapshot_sealed "$node_seal"); then
            log_message "ERROR" "OPENBAO_NEW_LINEAGE=true, but ${SNAPSHOT_BUCKET} cannot be listed for '${node_seal}' objects."
            log_message "ERROR" "A new lineage is only safe once the bucket is PROVEN to hold none. Nothing has changed yet."
            exit 1
        fi
        verdict=$(new_lineage_verdict "$node_seal" "$snap_seal" "$own_latest" "${OPENBAO_SNAPSHOT_KEY:-}")
        case "$verdict" in
            proceed)
                log_message "WARN" "OPENBAO_NEW_LINEAGE=true -- STARTING A NEW '${node_seal}' LINEAGE."
                log_message "WARN" "  newest object : ${latest} (sealed '${snap_seal:-none}') -- NOT restored"
                log_message "WARN" "  '${node_seal}' objects in ${SNAPSHOT_BUCKET}: none"
                log_message "WARN" "  ${ROOT_TOKEN_SECRET_NAME} and ${RECOVERY_KEYS_SECRET_NAME} are REPLACED with this node's new keys."
                init_openbao
                return 0 ;;
            refuse-named-key)
                log_message "ERROR" "OPENBAO_NEW_LINEAGE=true and OPENBAO_SNAPSHOT_KEY=${OPENBAO_SNAPSHOT_KEY:-} contradict each other:"
                log_message "ERROR" "one asks for a new lineage, the other for a named restore. Unset one. Nothing has changed yet."
                exit 1 ;;
            refuse-same-seal)
                log_message "ERROR" "OPENBAO_NEW_LINEAGE=true, but the newest object ${latest} carries this node's seal"
                log_message "ERROR" "'${node_seal}' and can be restored. A new lineage would discard it. Unset"
                log_message "ERROR" "OPENBAO_NEW_LINEAGE and re-run. Nothing has changed yet."
                exit 1 ;;
            refuse-own-seal-exists)
                log_message "ERROR" "OPENBAO_NEW_LINEAGE=true, but ${own_latest} carries this node's seal '${node_seal}':"
                log_message "ERROR" "this lineage's own history. Restore it instead -- unset OPENBAO_NEW_LINEAGE and re-run"
                log_message "ERROR" "with OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true. Nothing has changed yet."
                exit 1 ;;
            *)
                log_message "ERROR" "new_lineage_verdict returned '${verdict}' -- refusing. Nothing has changed yet."
                exit 1 ;;
        esac
    fi
```

- [ ] **Step 5: Document the switch in `usage()`**

In `usage()`, directly after the line `    echo "                                             foreign-sealed objects are not coming back."`, insert:

```bash
    echo "  OPENBAO_NEW_LINEAGE=true                  Let 'rehydrate' start a NEW lineage (a plain init) on a"
    echo "                                             node whose seal NO object in the bucket carries -- the"
    echo "                                             first boot of a GCP-only lineage beside the AWS mirror."
    echo "                                             Refused whenever an object under this node's seal exists,"
    echo "                                             and together with OPENBAO_SNAPSHOT_KEY. REPLACES the"
    echo "                                             stored root token and recovery keys."
```

- [ ] **Step 6: Run the tests and watch them pass**

```bash
bash scripts/test-openbao-new-lineage.sh
bash scripts/test-openbao-snapshot-key.sh
bash scripts/test-openbao-root-token-probe.sh
bash scripts/test-openbao-pki-verify.sh
shellcheck -x -S warning scripts/openbao-config.sh scripts/test-openbao-new-lineage.sh
```

Expected:
- The first command ends with `all checks passed`: 5 verdict checks, 7 wiring checks and 1 documentation check.
- The three existing suites still pass, so the default path is untouched.
- shellcheck prints nothing.

- [ ] **Step 7: Run it in CI**

In `.github/workflows/ci.yaml`, in the `shellcheck` job:

1. Directly above the line beginning `          for t in scripts/test-zitadel-*.sh`, add this comment. It follows the style of the numbered comments above that line:

   ```yaml
      # scripts/test-openbao-new-lineage.sh is the eighth named addition, and pins
      # the rule that lets a new GCP-sealed lineage boot beside the AWS mirror
      # (OPENBAO_NEW_LINEAGE) -- and that it never overrides a restorable lineage.
   ```

2. On the `for t in …; do` line, append ` scripts/test-openbao-new-lineage.sh` after `scripts/test-access-matrix-sync.sh`.

- [ ] **Step 8: Commit**

```bash
git add scripts/test-openbao-new-lineage.sh
git commit -F <msgfile> -- scripts/openbao-config.sh scripts/test-openbao-new-lineage.sh .github/workflows/ci.yaml
```

Message: `feat(openbao): an explicit switch lets a new lineage boot beside a foreign-sealed mirror`

---

### Task 5: `secret-store.sh migrate --keys`, for a cluster already repointed at OpenBao

**Files:**
- Modify: `scripts/secret-store.sh`:
  - the `migrate` usage lines;
  - the `KEYS` variable;
  - the `--keys` flag;
  - a new `migrate_keys()`;
  - `cmd_migrate`'s input.
- Create: `scripts/test-secret-store-migrate-keys.sh`
- Modify: `.github/workflows/ci.yaml`, the same named loop and comment list as Task 4

**Interfaces:**
- Consumes: the existing `migrate_source_keys()` (keys from the cluster's ExternalSecrets) and `bao_target_for()`.
- Produces: `secret-store.sh migrate --cloud gcp --project <id> --keys "<k1,k2 …>" [--apply]`, and `migrate_keys()`. The function prints one key per line, sorted and de-duplicated: the explicit list when `KEYS` is set, otherwise `migrate_source_keys`.

- [ ] **Step 1: Write the failing test**

Create `scripts/test-secret-store-migrate-keys.sh`:

```bash
#!/usr/bin/env bash
#
# Which source keys does `secret-store.sh migrate` walk?
#
# WHY. Normally the keys this cluster's ExternalSecrets ask for. But once the
# shared ExternalSecrets were repointed at OpenBao (Stage 2), gcp-0's ask for
# OpenBao paths such as `zitadel/envvars`, which bao_target_for does not map --
# so a cluster-derived walk skips every key and migrates nothing, while
# reporting success. --keys names the managed-store keys explicitly.
#
# migrate_keys() is lifted out of the script, so this tests the code that ships.
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
check() {
    if [ "$2" = "$3" ]; then printf '  ok   %s\n' "$1"
    else printf '  FAIL %s: expected %q got %q\n' "$1" "$2" "$3"; fail=1; fi
}

body="$(sed -n '/^migrate_keys() {/,/^}/p' scripts/secret-store.sh)"
[ -n "$body" ] || { echo "could not extract migrate_keys() from scripts/secret-store.sh" >&2; exit 1; }
eval "$body"
migrate_source_keys() { printf 'from-the-cluster\n'; }

KEYS=""
check "no --keys: the cluster's ExternalSecrets decide" "from-the-cluster" "$(migrate_keys)"
KEYS="zitadel-envvars,harbor-oidc"
check "commas separate, output sorted" $'harbor-oidc\nzitadel-envvars' "$(migrate_keys)"
KEYS="zitadel-envvars harbor-oidc"
check "spaces separate" $'harbor-oidc\nzitadel-envvars' "$(migrate_keys)"
KEYS="a,, b ,a"
check "blanks dropped, duplicates collapsed" $'a\nb' "$(migrate_keys)"

fn="$(sed -n '/^cmd_migrate() {/,/^}/p' scripts/secret-store.sh)"
if printf '%s' "$fn" | grep -qF 'done <<<"$(migrate_keys)"'; then
    printf '  ok   cmd_migrate walks migrate_keys\n'
else
    printf '  FAIL cmd_migrate must read its keys from migrate_keys\n'; fail=1
fi
if grep -qE '^[[:space:]]+--keys\)[[:space:]]+KEYS="\$2"; shift 2 ;;' scripts/secret-store.sh; then
    printf '  ok   --keys is parsed\n'
else
    printf '  FAIL --keys is not parsed\n'; fail=1
fi

echo
if [ "$fail" -eq 0 ]; then echo "all checks passed"; else echo "FAILURES"; fi
exit "$fail"
```

- [ ] **Step 2: Run the test and watch it fail**

```bash
chmod +x scripts/test-secret-store-migrate-keys.sh
bash scripts/test-secret-store-migrate-keys.sh; echo "exit=$?"
```

Expected: `could not extract migrate_keys() from scripts/secret-store.sh`, then `exit=1`.

- [ ] **Step 3: Implement**

In `scripts/secret-store.sh`:

(a) In the header comment, directly after the paragraph that ends `writes a platform secret into an app's prefix, which is a privilege` / `boundary rather than a cosmetic mistake.`, add:

```bash
#
#       --keys K1,K2,...  walks exactly these managed-store keys instead of the
#       ones the cluster's ExternalSecrets name. Needed once those ExternalSecrets
#       already point at OpenBao: they then name OpenBao paths, which the mapping
#       does not know, and a cluster-derived walk copies nothing.
```

(b) Directly after `APPLY="false"`, add:

```bash
KEYS=""  # migrate: explicit managed-store keys; empty = derive from the cluster
```

(c) In the `case "$1" in` flag loop, directly after `        --apply)   APPLY="true"; shift ;;`, add:

```bash
        --keys)    KEYS="$2"; shift 2 ;;
```

(d) Directly above `cmd_migrate() {`, add:

```bash
# The source keys `migrate` walks: an explicit --keys list when given, else the
# keys this cluster's ExternalSecrets ask for. Commas or whitespace separate the
# list; blanks and duplicates are dropped.
migrate_keys() {
    if [ -n "$KEYS" ]; then
        printf '%s\n' "$KEYS" | tr ', ' '\n\n' | { grep -v '^$' || true; } | sort -u
    else
        migrate_source_keys
    fi
}

```

(e) In `cmd_migrate`, replace `    done <<<"$(migrate_source_keys)"` with `    done <<<"$(migrate_keys)"`.

- [ ] **Step 4: Run the tests and watch them pass**

```bash
bash scripts/test-secret-store-migrate-keys.sh
bash scripts/test-secret-store-lint.sh
shellcheck -x -S warning scripts/secret-store.sh scripts/test-secret-store-migrate-keys.sh
bash scripts/test-no-secret-argv.sh | tail -1
```

Expected:
- The new suite ends with `all checks passed` (6 ok lines).
- The lint suite still passes.
- shellcheck prints nothing.
- The argv gate prints its `ok` line.

- [ ] **Step 5: Run it in CI**

In `.github/workflows/ci.yaml`, in the same `shellcheck` job:

1. Directly under the comment Task 4 added, add:

   ```yaml
      # scripts/test-secret-store-migrate-keys.sh is the ninth, and pins
      # `migrate --keys`: a cluster whose ExternalSecrets already name OpenBao
      # paths would otherwise migrate nothing and report success.
   ```

2. Append ` scripts/test-secret-store-migrate-keys.sh` to the `for t in …; do` line, after `scripts/test-openbao-new-lineage.sh`.

- [ ] **Step 6: Commit**

```bash
git add scripts/test-secret-store-migrate-keys.sh
git commit -F <msgfile> -- scripts/secret-store.sh scripts/test-secret-store-migrate-keys.sh .github/workflows/ci.yaml
```

Message: `feat(secrets): migrate takes explicit keys, for a cluster already pointed at OpenBao`

---

### Task 6: ADR-0037, the pointers and the docs

**Files:**
- Create: `website/content/docs/decisions/0037-gcp-only-runs-its-own-openbao-lineage-and-directory.md`
- Modify:
  - `website/content/docs/decisions/_index.md` (a row after the `0036` row)
  - `website/content/docs/decisions/0027-primary-cloud-provider.md`
  - `website/content/docs/decisions/0033-openbao-store-of-record-lineage.md`
  - `website/content/docs/platform/security/secrets.md`
  - `website/content/docs/guides/openbao-cross-cloud-failover.md`
  - `website/content/docs/get-started/sso.md`
  - `CLAUDE.md`

**Interfaces:**
- Consumes: the paths created in Tasks 1–5, which must exist or `verify-doc-paths.sh` fails.
- Produces: docs only.

- [ ] **Step 1: Write ADR-0037**

```markdown
---
title: A GCP-only platform runs its own OpenBao lineage and its own identity directory
linkTitle: 0037 · GCP-only runs its own store and directory
weight: 370
description: When GCP runs alone it uses a GCP-sealed OpenBao lineage and GCP's own ZITADEL directory, with the Stage 2 configuration from a shared module, so it needs no AWS key and no AWS data. Running GCP from the AWS lineage is rejected because it ties the test topology to AWS; keeping GCP on Secret Manager is rejected because it forks the secrets model.
lastVerified: 2026-09-11
---

**Status**: Accepted
**Date**: 2026-09-11
**Deciders**: Smana (Platform Owner)
**Related**: [ADR-0027](0027-primary-cloud-provider.md) — the relocation wording
this settles for the GCP-only case; [ADR-0033](0033-openbao-store-of-record-lineage.md) —
the lineage, and its driver "GCP-only deployments keep working with no AWS
dependency"; [ADR-0036](0036-per-app-secret-ownership-via-zitadel-groups.md) — the
mounts and personas this carries to GCP

---

## Context

AWS primary is the nominal topology. AWS + GCP runs sometimes, and GCP-only occasionally, as a test.

Stage 2 of ADR-0033 made OpenBao the store of record. Its design scoped GCP out except for the `ClusterSecretStore`, and that cluster-side parity did land. But GCP's OpenBao never got the `platform/` and `apps/` mounts, the policies or the logins. After the shared ExternalSecrets were repointed at OpenBao, 14 of them failed on gcp-0 in both GCP topologies: they authenticated through `jwt/gcp-0`, then read nothing.

A second gap was specific to GCP-only. Its snapshot bucket holds the AWS mirror, whose every object is AWS-sealed, so a GCP-sealed node had no way to start a lineage.

ADR-0027 says a GCP-only switch *relocates* singletons, carrying their data. ADR-0033's driver says GCP-only needs no AWS dependency. Carrying AWS's OpenBao data means unsealing with AWS's key, so the two cannot both hold.

## Decision Drivers

- GCP-only must work without the AWS KMS key or AWS's data. It is a test topology, and it must not depend on the one it tests.
- One secrets model on both clouds: the same mounts, policies and logins, defined once.
- No change to AWS primary, the nominal topology.

## Considered Options

### Option 1: GCP's own lineage and directory, Stage 2 from a shared module *(chosen)*

GCP's OpenBao is sealed by its own Cloud KMS key and gets the Stage 2 configuration from `opentofu/shared/modules/openbao-store-of-record`. It is seeded from GCP Secret Manager. ZITADEL restores GCP's own seed with its own master key and client secrets.

**Pros**: no AWS dependency; one definition of Stage 2; AWS untouched.
**Cons**: GCP's data diverges from AWS's between runs. A grant made on one directory does not exist on the other.

### Option 2: Run GCP from the AWS lineage

This is the `awskms` standby of the cross-cloud failover guide.

**Pros**: the secrets arrive already migrated, and there is one directory.
**Cons**: GCP-only needs the AWS key and AWS's newest snapshot, and ZITADEL must move its AWS seed, admin token and client secrets across. That is a migration, not a mode.

### Option 3: Keep GCP on Secret Manager

Point gcp-0's shared ExternalSecrets back at `gcpsm`.

**Pros**: the smallest change.
**Cons**: two secrets models, and every future shared ExternalSecret has to be patched per cloud.

## Decision Outcome

**Chosen option**: Option 1.

**Rationale**: it is the only option in which a GCP-only platform needs nothing from AWS. ADR-0027 rules out two clouds running duplicate singletons *at the same time*; a GCP-only platform with its own directory is not that. Relocating AWS's data remains available as the deliberate migration in *Migrate the identity provider*, and it is not a precondition for running GCP alone.

## Consequences

### Positive

- The 14 OpenBao-backed consumers work on gcp-0, in GCP-only and in AWS + GCP.
- `scripts/validate-openbao-policies.sh` fails CI when a JWT role names a policy its OpenBao does not define, which is the gap that hid this.

### Negative

- GCP's and AWS's directories and secrets are separate. Mitigation: GCP-only is a test topology, and relocating with data remains documented for when continuity matters.
- The first boot of a GCP lineage needs the operator to set `OPENBAO_NEW_LINEAGE=true` once. It is refused whenever an object under the node's own seal exists.

### Neutral

- AWS still defines Stage 2 inline until it moves onto the module. That move needs a live AWS OpenBao, so its plan can be verified.

## Implementation Notes

- Design: `docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-design.md`
- Plan: `docs/superpowers/plans/2026-09-11-openbao-stage2-gcp.md`
- Module: `opentofu/shared/modules/openbao-store-of-record`, called by `opentofu/gcp/openbao/management/store-of-record.tf`
- First boot: `OPENBAO_NEW_LINEAGE=true`, in `scripts/openbao-config.sh`

## References

- [Cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}})
- [Secrets]({{< relref "/docs/platform/security/secrets.md" >}})
- [Migrate the identity provider]({{< relref "/docs/guides/migrate-the-identity-provider.md" >}})
```

- [ ] **Step 2: Add the index row**

In `website/content/docs/decisions/_index.md`, directly after the `| [0036](…) | … | Accepted | 2026-09-10 |` row, add:

```markdown
| [0037]({{< relref "/docs/decisions/0037-gcp-only-runs-its-own-openbao-lineage-and-directory.md" >}}) | A GCP-only platform runs its own OpenBao lineage and its own identity directory | Accepted | 2026-09-11 |
```

- [ ] **Step 3: Add one pointer to ADR-0027**

In `0027-primary-cloud-provider.md`, directly after the paragraph that ends `It is a deliberate act with a written procedure, not something that happens as a side` / `effect of enabling a cluster.`, add:

```markdown

> **Amended 2026-09-11 by [ADR-0037](0037-gcp-only-runs-its-own-openbao-lineage-and-directory.md):**
> a GCP-only platform runs the singletons on GCP with GCP's *own* OpenBao lineage
> and identity directory. Relocating AWS's data is the optional migration above,
> not a precondition for running GCP alone.
```

- [ ] **Step 4: Add one pointer to ADR-0033**

In `0033-openbao-store-of-record-lineage.md`, directly after the line in `## References` that begins `- [ADR-0025](0025-cloud-managed-secret-stores.md), [ADR-0027]`, add:

```markdown
- [ADR-0037](0037-gcp-only-runs-its-own-openbao-lineage-and-directory.md) — Stage 2 (the `platform/` and `apps/` mounts, their policies and logins) on GCP's OpenBao, from the shared `openbao-store-of-record` module
```

- [ ] **Step 5: Update the secrets page**

In `website/content/docs/platform/security/secrets.md`:

(a) Directly after the break-glass code block that ends `  --query SecretString --output text | jq -r .password` and its closing fence, add:

````markdown

GCP's OpenBao has the same login, and publishes the password to Secret Manager:

```bash
export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200
export VAULT_CACERT=opentofu/gcp/openbao/management/.tls/ca.pem
bao login -method=userpass username=admin

gcloud secrets versions access latest \
  --secret openbao-priv-gcp-admin-credentials --project ogenki-435905 | jq -r .password
```
````

(b) In the warning callout, replace `It is fixed in` / `` `opentofu/aws/openbao/management/auth.tf`; if you add a mount, add it to this `` / `login's policies in the same change.` with:

```markdown
It is fixed in
`opentofu/aws/openbao/management/auth.tf`, and GCP's login comes from
`opentofu/shared/modules/openbao-store-of-record`; if you add a mount, add it to
this login's policies in the same change, in both.
```

(c) At the end of `## Migration state`, after the paragraph that begins `ZITADEL moved last and alone`, add:

```markdown

**GCP.** GCP's OpenBao got the same mounts, policies and logins on 2026-09-11,
from the shared `openbao-store-of-record` module
([ADR-0037]({{< relref "/docs/decisions/0037-gcp-only-runs-its-own-openbao-lineage-and-directory.md" >}})).
Its data is seeded from GCP Secret Manager with
`scripts/secret-store.sh migrate --cloud gcp --keys …`. The explicit list is
required, because gcp-0's ExternalSecrets already name OpenBao paths.
```

- [ ] **Step 6: Add the first-boot section to the failover guide**

In `website/content/docs/guides/openbao-cross-cloud-failover.md`, directly before `## Drill record`, add:

````markdown
## Starting a GCP-only lineage

GCP's snapshot bucket also holds the AWS mirror, and every mirrored object is
AWS-sealed. A `gcpckms` node that finds no object under its own seal therefore
has no way in. `rehydrate` refuses the foreign seal, and even with
`OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true` it refuses to initialise, because that
would overwrite a lineage's stored keys on a guess. The first boot of a GCP-only
lineage says so out loud instead:

```bash
OPENBAO_NEW_LINEAGE=true TM_CLOUD=gcp \
  terramate -C opentofu/gcp/openbao/management script run deploy
```

The switch has three limits:

- It is honoured only when nothing in the bucket carries the node's own seal.
- It is never honoured together with `OPENBAO_SNAPSHOT_KEY`.
- It **replaces** the stored root token and recovery keys.

Every later boot restores the newest `-gcpckms` object. When a mirrored AWS
object is newer, set `OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true`, as the refusal
message says.
````

- [ ] **Step 7: Update `sso.md`**

In `website/content/docs/get-started/sso.md`, in the `Recovery only` callout, replace `entry was deleted. Mint a PAT for the` with:

```markdown
entry was deleted (a GCP-only platform restoring `zitadel-20260828` is exactly this
case). Mint a PAT for the
```

- [ ] **Step 8: Update CLAUDE.md**

In `CLAUDE.md`, directly after the sentence `External Secrets is **read-only** on both` / ``mounts by design; see `website/content/docs/platform/security/secrets.md`.``, add:

```markdown
On GCP the same mounts, policies and logins come from
`opentofu/shared/modules/openbao-store-of-record`, called by
`opentofu/gcp/openbao/management` (ADR-0037); AWS still defines them inline until it
moves onto the module. `./scripts/validate-openbao-policies.sh` fails when a JWT role
names a policy its cloud's OpenBao does not define.
```

- [ ] **Step 9: Run the doc gates**

```bash
./scripts/verify-doc-paths.sh
./scripts/validate-links.sh
./scripts/validate-doc-claims.sh
```

Expected: all three exit 0.

- [ ] **Step 10: Commit**

```bash
git add website/content/docs/decisions/0037-gcp-only-runs-its-own-openbao-lineage-and-directory.md
git commit -F <msgfile> -- website/content/docs CLAUDE.md
```

Message: `docs(openbao): ADR-0037, and GCP's OpenBao in the secrets and failover pages`

---

### Task 7 [LIVE]: The throwaway test branch that makes GCP primary

**Files (on `test/gcp-only-live` only, never merged):**
- `opentofu/config.tm.hcl`
- `clusters/gcp-0/security/zitadel.yaml`
- `clusters/aws-0/security/zitadel.yaml`

- [ ] **Step 1: Cut the test worktree from this branch**

Use the `EnterWorktree` tool with name `test-gcp-only-live`. It branches from `origin/main`. Then stack it on this branch:

```bash
git merge --ff-only worktree-openbao-stage2-gcp
```

**Note:** this `--ff-only` merge only works while `origin/main` is an ancestor
of this branch. Once the access-matrix PR squash-merges, `origin/main` gains a
commit this branch lacks and the merge fails. Rebase this branch onto
`origin/main` first, or, in this fresh throwaway test worktree only (nothing
can be lost there), run `git reset --hard worktree-openbao-stage2-gcp` instead.

- [ ] **Step 2: Flip the identity-provider gates**

Make these three edits:

- In `opentofu/config.tm.hcl`, change `  primary_cloud = "aws"` to `  primary_cloud = "gcp"`.
- In `clusters/gcp-0/security/zitadel.yaml`, change the one `  suspend: true` under `spec:` to `  suspend: false`.
- In `clusters/aws-0/security/zitadel.yaml`, change `  suspend: false` to `  suspend: true`.

The third flip is required by `validate-idp-topology.sh`, which fails any non-primary cluster that would run its own identity provider.

```bash
./scripts/validate-idp-topology.sh
```

Expected: `==> identity provider topology is consistent: gcp hosts, all other clouds suspended.`

- [ ] **Step 3: Commit and push**

This is outward-facing; the owner approved the live test in the spec.

```bash
git commit -F <msgfile> -- opentofu/config.tm.hcl clusters/gcp-0/security/zitadel.yaml clusters/aws-0/security/zitadel.yaml
git push -u origin HEAD:refs/heads/test/gcp-only-live
```

Message: `test: make GCP primary for the GCP-only live test (never merge)`

---

### Task 8 [LIVE]: Deploy GCP-only, first boot on a new lineage

- [ ] **Step 1: Preflight**

Each of these must succeed. The first two check different credentials:

- `gcloud auth print-access-token >/dev/null` checks the gcloud CLI identity.
- `gcloud auth application-default print-access-token >/dev/null` checks ADC, which OpenTofu and the state backend read.

Then:

- `aws sts get-caller-identity`, for the S3 state backend and Route53.
- `tailscale status` must show Running.
- `gcloud kms keyrings list --location europe-west4 --project ogenki-435905` must show `openbao-dev`.
- `gcloud container clusters list --project ogenki-435905` must be empty, which confirms nothing is left over.
- Let's Encrypt must have fewer than 5 issuances in 7 days for `auth.gcp.cloud.ogenki.io`:

  ```bash
  curl -s 'https://api.certspotter.com/v1/issuances?domain=auth.gcp.cloud.ogenki.io&include_subdomains=false&expand=dns_names' | jq length
  ```

  This counts every issuance, so read the dates to count the last 7 days.

- Check what the first management apply will do with the OIDC secret:

  ```bash
  gcloud secrets versions access latest --secret openbao-priv-gcp-recovery-keys --project ogenki-435905 >/dev/null
  gcloud secrets versions list openbao-oidc --project ogenki-435905 --filter='state:ENABLED' --limit=1
  ```

  The first line confirms the recovery-keys pre-flight can read a version at
  all, or `rehydrate` refuses before it ever reaches `OPENBAO_NEW_LINEAGE`. The
  second says which branch the apply takes:

  | `openbao-oidc` state | What happens |
  |---|---|
  | absent | OIDC stays off |
  | exists, with no enabled version | the plan aborts (see store-of-record.tf's comment on the version-less-secret trap) |
  | exists, with a version (for example from the 2026-08-28 run) | OIDC turns on at the FIRST apply, so Task 10 Step 4's "plan adds …" expectation will not hold |

  **Watch item:** GCP management's remote state may still hold `vault_*`
  entries from a previous lineage. After a fresh init they refresh as gone and
  are re-created; a PKI resource whose read errors instead of returning 404
  would stop the plan. Recovery: `tofu state rm` on the `vault_` and
  `module.store_of_record.vault_` addresses -- the same ones
  `tofu-destroy-contained.sh` drops.

- [ ] **Step 2: Deploy**

Run this from the test worktree root:

```bash
OPENBAO_NEW_LINEAGE=true TM_CLOUD=gcp TF_VAR_flux_git_ref=refs/heads/test/gcp-only-live \
  terramate -C opentofu script run --disable-safeguards=git-out-of-sync deploy
```

`OPENBAO_NEW_LINEAGE` only affects `openbao-config.sh rehydrate`. If the deploy fails after OpenBao initialised and you re-run it, **drop `OPENBAO_NEW_LINEAGE`**: the node then answers 200 and rehydrate is a no-op.

Expected in the management stack's log:
- `OPENBAO_NEW_LINEAGE=true -- STARTING A NEW 'gcpckms' LINEAGE.`
- then an apply creating `module.store_of_record` resources and `google_secret_manager_secret.admin_credentials`.

- [ ] **Step 3: Get cluster access**

```bash
gcloud container clusters get-credentials gcp-0 --zone europe-west4-a --project ogenki-435905 --internal-ip
flux get kustomizations -A
```

Expected at this point: every Kustomization whose workloads read an OpenBao-backed secret is not Ready, because the mounts are still empty. Task 9 seeds them.

---

### Task 9 [LIVE]: OpenBao verified, secrets seeded, consumers converge

- [ ] **Step 1: Check OpenBao's configuration**

Run this from the test worktree root:

```bash
export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200
export VAULT_CACERT=opentofu/gcp/openbao/management/.tls/ca.pem
VAULT_TOKEN="$(gcloud secrets versions access latest --secret openbao-priv-gcp-root-token --project ogenki-435905 | jq -r .token)"
export VAULT_TOKEN
bao secrets list
bao policy list
```

Expected:
- `bao secrets list` shows `apps/`, `lineage/`, `pki_private_issuer/` and `platform/`.
- `bao policy list` includes `admin`, `external-secrets`, `pki-admin` and `secrets-admin`.

- [ ] **Step 2: Seed from GCP Secret Manager, dry run first**

```bash
KEYS="zitadel-envvars,harbor-admin-password,harbor-oidc,harbor-valkey-password,headlamp-envvars,runlore-credentials,runlore-slack-app,runlore-webhook,security-flux-ui-oidc,observability-flux-slack-app,observability-victoria-metrics-k8s-stack-grafana-envvars,observability-victoria-metrics-k8s-stack-alertmanager-slack-app,apps-app-wizard-llm,apps-app-wizard-oauth"
./scripts/secret-store.sh migrate --cloud gcp --project ogenki-435905 --keys "$KEYS"
./scripts/secret-store.sh migrate --cloud gcp --project ogenki-435905 --keys "$KEYS" --apply
```

Expected:
- The dry run shows 14 `would copy` lines and `skipped: 0`.
- The `--apply` run prints `copied: 14`.
- An `absent at source` line means that key is missing from GCP Secret Manager. Record it; do not guess a value.

- [ ] **Step 3: Resolve every key the cluster asks for**

```bash
./scripts/secret-store.sh check --cloud gcp --store openbao --context "$(kubectl config current-context)"
kubectl annotate externalsecrets -A force-sync="$(date +%s)" --overwrite
kubectl get externalsecrets -A
```

Expected: every OpenBao-backed ExternalSecret resolves, and all 14 show `SecretSynced`. Anything else must be named in the verification document with its cause.

- [ ] **Step 4: Converge Flux**

```bash
flux reconcile kustomization flux-system -n flux-system --with-source
flux get kustomizations -A
```

Expected: every Kustomization `Ready=True`. ZITADEL may take several minutes while its database restores from `zitadel-20260828`.

- [ ] **Step 5: Clear the leftover backup prefix, only if the restore refuses**

Do this step only if `kubectl -n security logs` for the ZITADEL CNPG pods shows `Expected empty archive`. Since #1963 each generation writes to its own prefix, so a refusal should not happen. The old prefix `xplane-zitadel-cnpg-cluster/` (base/ and wals/, dated 2026-08-28) is a pre-#1963 generation's archive.

```bash
./scripts/cnpg-prepare-restore.sh --help
```

Then run it exactly as its help describes, with `--seed zitadel-20260828`. It refuses to clear anything unless the seed holds a base backup. Delete the CNPG `Cluster` **and its PVC** before the retry.

---

### Task 10 [LIVE]: ZITADEL, the admin PAT, and both OpenBao logins

- [ ] **Step 1: First login**

The owner opens `https://auth.gcp.cloud.ogenki.io` and logs in with Google.

If Google answers with a redirect-URI error, the OAuth client must list `https://auth.gcp.cloud.ogenki.io/ui/login/login/externalidp/callback`. Only the owner can add it, in the Google console.

- [ ] **Step 2: The admin PAT, recovered once**

The restored seed predates the capture step. Run:

```bash
CL="--cluster gcp-0 --cloud gcp --project ogenki-435905"
./scripts/zitadel-oidc-clients.sh sync $CL
```

If it fails with `no ZITADEL admin PAT available`, the owner mints a PAT for the `iam-admin` machine user in the ZITADEL console. Then:

```bash
read -rs PAT
kubectl create secret generic iam-admin-pat -n security --from-file=pat=<(printf '%s' "$PAT")
unset PAT
```

This is `get-started/sso.md`'s recovery, with the token on stdin rather than on the command line.

- [ ] **Step 3: Converge ZITADEL**

These are the `sso.md` steps for gcp-0. Replace `<owner email>` with the owner's own Workspace address:

```bash
IDP_URL=https://auth.gcp.cloud.ogenki.io
./scripts/zitadel-oidc-clients.sh sync $CL --apply
./scripts/secret-store.sh grant --cloud gcp --project ogenki-435905 --apply
IDP_URL=$IDP_URL ./scripts/zitadel-idp.sh sync $CL --apply
./scripts/zitadel-oidc-clients.sh sync $CL --grant-admin <owner email> --apply
gcloud secrets describe openbao-oidc --project ogenki-435905 --format='value(name)'
```

Expected: the last command prints the secret's name. That shows `openbao-oidc` now exists.

- [ ] **Step 4: The second management apply turns OIDC on**

```bash
TM_CLOUD=gcp terramate -C opentofu/gcp/openbao/management script run --disable-safeguards=git-out-of-sync deploy
```

Expected: the plan adds `module.store_of_record.vault_jwt_auth_backend.oidc[0]`, the role, the `openbao-admin` group and its alias, plus two app personas. Rehydrate logs that there is nothing to rehydrate.

- [ ] **Step 5: Both logins read `platform/`**

For the OIDC login, run this and complete the browser flow:

```bash
bao login -method=oidc
bao token lookup
bao kv metadata get platform/zitadel/envvars
```

For the break-glass login, read the password with:

```bash
gcloud secrets versions access latest --secret openbao-priv-gcp-admin-credentials --project ogenki-435905 | jq -r .password
```

Then run the following, pasting the password at the prompt:

```bash
bao login -method=userpass username=admin
bao kv metadata get platform/zitadel/envvars
```

Expected:
- `bao token lookup` lists `admin`, `pki-admin` and `secrets-admin` among the identity policies.
- Both `kv metadata get` calls print the secret's versions, without a 403.

- [ ] **Step 6: Check the consumers**

Open Grafana, Harbor, the Flux UI and Headlamp at their `gcp.cloud.ogenki.io` hosts. Each must offer Google and log the owner in.

A consumer that answers `invalid_client` has a client secret that drifted from the seed. Re-run `./scripts/zitadel-oidc-clients.sh sync $CL --apply` and record it.

---

### Task 11 [LIVE]: The access-matrix gates

The access-matrix plan's Tasks 10–12 are written for its CronJob, which is deferred to its Task 9. Here the reconciler runs as a CLI from the workstation. **Gate 2 uses `--grants-only`**, not `--max-revocations 0`, per that plan's Task 8 override.

- [ ] **Step 1: Environment**

```bash
bash scripts/access-matrix-sync.sh --help
export IDP_URL=https://auth.gcp.cloud.ogenki.io
export GOOGLE_SA=access-matrix-sync@ogenki-435905.iam.gserviceaccount.com
export GOOGLE_SUBJECT=<owner email>
export CLOUD=gcp
```

The help lists the PAT resolution variables. If it names a GCP project variable besides `CLOUD`, export it with the value `ogenki-435905`.

- [ ] **Step 2: Gate 1, the dry run**

```bash
bash scripts/access-matrix-sync.sh; echo "exit=$?"
```

Expected:
- `exit=0` and no `GUARD` line.
- The owner, a `platform@` member who already holds `platform`, gets no write line.
- The empty `backend@`, `data-eng@` and `frontend@` groups produce nothing.

Then confirm nothing was written: run it again and see identical output.

- [ ] **Step 3: Gate 2, grants only**

The owner adds one test account to `backend@ogenki.io`, and that account logs in once at any consumer so its ZITADEL user exists. Then:

```bash
bash scripts/access-matrix-sync.sh --apply --grants-only; echo "exit=$?"
```

Expected: one `post` or `put` for the test account carrying `backend`, and `exit=0`.

Then check that the account is read-only. Take the subject string from the rendered GKE binding:

```bash
SUBJ="$(grep -m1 -o 'principalSet://[^"]*/group/backend' security/gcp-0/rbac/teams.yaml)"
kubectl auth can-i get pods -n apps --as=test --as-group="$SUBJ"
kubectl auth can-i create deployments -n apps --as=test --as-group="$SUBJ"
kubectl auth can-i get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system --as=test --as-group=backend
kubectl auth can-i patch kustomizations.kustomize.toolkit.fluxcd.io -n flux-system --as=test --as-group=backend
```

Expected, in order: `yes`, `no`, `yes`, `no`. That is read-only on GKE, and read-only through the Flux UI's bare `backend` group, per the owner's GitOps-only decision.

- [ ] **Step 4: Gate 3, revocation**

The owner removes the test account from `backend@ogenki.io`. Then:

```bash
bash scripts/access-matrix-sync.sh --apply; echo "exit=$?"
```

Expected: one `delete` or `put` removing `backend` from the test account, and `exit=0`.

- [ ] **Step 5: The guards on live data**

Temporarily change `frontend`'s `googleGroup` in the working tree only, never committed:

```bash
sed -i 's/frontend@ogenki.io/does-not-exist@ogenki.io/' security/base/access-matrix/matrix.yaml
bash scripts/access-matrix-sync.sh --apply --team frontend; echo "exit=$?"
git checkout -- security/base/access-matrix/matrix.yaml
```

Expected: a `GUARD unreadable` line, a non-zero exit, and zero writes. The last command reverts the change.

---

### Task 12 [LIVE]: Record the evidence, then ask about teardown

**Files:**
- Create, on `worktree-openbao-stage2-gcp` and not on the test branch: `docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-verification.md`

- [ ] **Step 1: Write the verification document**

Give one section per success criterion in the spec (1–8). Each section carries the command, its output and a PASS or FAIL verdict. Also record:
- anything that deviated, and why;
- every `absent at source` or unsynced key;
- any client secret that had to be rotated.

- [ ] **Step 2: Run the doc gates and commit**

```bash
./scripts/validate-links.sh
./scripts/verify-doc-paths.sh
git add docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-verification.md
git commit -F <msgfile> -- docs/superpowers/specs/2026-09-11-openbao-stage2-gcp-verification.md
```

Message: `docs(openbao): Stage 2 on GCP, verified live`

- [ ] **Step 3: Ask the owner about teardown, and stop**

Leave the platform running. Report what is running, and what the next pre-destroy snapshot will be: the lineage's first `-gcpckms` object. Ask whether to tear down.

**Run no destroy without explicit consent.** Delete the remote test branch only after teardown: the running cluster's Flux source points at it, and deleting it first would 404 that source.

---

## Self-review notes

- **Spec coverage.**

  | Spec item | Task |
  |---|---|
  | D1, D2 | 8, 9, 10 |
  | D3 | 1, 2 |
  | D4 | 4 |
  | D5 | 3 |
  | Design §1 | 1, 2 |
  | Design §2 | 4 |
  | Design §3 | 5, 9, 10 |
  | Design §4 | 3, 6 |
  | Design §5 | 7–12 |
  | Success criterion 1 | 9.4 |
  | Success criterion 2 | 9.3 |
  | Success criterion 3 | 9.1 |
  | Success criterion 4 | 10.5 |
  | Success criterion 5 | 3.4, 3.5 |
  | Success criterion 6 | 4.6 |
  | Success criterion 7 | 11 |
  | Success criterion 8 | Global Constraints; no task touches `opentofu/aws/` |

- **Two deliberate departures from the spec's wording.** Both come from facts found while writing this plan:
  - The spec says the new-lineage tests "extend `scripts/test-openbao-snapshot-key.sh`". That suite tests `openbao-snapshot.sh`, not `openbao-config.sh`, so the tests get their own sibling file in the same style.
  - The spec's data step 1, "move the CNPG prefixes aside before the deploy", becomes a conditional fallback (Task 9.5). Since #1963 each generation writes its own prefix, and `cnpg-prepare-restore.sh` calls itself "not part of the normal path any more".
- **One gap the spec did not name.** `secret-store.sh migrate` derives its keys from the live cluster's ExternalSecrets. On gcp-0 those already name OpenBao paths, so it would migrate nothing. Task 5 adds `--keys`.
