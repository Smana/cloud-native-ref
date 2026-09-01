# Enforcing the primary-cloud IdP invariant

**Date**: 2026-09-01
**Status**: Approved, not implemented
**Issue**: [#1947](https://github.com/Smana/cloud-native-ref/issues/1947)
**Governing decisions**: [ADR-0027](../../../website/content/docs/decisions/0027-primary-cloud-provider.md) (AWS is the primary cloud), [ADR-0024](../../../website/content/docs/decisions/0024-identity-provider-per-cloud.md) (the IdP is per-cloud deployable)

## Problem

ADR-0027 already decides the topology this design enforces: ZITADEL is a
**primary-cloud singleton**, hosted on whichever cloud is primary, relocating —
never duplicating — when only GCP runs. It explicitly rules out the third state,
"two clouds running with the singletons duplicated."

Nothing enforces it. Placement is two hand-set gates that must agree, and
ADR-0024 says plainly that "neither can enforce the other":

| Gate | Where | Effect |
|---|---|---|
| 1 | `deploy_identity_provider` in `opentofu/gcp/gke/configure/variables.tfvars` | derives `identity_provider_url` |
| 2 | `spec.suspend` in `clusters/gcp-0/security/zitadel.yaml` | whether Flux deploys it |

The forbidden state has now occurred twice. ADR-0027's own Context records the
first: *"a test cluster ended up running two directories with nobody able to say
whether that was the design."* On 2026-09-01 a dual-cloud bootstrap reproduced
it — both clusters ran their own ZITADEL, each with its own database restored
from its own seed, because the gates were left as the GCP validation work had
set them.

Both occurrences share a cause: **the intended topology is written in an ADR and
nowhere a machine can read it.**

## Non-goals

- **Deriving placement from `TM_CLOUD`.** Rejected on ADR-0027's own grounds:
  relocation "is an exception, and it is a migration… a deliberate act with a
  written procedure, not something that happens as a side effect of enabling a
  cluster." `TM_CLOUD` changes per invocation; the IdP's home must not.
- **Performing or scripting a relocation.** ADR-0027 notes the GCP-only path has
  "never been performed end to end"; proving it is separate work.
- **An AWS-side host toggle.** See *Unsupported state* below.
- **A new ADR.** The decision exists. This is enforcement, so ADR-0024 and
  ADR-0027 get short amendments instead.
- **Generating the Flux manifest with Terramate.** The obvious way to make gate
  2 derived rather than checked, and it is technically possible — `generate_file`
  takes `context = "root"`, so it is not confined to `opentofu/`. Rejected on
  three grounds. Flux's `postBuild` substitution cannot reach a Kustomization's
  own `spec`, only what it builds from `path`, so the field can be *generated*
  but never *substituted* — the derivation would have to own the whole file.
  Owning the whole file means either regenerating it (losing the narrative
  comments that explain the gate) or marker-based patching, which is as fragile
  as the hand-editing it replaces. And it crosses the repo's ownership line:
  `opentofu/` is Terramate's, `clusters/` is hand-authored GitOps that Flux
  reads directly, and trading that clarity for one boolean is a bad exchange.
  Checking is the right altitude, not the fallback.

## Design

### 1. One declaration

Add to `opentofu/config.tm.hcl` globals:

```hcl
# Which cloud hosts the services that cannot sensibly exist twice (ADR-0027).
# Changing this is a MIGRATION, not a toggle: the IdP's database seed, admin
# credential and OIDC clients travel with it.
primary_cloud = "aws"
```

Flipping this value is the deliberate act ADR-0027 requires. It is the only
place the topology is stated in configuration.

### 2. Gate 1 becomes derived

`opentofu/gcp/gke/configure/workflows.tm.hcl` passes the value instead of the
stack reading a hand-typed literal:

```hcl
-var='deploy_identity_provider=${global.primary_cloud == "gcp"}'
```

(An HCL comparison, not a `tm_` function — Terramate's `tm_*` set mirrors
Terraform's functions, and Terraform has no `equal()`. The repo uses the same
operator style already in `global.stack_cloud`.)

and the literal is removed from `variables.tfvars`. Gate 1 can no longer
disagree with the declaration because it *is* the declaration. Two hand-set
gates become one.

The variable keeps its default (`false`) so a bare `tofu apply` in the stack
directory stays safe.

### 3. Gate 2 becomes checked

`spec.suspend` stays committed Git state. It cannot be derived: it is applied by
Flux, which never sees Terramate globals, and `postBuild` substitution acts on
what a Kustomization *builds*, not on its own spec.

New `scripts/validate-idp-topology.sh` reads committed files only and asserts:

1. the primary cloud's IdP Kustomization is **not** suspended;
2. every non-primary cloud's IdP Kustomization **is** suspended;
3. `primary_cloud` names a cloud that exists in the repo.

An **absent** `spec.suspend` counts as not-suspended, matching Flux. This is why
`clusters/aws-0/security/zitadel.yaml` carries no such field today and does not
need one: AWS is primary, and the one state that would require AWS to be
suspended — GCP primary with AWS deployed — is rejected outright below.

Failure output names the offending file, the expected value, and the global, so
the fix needs no archaeology.

### 4. Restore compliance

In the same change: `clusters/gcp-0/security/zitadel.yaml` back to
`suspend: true`, and the `deploy_identity_provider` literal dropped from
`variables.tfvars`. Both clusters are currently destroyed, so this carries no
database, admin credential or client secret — the cheapest moment this
correction will ever have.

### 5. Unsupported state, named

`primary_cloud = "gcp"` **while AWS also deploys** would produce two
directories: `opentofu/aws/eks/configure` sets
`identity_provider_url = "https://auth.${var.public_domain_name}"`
unconditionally and has no host toggle.

The check rejects that combination explicitly rather than letting it half-work.
Adding an AWS-side toggle is out of scope: GCP-primary means AWS is not running,
which is the only case ADR-0027 opens the gates for. If a GCP-primary
*dual-cloud* platform is ever wanted, that is a new decision, and the check's
error message says so.

## Testing

The value of this check is catching states that are expensive to produce live,
so it is tested against fixtures rather than the live tree. Table-driven cases:

| Case | Expected |
|---|---|
| `primary_cloud=aws`, aws un-suspended, gcp suspended | pass |
| both clusters un-suspended | fail — names the duplicated singleton |
| `primary_cloud=aws`, aws suspended | fail — primary hosts nothing |
| `primary_cloud=gcp` with the AWS stack present | fail — unsupported combination |
| `primary_cloud` set to an unknown value | fail |

Wired into CI beside `validate-doc-claims.sh`, and listed in CLAUDE.md's
*Validation Commands*.

## Files touched

| File | Change |
|---|---|
| `opentofu/config.tm.hcl` | `primary_cloud` global |
| `opentofu/gcp/gke/configure/workflows.tm.hcl` | pass `deploy_identity_provider` |
| `opentofu/gcp/gke/configure/variables.tfvars` | drop the literal |
| `clusters/gcp-0/security/zitadel.yaml` | `suspend: true`, comment rewritten |
| `scripts/validate-idp-topology.sh` | new |
| `scripts/test-validate-idp-topology.sh` | new, fixture-driven |
| `.github/workflows/ci.yaml` | new job |
| `website/content/docs/decisions/0024-*.md` | gate 1 is now derived |
| `website/content/docs/decisions/0027-*.md` | how the invariant is enforced |
| `CLAUDE.md` | validation command |

## Success criteria

1. `./scripts/validate-idp-topology.sh` exits 0 on the corrected tree.
2. It exits non-zero, naming the file, for each failure case above.
3. `terramate script run deploy` on GCP derives `deploy_identity_provider=false`
   with `primary_cloud = "aws"` — verifiable in the plan output without applying.
4. Flipping `primary_cloud` to `gcp` makes the check demand the mirrored
   suspend state, demonstrating the GCP-only path is one value plus a migration.
5. A dual-cloud bootstrap produces exactly one ZITADEL. This is the criterion
   that failed on 2026-09-01 and the only one needing a live cluster; it is
   verified on the next dual bootstrap rather than gated on one.
