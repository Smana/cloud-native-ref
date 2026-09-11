# OpenBao Stage 2 on GCP — design

**Date:** 2026-09-11
**Status:** approved in brainstorming, section by section
**Branch:** `worktree-openbao-stage2-gcp`. It is stacked on `worktree-workspace-access-matrix`,
which provides the `platform` team name and the role list it needs. That PR merges first.
**Parent:** [Stage 2: secrets and personas](2026-09-10-openbao-stage2-secrets-personas-design.md) ·
[ADR-0033](../../../website/content/docs/decisions/0033-openbao-store-of-record-lineage.md) ·
[ADR-0027](../../../website/content/docs/decisions/0027-primary-cloud-provider.md) ·
[ADR-0024](../../../website/content/docs/decisions/0024-identity-provider-per-cloud.md)

## Context: three topologies, one nominal

| Topology | How often | What runs |
|---|---|---|
| **AWS primary** (`TM_CLOUD=aws`) | **nominal** | aws-0 and AWS's OpenBao. **This work does not change it.** |
| AWS + GCP (`TM_CLOUD=aws,gcp`) | sometimes | Both clusters. OpenBao is **per-cloud**: two instances, each authoritative for its own cluster ([ADR-0033](../../../website/content/docs/decisions/0033-openbao-store-of-record-lineage.md), "Stage 1 is per-cloud"). `jwt/gcp-0` lives on `bao.priv.gcp.ogenki.io`. |
| GCP only (`TM_CLOUD=gcp`, `primary_cloud = "gcp"`) | occasionally, as a test | gcp-0 hosts ZITADEL, and GCP's OpenBao is the only one. |

## Problem

Stage 2 (#2013–#2019, 2026-09-10) made OpenBao the store of record. Its design scoped GCP
out, with one exception: "keeping its `ClusterSecretStore` at parity with AWS".

- **The cluster side of that parity was delivered.** gcp-0 includes
  `security/base/openbao-stores`, and `jwt/gcp-0` has an `external-secrets` role naming the
  policies `default` and `external-secrets`.
- **The server side was not.** `opentofu/gcp/openbao/management` creates only the `lineage`
  and `pki` mounts. It has no `platform/` or `apps/` mount, none of the `external-secrets`,
  `secrets-admin` or `admin` policies, no break-glass `userpass`, and no OIDC login.

#2014, #2017 and #2018 repointed 15 shared ExternalSecrets at `openbao-platform` and
`openbao-apps`. gcp-0 replaces one of them, Tailscale, with its own reading GCP Secret
Manager. That leaves **14 consumers that fail on gcp-0 in both GCP topologies**:

- ZITADEL (×2)
- Grafana, the Alertmanager Slack app, and the runlore webhook token
- runlore (×3)
- Harbor (×3)
- Headlamp
- the Flux UI OIDC client and the Flux Slack app

External Secrets reaches GCP's OpenBao and authenticates. Then every read fails.

**CI stayed green.** It renders manifests, but nothing links a cluster's JWT role policies to
the management stack that is supposed to define them.

**A second blocker is specific to a brand-new GCP lineage.** The GCP snapshot bucket holds
only `-awskms` objects, mirrored from AWS. `openbao-config.sh rehydrate` refuses to restore
them onto a `gcpckms` node. Even with `OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true`, it refuses
to initialise, and correctly so: it will not overwrite a lineage's stored keys on a guess.
Moving the mirrored objects under a prefix is refused too. So a GCP-sealed lineage has no
way to start.

## Decisions

| # | Decision | Rejected alternatives |
|---|---|---|
| D1 | **GCP runs its own OpenBao lineage**: `gcpckms`, its own key, no AWS dependency. This is the [ADR-0033](../../../website/content/docs/decisions/0033-openbao-store-of-record-lineage.md) decision driver "GCP-only deployments keep working with no AWS dependency". | Running from the AWS lineage (an `awskms` standby) ties GCP-only to AWS's key and data. Keeping GCP on Secret Manager leaves two secrets models. |
| D2 | **GCP runs its own ZITADEL directory**: seed `zitadel-20260828`, with its master key (`zitadel-envvars`) and client secrets from the same run, so all three match. | Copying AWS's directory ties GCP data to AWS. A fresh empty directory loses the Google IdP links and the users. |
| D3 | **A shared module, `opentofu/shared/modules/openbao-store-of-record`, used from GCP's stack now.** AWS moves onto it in a follow-up, during a session where AWS's OpenBao is live and its plan can be verified. | Refactoring AWS now is unverifiable while AWS's OpenBao is down, and one wrong `moved` on `vault_mount.platform` deletes its data. Copying the files into GCP with a parity check keeps two copies forever. |
| D4 | **An explicit `OPENBAO_NEW_LINEAGE=true` switch in rehydrate** for the first boot of a new lineage. | Separate buckets reverse ADR-0033's single bucket. A manual move-aside is fragile and has to be redone whenever the mirror refills. |
| D5 | **A policy-parity CI check**: every policy a cluster's JWT roles name must be defined by that cloud's management stack or by the module. | A check that a store reference resolves would not have caught this bug, because the stores existed. |

[ADR-0027](../../../website/content/docs/decisions/0027-primary-cloud-provider.md) says a
GCP-only switch *relocates* singletons, carrying their data. That conflicts with D1 and D2.
ADR-0027 also records that relocation "has never been performed end to end" and is "designed
rather than proven". The new ADR (§4) resolves the conflict:

- **A GCP-only platform runs its own lineage and directory.**
- **Relocating AWS data** is the separate, optional migration in
  `guides/migrate-the-identity-provider.md`.
- **What stays ruled out** is two clouds running duplicate singletons *at the same time*.

## Design

### 1. The shared module

`opentofu/shared/modules/openbao-store-of-record` holds what
`opentofu/aws/openbao/management` defines for Stage 2 today:

- **Mounts.** `platform/` and `apps/`, both kv-v2 in the root namespace.
- **Policies.** `external-secrets`, `secrets-admin` and `admin`. It also holds `pki-admin`,
  which is templated on the PKI mount path.
- **Per-app personas.** One policy, one external identity group and one alias per entry of
  `secret_owning_apps` (ADR-0036). These are created only when OIDC is configured.
- **The break-glass login.** A `userpass` backend and an admin user carrying `admin`,
  `pki-admin` and `secrets-admin`. The password is generated in the module and returned as a
  sensitive output.
- **The ZITADEL OIDC login.** It has these parts:
  - the `oidc/` JWT backend, with `groups_claim = "groups"` and a `default` role requesting
    the `groups` scope;
  - the `openbao-admin` external group, carrying `admin`, `pki-admin` and `secrets-admin`;
  - that group's alias, named after the matrix's platform team.

  All of it is gated on the OIDC inputs being present.

**Inputs:**

- `oidc_client_id`, `oidc_client_secret`, `oidc_issuer` and `oidc_redirect_uris`
- `admin_group_alias`, which is `platform`
- `secret_owning_apps`
- `admin_username`
- `pki_mount_path`

**Outputs:**

- the admin password (sensitive)
- the mount paths
- the policy names

**The GCP stack** (`opentofu/gcp/openbao/management`) does four things:

- It calls the module.
- It reads `openbao-oidc` from GCP Secret Manager. That entry is absent on the first apply,
  so OIDC stays off, the same behaviour as AWS.
- It publishes the break-glass credentials to GCP Secret Manager as
  `openbao-priv-gcp-admin-credentials`, matching the existing `openbao-priv-gcp-*` bootstrap
  names.
- It keeps its own `cert-manager` and `snapshot` policies.

**The AWS stack does not change in this work.**

### 2. The first boot of a new lineage

`openbao-config.sh rehydrate` gains `OPENBAO_NEW_LINEAGE=true`. Its rules:

- **It is permitted only when two things hold.** The bucket listing succeeded, and no
  top-level object carries this node's seal segment.
- **It never bypasses** the "every snapshot moved aside under a prefix" refusal (`rc=2`).
- **It is loud about what it replaces.** It logs that the stored root token and recovery keys
  are replaced, then takes the existing first-bootstrap init path.
- **The default is unchanged.** Without the switch, rehydrate refuses exactly as it does
  today.

The tests extend `scripts/test-openbao-snapshot-key.sh`. Each case pins one outcome:

| Case | Result |
|---|---|
| no switch | refuses |
| switch, and zero objects under this node's seal | initialises |
| switch, and any object under this node's seal | refuses |
| switch, and everything moved aside | refuses |
| switch, and the listing fails | refuses |

The switch is set once, by the operator, on the first GCP deploy whose bucket holds no
`-gcpckms` object. After that the bucket has mixed seals. If the newest object is an AWS
mirror, `OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true` selects the newest `-gcpckms` object; the
refusal message already says so. In GCP-only mode AWS is down, so the mirror adds nothing
new.

### 3. Data, ZITADEL and the logins (GCP-only)

1. **Clear the backup prefixes.** Before the deploy, move
   `gs://ogenki-435905-ogenki-cnpg-backups/xplane-zitadel-cnpg-cluster/` (41 MB) and
   `…/xplane-harbor-cnpg-cluster/` (25 MB) to a dated side path. A CNPG restore refuses a
   destination archive that is not empty.
2. **First boot.** It uses `OPENBAO_NEW_LINEAGE=true`. The management stack's first apply
   then creates the module's mounts, policies and break-glass login.
3. **Seed.** Run `scripts/secret-store.sh migrate --cloud gcp --apply`. It copies every
   mapped key from GCP Secret Manager into `platform/` and `apps/`. It is additive: it never
   deletes the source and never overwrites a destination. It reports unmapped keys and
   skips them rather than guessing. The bootstrap tier stays in Secret Manager, as on AWS:
   - `openbao-priv-gcp-*`
   - `flux-github-app`
   - `tailscale-k8s-operator-oauth`
   - `headlamp-oauth2-proxy`
4. **ZITADEL** restores `zitadel-20260828`. Its master key and client secrets are the ones
   step 3 migrated, all from the same 2026-08-28 run.
5. **The admin PAT.** After the operator's first Google login, mint an `iam-admin` PAT once
   in the console. This is the documented recovery in `get-started/sso.md`. Store it in the
   `iam-admin-pat` Secret and in GCP Secret Manager as `zitadel-iam-admin-pat`.
6. **Converge.** Run `scripts/zitadel-oidc-clients.sh` on GCP. It ensures the matrix's roles
   (`platform`, `backend`, `data`, `frontend`) and grants `platform` to the operator with
   `--grant-admin`. It also creates OpenBao's OIDC client and writes its secret to GCP
   Secret Manager as `openbao-oidc`.
7. **The second management apply** reads `openbao-oidc` and turns on the ZITADEL OIDC login:
   `platform` maps to `openbao-admin`.

### 4. Guardrails and records

- **`scripts/validate-openbao-policies.sh`.** It is static, reads committed HCL, and runs in
  CI next to `validate-idp-topology.sh`. For each cloud, every policy named in
  `opentofu/<cloud>/<k8s>/configure/openbao.tf`'s `openbao_roles` must be defined by
  `opentofu/<cloud>/openbao/management`, either directly or through the module.
  - **It must fail on the tree before this work.** GCP names `external-secrets` and never
    defines it. That failure is the proof the check works.
  - **It passes after this work.**
- **ADR-0037**, "A GCP-only platform runs its own OpenBao lineage and identity directory".
  It records D1 and D2 with their rejected alternatives. It adds a one-line pointer to
  ADR-0027 (the relocation wording) and to ADR-0033 (Stage 2 now on both clouds' OpenBao).
- **Docs:**
  - `guides/openbao-cross-cloud-failover.md` covers the new-lineage switch.
  - `platform/security/secrets.md` covers GCP-only and AWS + GCP.
  - `get-started/sso.md` covers the one-time PAT.
  - CLAUDE.md's OpenBao section says the module applies to each cloud's OpenBao.

### 5. Validation (live, GCP-only)

- **Branches.** `test/gcp-only-live` is this branch plus one commit that flips the two
  identity-provider gates: `primary_cloud = "gcp"` and gcp-0's ZITADEL `suspend: false`. It
  is pushed so Flux can read it, never merged, and deleted afterwards.
- **Deploy.**

  ```bash
  TM_CLOUD=gcp TF_VAR_flux_git_ref=refs/heads/test/gcp-only-live \
    terramate script run --disable-safeguards=git-out-of-sync deploy
  ```

  Add `OPENBAO_NEW_LINEAGE=true` for the first boot only.
- **Checks.** They run in order, each backed by a command's output:
  1. `bao secrets list` shows `platform/` and `apps/`, and `bao policy list` includes
     `external-secrets` and `secrets-admin`.
  2. `secret-store.sh migrate` reports every mapped key copied, and
     `secret-store.sh check --cloud gcp --store openbao` resolves every key.
  3. All 14 ExternalSecrets are `SecretSynced`, and every Flux Kustomization is `Ready`.
  4. The operator can log in through Google, the PAT is minted, and `--grant-admin` has run.
  5. The OIDC login through ZITADEL lands in `openbao-admin` and reads `platform/`.
  6. The break-glass `userpass` login reads `platform/`.
- **Then the access-matrix live gates** (Tasks 10–12 of its plan):
  1. the RBAC bindings are live;
  2. the reconciler runs as a dry run;
  3. then with `--grants-only --apply`;
  4. then with revocations on;
  5. finally a check that `backend` and `data` are read-only, which needs one test account
     in `backend@`.
- **Record.** The evidence goes into `2026-09-11-openbao-stage2-gcp-verification.md`.
  **There is no teardown without the owner's consent.**

## Out of scope

- **Moving AWS onto the module.** A follow-up, done where its plan can be verified.
- **Relocating AWS's ZITADEL or OpenBao data to GCP.** The existing migration guide covers it.
- **The single-OpenBao wiring**, where gcp-0 reaches AWS's OpenBao through the Tailscale
  remote endpoint. That is ADR-0033's target model, and it is not built.
- **ZITADEL client secrets in AWS + GCP mode.** gcp-0's consumers would need the AWS
  directory's client secrets there. That is a data question for that mode.
- **Removing the GCP OpenBao stacks' `opt-in` tag.**

## Risks

- **The GCP seed predates the rename.** `zitadel-20260828` holds the pre-rename roles and
  users from that run. `--grant-admin` covers the operator; other users re-earn their grants.
- **Client secrets may have drifted from the seed.** If a consumer's login fails, re-run
  `zitadel-oidc-clients.sh` to rotate that client.
- **Certificates.** `auth.gcp.cloud.ogenki.io` had 0 Let's Encrypt issuances in the 7 days to
  2026-09-11, so the budget is available.
- **The rehydrate change is in a heavily guarded script.** Its tests come first, and the
  default path must not move.
- **Cost.** GKE and a GCE OpenBao node run while the test is up.

## Success criteria

1. A GCP-only deploy converges: every Flux Kustomization is `Ready`.
2. The 14 OpenBao-backed ExternalSecrets on gcp-0 are `SecretSynced`.
3. GCP's OpenBao has the `platform/` and `apps/` mounts and the `external-secrets`,
   `secrets-admin`, `admin` and `pki-admin` policies.
4. The break-glass `userpass` login and the ZITADEL OIDC login both read `platform/`.
5. `validate-openbao-policies.sh` fails on the tree before this work and passes after it.
6. The new-lineage cases pass, and the default refusal is unchanged.
7. The access-matrix live gates are recorded in the verification document.
8. No file under `opentofu/aws/` changes in this work.
