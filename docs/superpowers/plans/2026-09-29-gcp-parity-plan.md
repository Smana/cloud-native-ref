# GCP parity slice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make gcp-0 a GCP-only platform. `TM_CLOUD=gcp` deploys it, it hosts ZITADEL and the only OpenBao,
and it runs the agent factory. AWS keeps the Route53 zone, the AWS↔GCP federation, the S3 state bucket and
the OpenBao lineage stacks.

**Architecture:** Six PRs in this repo, plus a docs PR (Task 0.1).
- **G-0** widens octo-sts's trust policies on `main`.
- **G-1 to G-4**, a platform chain off `main`: GCP's OpenBao gets Stage 2, rebuilds become repeatable, a
  hosted ZITADEL keeps its clients in step, then the GCP-primary flip with a fresh ZITADEL.
- **G-5**, on the agent-factory stack: the `agents` mount, per-cloud issuer variables, the GKE Sandbox pool,
  the gcp-0 umbrellas and a GCP render gate.

Everything is validated on `integration/agent-factory` by one deploy after tonight's reset.

**Tech Stack:**
- OpenTofu + Terramate. Providers: `hashicorp/vault` v5, `google`/`google-beta` `~> 7.17`.
- GKE Sandbox (gVisor) and Cilium 1.20.2.
- Flux, with External Secrets v1 (`Password` generator).
- ZITADEL chart 10.0.6.
- Crossplane v2 with crossplane-configuration pre-releases.
- bash and python3 suites, discovered by `scripts/ci/tests/run.sh`.

**Spec:** [`2026-09-29-gcp-parity-design.md`](../specs/2026-09-29-gcp-parity-design.md) (read it first: diagrams,
secrets table, risks).

## Global Constraints

- **Target** is gcp-0: project `ogenki-435905`, zone `europe-west4-a`, cluster `gcp-0`. No aws-0 cluster and
  no AWS OpenBao server is built.
- **No cloud or cluster command before the owner's weekly reset, 2026-09-29 21:00.** Phases 0–7 are git,
  CI and offline tests only. Every command in Phase 8 runs after the reset.
- **Deploy from an `integration/agent-factory` checkout only, and always with
  `TF_VAR_flux_git_ref=refs/heads/integration/agent-factory`.** Three reasons:
  - Terramate applies the checkout's disk.
  - A `*/openbao/management` deploy from `main` destroys the `agents` mount and every key in it, until G-5
    merges (SP2 P38, moved here by GP-8).
  - A `gke/configure` apply without the ref points Flux at `main` and prunes the agent platform.
- **Merge classes.**
  - G-0 merges to `main` ahead of the programme: octo-sts reads `main` only (like #2113).
  - G-1, G-2 and G-3 are platform fixes that may merge on their own merits, in chain order.
  - G-4 is a platform decision with an ADR; the owner merges it, or it waits for Phase 7.
  - G-5 is programme stack: **nothing merges before the owner's UX sign-off** (SP2 P33). Merge-only, never
    rebased; each stacked branch merges its parent and `origin/main` before every push.
- **Salvage source.** `ac62abf2` (branch `worktree-openbao-stage2-gcp`, verified live 2026-09-11), whose
  pre-work base is `850ce578`. Both are reachable from `origin/test/gcp-only-live`. Paths moved in the scripts
  restructure:

  | Then | Now |
  |---|---|
  | `scripts/secret-store.sh` | `scripts/provision/secret-store.sh` |
  | `scripts/openbao-config.sh` | `scripts/provision/openbao-config.sh` |
  | `scripts/validate-*.sh` | `scripts/ci/validate-*.sh` |
  | `scripts/test-*.sh` | `scripts/ci/tests/test-*.sh` |

- **Names.**

  | Thing | Value |
  |---|---|
  | GCP OpenBao | `https://bao.priv.gcp.ogenki.io:8200`, CA at `opentofu/gcp/openbao/management/.tls/ca.pem` (the management deploy writes it) |
  | Secret Manager | root token `openbao-priv-gcp-root-token`, CA chain `openbao-priv-gcp-ca-chain`, break-glass `openbao-priv-gcp-admin-credentials`, OIDC `openbao-oidc`, project id `zitadel-project-id` (new) |
  | Mounts | `platform`, `apps` (module), `agents` (GCP stack, G-5), `lineage`, `pki_private_issuer` |
  | JWT roles on `jwt/gcp-0` | `cert-manager`, `external-secrets`, `openbao-snapshot`, `agents-secrets` (G-5) |
  | GKE Sandbox pool | `agents-gvisor`: `e2-standard-8`, spot, 0–2 nodes. RuntimeClass `gvisor` is GKE's |
  | Custom role suffix | `_v3` (`xplane_dns_editor_v3`, `xplane_storage_admin_v3`, `xplane_role_reader_v3`) |
  | ConfigMap keys (new) | `oidc_issuer_url` (gcp), `oidc_jwks_uri`, `oidc_jwks_host` (both), `gcp_dns_editor_role` (gcp) |
  | IdP | `https://auth.gcp.cloud.ogenki.io`; the owner's grant is `--grant-admin <email>` (role `admin`) |

- **Secrets.** Every secret is generated in-cluster, copied by `migrate` from Secret Manager, written by the
  deploy, or restored by the raft snapshot. **The one exception** is the three agent keys (`github-app`,
  `factory-app`, `zai`): the owner writes them once per GCP lineage with `bao kv put -mount=agents`, because
  the AWS snapshot cannot be restored across KMS seals.
- **Constitution.**
  - Every new pod gets a default-deny CNP, requests and limits, and a restricted securityContext with
    `seccompProfile: RuntimeDefault`.
  - Nothing permanent is applied with `kubectl`; a live probe is deleted in the same task.
- **Evidence.** No "done" without a command run in the same response and its output cited:
  - `./scripts/ci/validate-manifests.sh` → `Invalid: 0, Skipped: 0`;
  - `task check` → exit 0;
  - `tofu validate` → `Success! The configuration is valid.`;
  - `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml <dir>` → exit 0.
- **Git.**
  - Each PR starts in a fresh worktree (`EnterWorktree`); a stacked branch then runs
    `git reset --hard origin/<parent>` before its first commit.
  - Conventional commits in English, with **no `Co-Authored-By` trailer and no generated-with line** (the
    owner's CLAUDE.md overrides the session reminder).
  - Comments carry *why* only.
- **ADR number.** Use the lowest number ≥ 0052 that is neither a file in `website/content/docs/decisions/`
  nor reserved in an open plan: `grep -rhoE 'ADR-00[5-9][0-9]' <the SP2, SP3 and observability plans> | sort -u`.
  0044, 0049 and 0051 are reserved already. The text below writes it `ADR-00NN`.

**Markers.**
- **[OWNER]:** only the owner can do it; the executor stops and asks.
- **[LIVE]:** needs gcp-0 deployed from `integration/agent-factory` (Phase 8).

---

## Pre-flight rulings

Each ruling reads: what · why · cost if wrong.

| # | Ruling | Why | Cost if wrong |
|---|---|---|---|
| GP-1 | **Salvage `ac62abf2`**: the shared module `opentofu/shared/modules/openbao-store-of-record`, the GCP stack's call to it, `validate-openbao-policies.sh`, `migrate --keys` and the `OPENBAO_NEW_LINEAGE` switch. Apply them as 3-way diffs onto today's `main` | Verified live on 2026-09-11. The GCS state of `gcp/openbao/management` probably holds `module.store_of_record.*` addresses from that run, and the owner avoids `moved`/`state mv` | Conflicts with post-09-11 `main` in guarded scripts. Each salvaged file brings its test first, and the default paths must not move |
| GP-2 | **The module follows `main`'s AWS semantics.** Alias `admin` (the access-matrix `platform` rename never merged). `ignore_changes` on the OIDC client id, secret and `bound_audiences` (#2078). AWS's stack is untouched | Without `ignore_changes`, a management apply before ZITADEL is up (every rebuild) replays OIDC discovery and fails | One apply shows an in-place alias rename `platform → admin` when the 09-11 lineage is restored |
| GP-3 | **ZITADEL on gcp-0 is fresh every build.** `objectStoreRecovery` goes. The masterkey, DB user password and first-human password come from ESO `Password` generators (`CreatedOnce`, `Retain`). The DB admin comes from `xplane-zitadel-cnpg-superuser` through the chart's `env`, and `envVarsSecret` is emptied | The owner's approved design; no seed. One source for the DB admin, so ZITADEL and CNPG never disagree (the 2026-08-28 failure) | Every build loses users and IdP links: the owner logs in once and re-grants. If chart 10.0.6 does not pass `env` to its init/setup Jobs (checked in Task 5.2 Step 4), fall back to an ESO `kubernetes`-provider SecretStore reading the superuser Secret into `zitadel-envvars` |
| GP-4 | **`zitadel_project_id` comes from Secret Manager `zitadel-project-id`**, which the sync writes. `gke/configure` reads it at plan time; the committed tfvars value is the fallback | A fresh directory gets a new id every build. The standalone `gke/configure` deploy runs after `gke/init` stage 3, and it would re-apply the committed id against the sync's patch: a server-side-apply conflict or a revert | The first build publishes the stale fallback for the minutes before stage 3. Headlamp's token exchange fails until then |
| GP-5 | **The sync mirrors consumer secrets into OpenBao**, under `--mirror-openbao`, set only by gcp-0's hosting run. It merges into the path `bao_target_for` maps, and the payload wins on shared keys | gcp-0's consumers read `openbao-platform`, while the sync wrote only Secret Manager (09-11 bug 9). A fresh directory rotates every client every build | A value edited in OpenBao under a key the payload also carries is overwritten; admin credentials are not in the payload of the OIDC fields that change. Keys the map does not know (`openbao-oidc`, `headlamp-oauth2-proxy`) stay in Secret Manager only |
| GP-6 | **`migrate` is an [OWNER] step after the deploy**, with `--keys`, followed by a force-sync. It is not automated in HCL | The owner's approved flow. Automating it puts the root token into Terramate job environments | Some ExternalSecrets fail for minutes, until the migrate and force-sync. On a restored lineage most keys already exist |
| GP-7 | **Lineage: restore if possible, else start a new one.** Pre-flight P-4 restores the newest `-gcpckms` snapshot (`OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true`) when the Secret Manager root token belongs to that lineage. Otherwise it starts a new lineage (`OPENBAO_NEW_LINEAGE=true`, salvaged), and first deletes the stale `openbao-oidc` so the first management apply runs without OIDC | Restoring keeps the 09-11 `platform/` data and the `oidc/` mount. A new lineage cannot create `oidc/` while ZITADEL is down: the discovery check fails | A wrong verdict fails the management apply with 403 (token mismatch). The recovery is to re-run with the other flag |
| GP-8 | **M1 moves here, for both clouds.** The `agents` mount and the `agents-secrets` policy, the SecretStore path and the ExternalSecret keys land in G-5. `merge-gate` stays with SP2 S1 | The owner writes the three agent keys to `agents/` on GCP before S1 exists, and the SecretStore path is shared base | SP2 Task 1.15a shrinks (Cross-plan edits). The management-from-`main` hazard now runs until G-5 merges |
| GP-9 | **Node selection stays in the RuntimeClass**, with no composition change | The composition sets only `runtimeClassName: gvisor` (`main.k:333`). GKE's `gvisor` RuntimeClass carries the `sandbox.gke.io/runtime` selector and toleration; ours carries `agents.ogenki.io/runtime` | If GKE's RuntimeClass has no `scheduling`, runs land on runc nodes and fail to start. The smoke probe (8.5) checks it first |
| GP-10 | **The sandbox pool is a standalone `google_container_node_pool` with `provider = google-beta`**: `e2-standard-8` spot, 0–2 nodes, the Cilium taint | Independent of the module's `node_pools` map, whose sandbox support differs between the beta and GA modules. 16 vCPU / 64 GiB matches aws-0's `limits` | If e2 is refused for GKE Sandbox, change `agents_pool_machine_type` to `n2-standard-8` (dearer) |
| GP-11 | **Cilium on gcp-0 gets `socketLB.hostNamespaceOnly: true`** | gVisor's netstack never calls `connect()` in the host kernel, so socket-LB cannot translate a ClusterIP; per-packet LB can. aws-0 already runs it | It is the first datapath change since the GKE gate. The smoke probe and the gateways (L-4) prove it; the rollback is one line |
| GP-12 | **Per-cloud issuer variables** (`oidc_issuer_url`, `oidc_jwks_uri`, `oidc_jwks_host`) in both ConfigMaps. The base manifests use them | `oidc.eks.${region}.amazonaws.com` renders a host that does not exist on gcp-0, and `/keys` is EKS's JWKS path (GKE's is `/jwks`). The render stays clean, so nothing would notice | SP2's broker (P11) and any later consumer must use the same keys (Cross-plan edits) |
| GP-13 | **octo-sts `issuer_pattern` becomes an alternation** of the EKS pattern and `https://container\.googleapis\.com/v1/projects/ogenki-435905/locations/[a-z0-9-]+/clusters/gcp-0`. G-0 merges ahead | octo-sts reads trust policies from `main` only. The agent-router `sts` listener verifies every token against its own cluster's issuer first | Until G-0 merges, runbooks 05 and 07 fail at the exchange on gcp-0 |
| GP-14 | **The GCP render fixture uses per-cloud overlays.** Each substituted agent base gets `*/aws-0/<name>` and `*/gcp-0/<name>` one-liners, and the new `assert-cloud-shape.py` gates the gcp-0 renders | `render-bundle.py` renders a base with AWS fixtures and a `*/gcp-0/*` overlay with `CLUSTER_FIXTURE_VARS["gcp-0"]`. A base referenced by an overlay stops being a render root, which is why aws-0 needs its twin (as 89a2666b did for envoy-gateway) | Twelve small files. A future gcp-0 child that substitutes into a `base/` path fails the gate, by design |
| GP-15 | **Custom GKE roles get a `_v3` suffix and survive teardown.** The destroy drops them from state; the deploy adopts them (`adopt-custom-roles.sh`) | GCP reserves a deleted role ID for 37 days and allows undelete for 7 only. The 09-14 teardown deleted `_v2`, and the unsuffixed IDs were deleted before 09-11 (09-11 bug 2) | Three role definitions stay in the project between builds. They grant nothing, because their bindings are destroyed |
| GP-16 | **The GCP-primary flip is a PR (G-4) with an ADR.** It sets `primary_cloud`, both ZITADEL `suspend`s and the fresh-directory overlay | The owner's intent is durable (AWS reduced), and `validate-idp-topology.sh` must hold on the stack | Merged to `main`, it makes `TM_CLOUD=aws` build a cluster with no IdP until reverted. The ADR records it |
| GP-17 | **gcp-0's Envoy Gateway gets the rate limit through a shared `infrastructure/base/envoy-gateway-ratelimit`.** The Karpenter panel and alert stay in base, inert on gcp-0 | `llm-gateway`'s budget policy needs the rate-limit service (SP4 PR 1). GKE has no Karpenter metrics, and `AgentSandboxPodPending` is gcp-0's capacity signal | The gcp-0 dashboard shows one empty panel |
| GP-18 | **SP2 on gcp-0: the bridge → broker `:8443` serves TLS on both clouds**, not plain HTTP behind WireGuard (reverses SP2 P2). This is a cross-plan edit | gcp-0's Cilium has no WireGuard ("Do not add WireGuard here without new evidence"), and a run token must not cross nodes in clear | SP2 AP-1, S1 and CC-S2 each grow: a Certificate from the `openbao` issuer, the CA in the sandbox. SP2's live gates on gcp-0 wait for it |
| GP-19 | **Stacking.** G-5 is based on H-1 (`fix/agent-review-hardening`) and merges G-4 in. O-1 re-bases onto G-5. The first deploy needs only G-1 to G-4; G-5 can follow through Flux and three stack re-applies | H-1's live gate runs on gcp-0, and G-5 edits runbooks H-1 also edits. G-5 before O-1 means O-1 and S1 add their gcp-0 children themselves | G-5's PR diff shows G-1 to G-4 until they reach `main`. Phase 7 order: #2111 → H-1 → G-5 → O-1 → S1 |

## Risks → early checks

Verdicts and evidence are in the spec's *Risks* table. This maps each one to the step that checks it early.

| Risk | Checked by |
|---|---|
| ADC reauth mid-run | 8.1 P-2 (fresh login), 8.2 (exit code logged, idempotent re-run) |
| Let's Encrypt 5/168 h | 8.1 P-3 |
| GKE LB orphans | 3.3 (teardown reports target pools and `k8s-*` firewall rules), 8.1 P-9 |
| Custom-role IDs reserved | 3.2 (`_v3` + persistence), 8.1 P-6 |
| Lineage/token mismatch | 8.1 P-4, P-5 |
| Grant allowlist | not triggered: 6.4 Step 1 greps the pinned compositions for new `roles/` |
| Hairpin on gcp-0's own Gateway | 8.4 Step 5 (SSO on every consumer); SP2 cross-plan edit |
| external-dns child filter | 8.3 Step 8 |
| gVisor + socket-LB, gVisor + seccomp, scale from zero | 8.5 |
| AgentRun XRD missing on gcp-0 | 6.4 (pin lockstep), 8.2 Step 4 (core patch) |
| Destroy false success | only `scripts/ops/teardown/teardown.sh`, then `--verify-only` (3.3) |

## PR map

| # | Repo · branch | Base | Class | Carries | Gate |
|---|---|---|---|---|---|
| G-0 | this · `chore/octo-sts-gke-issuer` | `main` | **merge ahead** | trust policies accept gcp-0's issuer | CI; owner merges before 8.6 |
| G-1 | this · `fix/openbao-stage2-gcp` | `main` | **platform fix** | module, GCP stack call, policy-parity gate, `migrate --keys`, new-lineage switch | CI; live in 8.3 |
| G-2 | this · `fix/gke-rebuild-hygiene` | `fix/openbao-stage2-gcp` | **platform fix** | stage 2: CA, jwt adopt, `deploy_identity_provider`; custom roles `_v3` that survive teardown; teardown sweep | CI; live in 8.2 |
| G-3 | this · `fix/gcp-hosted-idp` | `fix/gke-rebuild-hygiene` | **platform fix** (inert while AWS is primary) | shared key map, sync `--mirror-openbao`, `zitadel-project-id`, stage 3: IdP sync and OpenBao flags | CI; live in 8.3–8.4 |
| G-4 | this · `feat/gcp-primary` | `fix/gcp-hosted-idp` | **platform decision** (owner) | ADR-00NN, `primary_cloud = "gcp"`, both suspends, fresh ZITADEL | CI; live in 8.3–8.4 |
| G-5 | this · `feat/gcp-agent-platform` | `fix/agent-review-hardening` (H-1), merges `feat/gcp-primary` | **programme stack** (Phase 7) | M1 on both clouds, issuer vars, sandbox pool + Cilium, CC pin, Kyverno, overlays, two umbrellas, cloud-shape gate, runbooks | CI; live in 8.5–8.6 |

`integration/agent-factory` merges G-5 (which contains H-1 and G-1 to G-4), plus one test-only commit that
unsuspends gcp-0's `ai-gateway` and `agent-platform` (Task 7.1).

## File structure

| Path | PR | Responsibility |
|---|---|---|
| `.github/chainguard/agent-*.sts.yaml`, `scripts/ci/tests/test-octo-sts-issuer.py` | G-0 | Trust gcp-0's issuer |
| `opentofu/shared/modules/openbao-store-of-record/**` | G-1 | Stage 2 mounts, policies, break-glass, OIDC, personas |
| `opentofu/gcp/openbao/management/{store-of-record.tf,auth.tf,outputs.tf,policies.tf,variables.tf,variables.tfvars,versions.tf,workflows.tm.hcl}` | G-1 | Call the module; OIDC from Secret Manager; break-glass to Secret Manager |
| `scripts/ci/validate-openbao-policies.sh`, `scripts/ci/tests/test-validate-openbao-policies.sh`, `scripts/tasks.yaml`, `taskfile.yaml`, `.github/workflows/ci.yaml` | G-1 | Policy-parity gate, module `tofu test` step |
| `scripts/provision/secret-store.sh`, `scripts/ci/tests/test-secret-store-migrate-keys.sh` | G-1 | `migrate --keys` |
| `scripts/provision/openbao-config.sh`, `scripts/ci/tests/test-openbao-new-lineage.sh`, `website/content/docs/guides/openbao-cross-cloud-failover.md` | G-1 | `OPENBAO_NEW_LINEAGE` |
| `scripts/ci/tests/test-openbao-oidc-lifecycle.sh` | G-1 | #2078's `ignore_changes` on both OIDC definitions |
| `opentofu/gcp/gke/init/{workflows.tm.hcl,iam.tf,variables.tf,variables.tfvars,outputs.tf}`, `scripts/ops/gcp/adopt-custom-roles.sh`, `scripts/ci/tests/{test-gcp-gke-init-workflow.py,test-adopt-custom-roles.sh,test-gcp-custom-role-refs.sh}` | G-2 | Stage 2 fixes, roles `_v3` that survive teardown |
| `opentofu/gcp/gke/configure/kubernetes.tf`, `infrastructure/gcp-0/external-dns/workloadidentity.yaml`, `scripts/ci/flux-schema/render-bundle.py` | G-2 | `gcp_dns_editor_role` |
| `scripts/ops/teardown/teardown.sh`, `scripts/ci/tests/test-teardown-gcp-sweep.sh` | G-2 | Report the LB leftovers that block a VPC delete |
| `scripts/lib/bao-map.sh`, `scripts/ci/tests/test-bao-map.sh` | G-3 | One managed-store → OpenBao map for both scripts |
| `scripts/provision/zitadel-oidc-clients.sh`, `scripts/ci/tests/{test-zitadel-oidc-clients-mirror.sh,test-gcp-zitadel-project-id.sh}` | G-3 | Mirror, project id |
| `opentofu/gcp/gke/configure/{data.tf,locals.tf,kubernetes.tf}` | G-3 | Read `zitadel-project-id` |
| `opentofu/config.tm.hcl`, `clusters/{gcp-0,aws-0}/security/zitadel.yaml`, `website/content/docs/decisions/00NN-gcp-primary-platform.md`, `_index.md`, `opentofu/AGENTS.md` | G-4 | GCP primary |
| `security/gcp-0/zitadel/{kustomization.yaml,password-generators.yaml,externalsecrets-generated.yaml,helmrelease-env-patch.yaml}`, `scripts/ci/tests/test-zitadel-gcp-fresh.py` | G-4 | Fresh ZITADEL |
| `opentofu/{aws,gcp}/openbao/management/{mounts.tf,policies.tf,policies/*.hcl}`, module `policies/secrets-admin.hcl`, `opentofu/gcp/gke/configure/openbao.tf`, `security/base/agent-secrets/secretstore.yaml`, `security/base/octo-sts/externalsecret.yaml`, `infrastructure/base/agent-router/externalsecret-zai.yaml`, `scripts/ci/tests/test-openbao-agent-mounts.sh` | G-5 | M1 on both clouds |
| `opentofu/{aws/eks,gcp/gke}/configure/{kubernetes.tf,locals.tf,openbao.tf}`, `infrastructure/base/agent-router/{securitypolicy-*.yaml,network-policy-data-plane.yaml}`, `infrastructure/base/agent-mcp/mcproutes.yaml`, `security/base/octo-sts/network-policy.yaml`, `scripts/ci/tests/test-oidc-issuer-vars.sh` | G-5 | Per-cloud issuer |
| `opentofu/gcp/gke/init/{sandbox.tf,variables.tf,helm_values/cilium.yaml}`, the Vector toleration file(s), `scripts/ops/k8s/gvisor-smoke.yaml`, `scripts/ci/tests/test-gcp-agents-pool.sh` | G-5 | Sandbox nodes |
| `infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml`, `security/gcp-0/controllers/kustomization.yaml`, `scripts/ci/tests/test-gcp-agent-prereqs.sh` | G-5 | AgentRun XRD and Kyverno on gcp-0 |
| `{infrastructure,security,observability}/{aws-0,gcp-0}/<agent base>/kustomization.yaml` (12) | G-5 | Per-cloud render roots |
| `infrastructure/base/envoy-gateway-ratelimit/**`, `infrastructure/{aws-0,gcp-0}/envoy-gateway/kustomization.yaml` | G-5 | Shared rate limit |
| `clusters/gcp-0/{ai-gateway,agent-platform,llm-platform}.yaml`, `clusters/gcp-0-ai-gateway/*`, `clusters/gcp-0-agent-platform/*`, `clusters/gcp-0-llm-platform/kustomization.yaml`, `clusters/aws-0-{agent-platform,ai-gateway}/*` (paths), `.doc-claims.yaml` | G-5 | Umbrellas |
| `scripts/ci/flux-schema/assert-cloud-shape.py`, `scripts/ci/tests/flux-schema/test-assert-cloud-shape.py`, `scripts/ci/validate-manifests.sh` | G-5 | GCP render gate |
| `docs/runbooks/agent-factory/*.md`, `scripts/ci/tests/test-runbooks-gcp.py` | G-5 | Runbooks on gcp-0 |

## Owner actions

| Marker | Task | What |
|---|---|---|
| [OWNER] | 1.1 | Merge G-0 to `main` (octo-sts reads `main`) before Task 8.6 |
| [OWNER] | 5.2 | Decide whether G-1 to G-4 merge ahead as platform work, or wait for Phase 7 |
| [OWNER] | 8.1 | After 21:00: `gcloud auth application-default login`; check the Google OAuth client's redirect list; read the pre-flight verdicts |
| [OWNER] | 8.2 | The first deploy |
| [OWNER] | 8.3 | `secret-store.sh migrate --cloud gcp --keys …` as the break-glass admin |
| [OWNER] | 8.4 | First Google login; `--grant-admin`; a second management apply (new lineage only); SSO checks |
| [OWNER] | 8.6 | `bao kv put -mount=agents` for `github-app`, `factory-app`, `zai`: the one exception |

## Cross-plan edits

Apply these to the plans' canonical copies in Task 0.1.

**SP2 plan (`2026-09-27-agent-collaboration-rooms-plan.md`):**
- **Global Constraints.** *Target* becomes gcp-0: the GCP parity plan makes it the platform, and aws-0 is not
  deployed. P2 is reversed; gcp-0 is in scope.
- **P2.** New text: "The bridge → broker `:8443` serves TLS on both clouds (GCP parity GP-18). The broker's
  certificate comes from the `openbao` ClusterIssuer, and the bridge trusts `openbao-ca`." AP-1, S1 and CC-S2
  gain those steps.
- **P11.** "`oidc.eks.${region}.amazonaws.com:443`" → "`${oidc_jwks_host}:443`", and the JWKS URI →
  `${oidc_jwks_uri}` (GP-12).
- **P11/§9, the broker's IdP egress.** On gcp-0, `toFQDNs: auth.gcp.cloud.ogenki.io` with `toPorts: 443`
  reaches gcp-0's own ZITADEL Gateway and hits the hairpin (memory `gcp_gateway_hairpin_cross_node`). Use
  `toEntities: [all]` with no `toPorts` for that one rule, as `tooling/gcp-0/headlamp/network-policy.yaml`
  does.
- **P38 and Task 1.15a.** The `agents` mount, `agents-secrets.hcl`, the SecretStore path, the ExternalSecret
  keys and `test-openbao-agent-mounts.sh` landed in GCP parity G-5 (GP-8), for both clouds. Task 1.15a keeps:
  - the `merge-gate` mount, its `secrets-admin` paths and a `merge-gate` line in that test;
  - Steps 8–11, marked "aws-0 only, if it is ever rebuilt".

  The footgun reads "until G-5 merges".
- **Every [LIVE] step.**

  | Replace | With |
  |---|---|
  | `priv.aws.ogenki.io` | `priv.gcp.ogenki.io` |
  | `opentofu/aws/openbao/management/.tls/ca.pem` | `opentofu/gcp/openbao/management/.tls/ca.pem` |
  | `jwt/aws-0` | `jwt/gcp-0` |
  | `auth.cloud.ogenki.io` | `auth.gcp.cloud.ogenki.io` |
  | "the next aws-0 rebuild" | "gcp-0, after GCP parity Task 8.6" |

- **Task 0.5.14.** Step 1: runbook 08's pool check is `kubectl get nodes -l sandbox.gke.io/runtime=gvisor`
  instead of `karpenter_nodepools_*`. Step 2's regex becomes
  `^https://grafana\.priv\.gcp\.ogenki\.io/d/agent-platform$`.
- **The live-check routine.** Hand-patch the core package on **gcp-0**. Every child an S PR adds to
  `clusters/aws-0-agent-platform/` gets its twin in `clusters/gcp-0-agent-platform/`, with `gke-gcp-0-vars`
  and a `*/gcp-0/*` overlay when it substitutes (GP-14).
- **P12.** gcp-0's stage 3 already opens the OpenBao session (`--openbao-url`, G-3). The `rooms-proxy` write
  to `agents/rooms-proxy` uses it the same way on gcp-0.

**Observability plan (`2026-09-27-agent-observability-plan.md`):**
- O12 and the PR map: O-1's *Base* becomes `feat/gcp-agent-platform` (GCP parity G-5), which is itself on H-1.
- Owner action 3.1 and Phase 3: gcp-0 after GCP parity Task 8.6, not "the next aws-0 rebuild".
- Every child O-1 adds to `clusters/aws-0-agent-platform/` (collector and the rest) gets its gcp-0 twin
  under the same rule.

**SP3 plan:** when `merge-gate` lands, it lands on GCP's management stack too.

---

## Phase 0 — Records

### Task 0.1: Commit the spec, the plan and the cross-plan edits

**Files:**
- Create: `docs/superpowers/specs/2026-09-29-gcp-parity-design.md`,
  `docs/superpowers/plans/2026-09-29-gcp-parity-plan.md`
- Modify: `docs/superpowers/plans/2026-09-27-agent-collaboration-rooms-plan.md` (on `main`), and
  `docs/superpowers/plans/2026-09-27-agent-observability-plan.md` (on branch `docs/observability-plan`, where
  it lives). Also update the scratchpad copies of both.

**Interfaces:** Produces the reference every later PR body links to.

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `docs/gcp-parity` (from `origin/main`).

- [ ] **Step 2: Copy the two documents in and apply the SP2 edits**

Copy the spec and plan from the scratchpad to the paths above. Compare the SP2 plan in the repo with the
scratchpad copy: `diff -q docs/superpowers/plans/2026-09-27-agent-collaboration-rooms-plan.md <scratchpad copy>`.
If they differ, the newer file (`ls -l --time-style=+%FT%T`) is canonical: copy it over the older first.
Then apply the SP2 bullets of *Cross-plan edits*, one at a time.

- [ ] **Step 3: Gate**

Run: `./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh; echo "exit $?"`
Expected: `exit 0`. A dead relative link is fixed in place.

- [ ] **Step 4: Commit and open the docs PR** (docs PRs wait for review)

```bash
git add docs/superpowers
git commit -m "docs(superpowers): GCP parity slice design and plan, and SP2's gcp-0 deltas"
```

Run `create-pr` with base `main`. Title: `docs(superpowers): GCP parity slice`.

- [ ] **Step 5: The observability plan, on its own branch**

In a worktree of `docs/observability-plan`, apply the observability bullets of *Cross-plan edits*. Then:

```bash
git commit -am "docs(superpowers): O-1 builds on GCP parity G-5 and runs on gcp-0"
git push origin HEAD:docs/observability-plan
```

---

## Phase 1 — G-0: octo-sts trusts gcp-0

### Task 1.1: Trust policies accept the GKE issuer

**Files:**
- Modify: `.github/chainguard/agent-implementer.sts.yaml`, `agent-reviewer.sts.yaml`, `agent-tester.sts.yaml`,
  `agent-triager.sts.yaml`
- Create: `scripts/ci/tests/test-octo-sts-issuer.py`

**Interfaces:** Produces the trust octo-sts needs for tokens minted on gcp-0 (runbooks 05 and 07, SC-04).

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `chore/octo-sts-gke-issuer` (from `origin/main`).

- [ ] **Step 2: Write the failing test**

`scripts/ci/tests/test-octo-sts-issuer.py`:

```python
#!/usr/bin/env python3
# requires: python3
"""GCP parity GP-13: every agent trust policy accepts aws-0's EKS issuer AND
gcp-0's GKE issuer, and nothing wider. octo-sts anchors the pattern, so
re.fullmatch is the model (RE2 and Python agree on this subset)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
EKS = "https://oidc.eks.eu-west-3.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF"
GKE = "https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0"
REJECT = [
    "https://container.googleapis.com/v1/projects/attacker/locations/europe-west4-a/clusters/gcp-0",
    "https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-1",
    "https://oidc.eks.us-east-1.amazonaws.com/id/0123456789ABCDEF0123456789ABCDEF",
    GKE + "/extra",
]
fails = []
files = sorted((ROOT / ".github/chainguard").glob("agent-*.sts.yaml"))
if len(files) != 4:
    fails.append(f"expected 4 agent trust policies, found {len(files)}")
for f in files:
    m = re.search(r"^issuer_pattern:\s*'([^']+)'\s*$", f.read_text(), re.M)
    if not m:
        fails.append(f"{f.name}: no single-quoted issuer_pattern")
        continue
    pat = re.compile(m.group(1))
    for iss in (EKS, GKE):
        if not pat.fullmatch(iss):
            fails.append(f"{f.name}: does not accept {iss}")
    for iss in REJECT:
        if pat.fullmatch(iss):
            fails.append(f"{f.name}: accepts {iss}")
for x in fails:
    print("FAIL", x)
if fails:
    sys.exit(1)
print("PASS")
```

- [ ] **Step 3: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-octo-sts-issuer.py; echo "exit $?"`
Expected: four `FAIL agent-*.sts.yaml: does not accept https://container.googleapis.com/…` lines, then `exit 1`.

- [ ] **Step 4: Widen the four policies**

In each file, replace the `issuer_pattern:` line with:

```yaml
issuer_pattern: '(https://oidc\.eks\.eu-west-3\.amazonaws\.com/id/[0-9A-F]{32}|https://container\.googleapis\.com/v1/projects/ogenki-435905/locations/[a-z0-9-]+/clusters/gcp-0)'
```

In each header comment, "The issuer is a pattern because the EKS issuer ID changes on every rebuild (OD-5)"
gains: "The second alternative is gcp-0's GKE issuer, fixed by project and cluster name (GCP parity GP-13)".
In `agent-reviewer.sts.yaml`, whose header does not carry that sentence, add the new sentence to its first
line.

- [ ] **Step 5: Run it to see it pass, then the suite**

Run: `python3 scripts/ci/tests/test-octo-sts-issuer.py && task ci:test`
Expected: `PASS`, then `… passed, … skipped, 0 failed`.

- [ ] **Step 6: Commit and open G-0**

```bash
git add .github/chainguard scripts/ci/tests/test-octo-sts-issuer.py
git commit -m "chore(agents): octo-sts trusts gcp-0's GKE issuer"
```

Run the `create-pr` skill with base `main`. Title: `chore(agents): octo-sts trust policies accept gcp-0's issuer`.
The body says octo-sts reads `main` only, so this merges ahead of the programme, as #2113 did (GP-13).
**[OWNER] merges it** before Task 8.6.

---

## Phase 2 — G-1: Stage 2 on GCP's OpenBao (platform fix)

### Task 2.1: The policy-parity gate, red on today's tree

**Files:**
- Create: `scripts/ci/validate-openbao-policies.sh` (from `ac62abf2:scripts/validate-openbao-policies.sh`),
  `scripts/ci/tests/test-validate-openbao-policies.sh` (from `ac62abf2:scripts/test-validate-openbao-policies.sh`)

**Interfaces:**
- Produces `./scripts/ci/validate-openbao-policies.sh [ROOT]`. It exits 1 with `FAIL: <cloud>: a JWT role names policy "<p>", …` for every
  policy a `*/configure/openbao.tf` role names and that `<cloud>/openbao/management` does not define (directly
  or through a module). Otherwise it prints `==> OpenBao policy parity: every policy a JWT role names is defined (N cloud(s)).`

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `fix/openbao-stage2-gcp` (from `origin/main`). Check the salvage refs exist:
`git cat-file -t ac62abf2 && git cat-file -t 850ce578` → `commit` twice. If not: `git fetch origin test/gcp-only-live`.

- [ ] **Step 2: Bring the test first**

```bash
git show ac62abf2:scripts/test-validate-openbao-policies.sh \
  | sed -e 's#scripts/validate-openbao-policies.sh#scripts/ci/validate-openbao-policies.sh#g' \
        -e 's#/\.\." || exit#/../../.." || exit#' \
  > scripts/ci/tests/test-validate-openbao-policies.sh
grep -n 'dirname' scripts/ci/tests/test-validate-openbao-policies.sh
```

Expected: every `dirname` line resolves the repo root three levels up (`../../..`). Fix by hand any that
still says `..`.

- [ ] **Step 3: Run it to see it fail**

Run: `bash scripts/ci/tests/test-validate-openbao-policies.sh; echo "exit $?"`
Expected: a non-zero exit that names the missing `scripts/ci/validate-openbao-policies.sh`.

- [ ] **Step 4: Bring the gate**

```bash
git show ac62abf2:scripts/validate-openbao-policies.sh > scripts/ci/validate-openbao-policies.sh
chmod +x scripts/ci/validate-openbao-policies.sh
```

- [ ] **Step 5: The test passes, and the gate is red on the tree**

Run: `bash scripts/ci/tests/test-validate-openbao-policies.sh; echo "suite $?"; ./scripts/ci/validate-openbao-policies.sh; echo "gate $?"`
Expected: `suite 0`. Then the tree fails:
`FAIL: gcp: a JWT role names policy "external-secrets", but opentofu/gcp/openbao/management does not define it (directly or through a module it calls)`, then `gate 1`.
That is `gcp_only_broken_since_stage2`, caught. Task 2.3 turns it green.

- [ ] **Step 6: Commit**

```bash
git add scripts/ci/validate-openbao-policies.sh scripts/ci/tests/test-validate-openbao-policies.sh
git commit -m "feat(ci): a JWT role may only name a policy its OpenBao defines"
```

### Task 2.2: The shared Stage 2 module, on main's semantics

**Files:**
- Create: `opentofu/shared/modules/openbao-store-of-record/**` (from `ac62abf2`),
  `scripts/ci/tests/test-openbao-oidc-lifecycle.sh`
- Modify (after the checkout): its `oidc.tf`, `variables.tf` and `tests/store_of_record.tftest.hcl`

**Interfaces:**
- Produces module inputs `pki_mount_path`, `openbao_address`, `admin_username`, `admin_group_alias` (default
  `"admin"`), `secret_owning_apps`, `oidc_client_id`, `oidc_client_secret`, `oidc_issuer`.
- Produces output `admin_password` (sensitive), plus mount and policy names.
- Resources keep their `ac62abf2` addresses: `vault_mount.platform`, `vault_mount.apps`,
  `vault_policy.{admin,pki_admin,secrets_admin,external_secrets,app_prefix}`,
  `vault_jwt_auth_backend.oidc[0]`, `vault_identity_group.oidc_admin[0]`, … (GP-1).

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-openbao-oidc-lifecycle.sh`:

```bash
#!/usr/bin/env bash
#
# #2078 on every copy of the OpenBao OIDC login (GCP parity GP-2): tofu must never
# rewrite the rotating client fields. A management apply runs before ZITADEL is up
# on every rebuild, and rewriting them replays OIDC discovery against an IdP that
# is not there yet; zitadel-oidc-clients.sh's reconcile_openbao_oidc rotates them.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
for f in opentofu/aws/openbao/management/oidc.tf opentofu/shared/modules/openbao-store-of-record/oidc.tf; do
  [ -f "$ROOT/$f" ] || { echo "FAIL $f is missing"; fails=$((fails + 1)); continue; }
  grep -Eq 'ignore_changes[[:space:]]*=[[:space:]]*\[oidc_client_id, oidc_client_secret\]' "$ROOT/$f" \
    || { echo "FAIL $f: the backend does not ignore oidc_client_id/oidc_client_secret"; fails=$((fails + 1)); }
  grep -Eq 'ignore_changes[[:space:]]*=[[:space:]]*\[bound_audiences\]' "$ROOT/$f" \
    || { echo "FAIL $f: the default role does not ignore bound_audiences"; fails=$((fails + 1)); }
done
[ "$fails" -eq 0 ] || exit 1
echo PASS
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-openbao-oidc-lifecycle.sh; echo "exit $?"`
Expected: `FAIL opentofu/shared/modules/openbao-store-of-record/oidc.tf is missing`, then `exit 1`.

- [ ] **Step 3: Salvage the module and bring it to main's semantics**

```bash
git checkout ac62abf2 -- opentofu/shared/modules/openbao-store-of-record
```

In `opentofu/shared/modules/openbao-store-of-record/oidc.tf`, add the last block inside
`resource "vault_jwt_auth_backend" "oidc"`:

```hcl
  lifecycle {
    # Same as opentofu/aws/openbao/management/oidc.tf (#2078): OpenBao never
    # returns the secret on read, and every fresh ZITADEL issues a new client id,
    # so an apply here would replay discovery while the IdP is still down.
    # zitadel-oidc-clients.sh's reconcile_openbao_oidc rotates both fields.
    ignore_changes = [oidc_client_id, oidc_client_secret]
  }
```

Then the last block inside `resource "vault_jwt_auth_backend_role" "oidc_default"`:

```hcl
  lifecycle {
    # Tracks the client id, so it rotates with it (#2078).
    ignore_changes = [bound_audiences]
  }
```

In `variables.tf`, set `admin_group_alias`'s `default = "admin"`, and make its description name ZITADEL's
`admin` project role (`scripts/provision/zitadel-oidc-clients.sh` `ZITADEL_PROJECT_ROLES`). The access-matrix
rename to `platform` never merged (GP-2). In `tests/store_of_record.tftest.hcl`, the alias assertion becomes:

```hcl
  assert {
    condition     = vault_identity_group_alias.oidc_admin[0].name == "admin"
    error_message = "the openbao-admin group must alias ZITADEL's admin project role"
  }
```

- [ ] **Step 4: Run both tests**

Run: `bash scripts/ci/tests/test-openbao-oidc-lifecycle.sh && tofu -chdir=opentofu/shared/modules/openbao-store-of-record init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/shared/modules/openbao-store-of-record test`
Expected: `PASS`, then `Success! 2 passed, 0 failed.`

- [ ] **Step 5: Commit**

```bash
git add opentofu/shared/modules/openbao-store-of-record scripts/ci/tests/test-openbao-oidc-lifecycle.sh
git commit -m "feat(openbao): the Stage 2 store of record as a shared module, tested offline"
```

### Task 2.3: GCP's management stack calls the module

**Files:**
- Modify: `opentofu/gcp/openbao/management/{auth.tf,outputs.tf,policies.tf,variables.tf,variables.tfvars,versions.tf,workflows.tm.hcl}`
- Create: `opentofu/gcp/openbao/management/store-of-record.tf`
- Modify: `.github/workflows/ci.yaml`, `scripts/tasks.yaml`, `taskfile.yaml`

**Interfaces:**
- Consumes the module from Task 2.2.
- Produces on GCP's OpenBao the mounts `platform`, `apps`, the policies `external-secrets`, `secrets-admin`,
  `admin`, `pki-admin`, `userpass/admin`, and `oidc/` once `openbao-oidc` exists.
- Produces the Secret Manager secret `openbao-priv-gcp-admin-credentials` (`{username, password, address}`).

- [ ] **Step 1: The failing check is Task 2.1's gate**

Run: `./scripts/ci/validate-openbao-policies.sh; echo "exit $?"`
Expected: the `gcp … "external-secrets"` failure, then `exit 1`.

- [ ] **Step 2: Apply the salvaged stack diff**

```bash
git diff 850ce578 ac62abf2 -- opentofu/gcp/openbao/management | git apply -3 --index
git status --short opentofu/gcp/openbao/management
```

Expected: `A  …/store-of-record.tf`, and `M` for `auth.tf`, `outputs.tf`, `policies.tf`, `variables.tf`,
`variables.tfvars`, `versions.tf` and `workflows.tm.hcl`. Resolve a conflict by keeping `main`'s side and
adding the salvaged lines.

Then in `store-of-record.tf` set `admin_group_alias = "admin"` in the `module "store_of_record"` block
(GP-2). Leave the module name `store_of_record` unchanged: the state addresses depend on it (GP-1).

- [ ] **Step 3: Wire the gate and the module test into CI and `task check`**

`scripts/tasks.yaml`, after `idp-topology`:

```yaml
  openbao-policies:
    desc: Assert every policy an OpenBao JWT role names is defined by its cloud's management stack
    cmds: ["{{.TASKFILE_DIR}}/ci/validate-openbao-policies.sh"]
```

`taskfile.yaml`, in `check`, after `- {task: "ci:idp-topology"}`: `- {task: "ci:openbao-policies"}`.

In `.github/workflows/`, find the step running the IdP check with
`grep -rn 'validate-idp-topology.sh' .github/workflows`. Add a sibling step of the same shape right after it:

```yaml
      - name: OpenBao policy parity
        run: ./scripts/ci/validate-openbao-policies.sh
```

Add the module test the salvage carried, after the pre-commit job's `Validate Opentofu configuration` step
in `ci.yaml`:

```yaml
      - name: Test the OpenBao store-of-record module
        run: |
          tofu -chdir=opentofu/shared/modules/openbao-store-of-record init -backend=false -input=false
          tofu -chdir=opentofu/shared/modules/openbao-store-of-record test
```

- [ ] **Step 4: Gates**

Run: `./scripts/ci/validate-openbao-policies.sh && tofu -chdir=opentofu/gcp/openbao/management init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/gcp/openbao/management validate && (cd opentofu/gcp/openbao/management && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .)`
Expected: `==> OpenBao policy parity: every policy a JWT role names is defined (2 cloud(s)).`, then
`Success! The configuration is valid.`, then trivy exit 0.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/openbao/management .github/workflows scripts/tasks.yaml taskfile.yaml
git commit -m "feat(openbao): GCP's OpenBao gets the Stage 2 mounts, policies and logins"
```

### Task 2.4: `migrate --keys`, for a cluster already pointed at OpenBao

**Files:**
- Modify: `scripts/provision/secret-store.sh`
- Create: `scripts/ci/tests/test-secret-store-migrate-keys.sh`

**Interfaces:** Produces `secret-store.sh migrate --cloud gcp [--project P] --keys "k1,k2 …" [--apply]`.
It walks the named managed-store keys, needs no cluster, and refuses (exit 2) a `--keys` that resolves to
nothing.

- [ ] **Step 1: Bring the test**

```bash
git show ac62abf2:scripts/test-secret-store-migrate-keys.sh \
  | sed -e 's#scripts/secret-store.sh#scripts/provision/secret-store.sh#g' \
        -e 's#/\.\." || exit#/../../.." || exit#' \
  > scripts/ci/tests/test-secret-store-migrate-keys.sh
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-secret-store-migrate-keys.sh; echo "exit $?"`
Expected: `could not extract migrate_keys() from scripts/provision/secret-store.sh`, then `exit 1`.

- [ ] **Step 3: Apply the salvaged change**

```bash
git diff 850ce578 ac62abf2 -- scripts/secret-store.sh \
  | sed 's#\([ab]\)/scripts/secret-store.sh#\1/scripts/provision/secret-store.sh#g' \
  | git apply -3 --index
```

The header's usage block names `migrate --cloud aws|gcp [--context CTX] [--keys K1,K2] [--apply]`.

- [ ] **Step 4: Run it to see it pass**

Run: `bash scripts/ci/tests/test-secret-store-migrate-keys.sh`
Expected: every line `ok`, and `all checks passed`.

- [ ] **Step 5: Commit**

```bash
git add scripts/provision/secret-store.sh scripts/ci/tests/test-secret-store-migrate-keys.sh
git commit -m "feat(secrets): migrate takes explicit keys, for a cluster already pointed at OpenBao"
```

### Task 2.5: The new-lineage switch; gates and PR G-1

**Files:**
- Modify: `scripts/provision/openbao-config.sh`, `website/content/docs/guides/openbao-cross-cloud-failover.md`
- Create: `scripts/ci/tests/test-openbao-new-lineage.sh`

**Interfaces:** Produces `OPENBAO_NEW_LINEAGE=true` for `openbao-config.sh rehydrate`. It initialises a new
lineage only when the bucket listing succeeded and no top-level object carries this node's seal. It never
overrides the moved-aside refusal (`rc=2`). Unset, behaviour is unchanged.

- [ ] **Step 1: Bring the test**

```bash
git show ac62abf2:scripts/test-openbao-new-lineage.sh \
  | sed -e 's#scripts/openbao-config.sh#scripts/provision/openbao-config.sh#g' \
        -e 's#/\.\." || exit#/../../.." || exit#' \
  > scripts/ci/tests/test-openbao-new-lineage.sh
grep -n 'dirname\|openbao-config.sh' scripts/ci/tests/test-openbao-new-lineage.sh
```

Expected: the root resolves `../../..`, and every script path is `scripts/provision/openbao-config.sh`.

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-openbao-new-lineage.sh; echo "exit $?"`
Expected: a non-zero exit whose output says the switch case initialised nothing, or that the function it
lifts is missing.

- [ ] **Step 3: Apply the salvaged switch and its guide section**

```bash
git diff 850ce578 ac62abf2 -- scripts/openbao-config.sh \
  | sed 's#\([ab]\)/scripts/openbao-config.sh#\1/scripts/provision/openbao-config.sh#g' \
  | git apply -3 --index
git diff 850ce578 ac62abf2 -- website/content/docs/guides/openbao-cross-cloud-failover.md | git apply -3 --index
```

Resolve conflicts by keeping `main`'s current rehydrate logic and inserting the switch's branch. The test
pins all five cases from the 09-11 design: no switch; switch with zero own-seal objects; switch with an
own-seal object; switch with everything moved aside; switch with a failed listing.

- [ ] **Step 4: Run it to see it pass, plus the neighbouring OpenBao suites**

Run: `bash scripts/ci/tests/test-openbao-new-lineage.sh && task ci:test`
Expected: the lineage suite passes, then `… 0 failed`.

- [ ] **Step 5: Every gate**

Run: `./scripts/ci/validate-manifests.sh && ./scripts/ci/validate-openbao-policies.sh && ./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh && task check`
Expected: `Invalid: 0, Skipped: 0`, then parity passes, then every command exits 0.

- [ ] **Step 6: Commit and open G-1**

```bash
git add scripts/provision/openbao-config.sh scripts/ci/tests/test-openbao-new-lineage.sh website/content/docs/guides/openbao-cross-cloud-failover.md
git commit -m "feat(openbao): an explicit switch lets a new GCP lineage boot beside a foreign-sealed mirror"
```

Run `create-pr` with base `main`. Title: `fix(openbao): Stage 2 on GCP's OpenBao`. The body says:
- it fixes `gcp_only_broken_since_stage2`;
- it is salvaged from `ac62abf2`, verified live 2026-09-11, with GP-1 and GP-2's deltas;
- **platform fix: it can merge on its own**;
- no ADR: module versus copy is code layout, not a technology choice.

It carries a *Live evidence* section that Task 8.3 fills in.

---

## Phase 3 — G-2: repeatable GKE rebuilds (platform fix)

### Task 3.1: Stage 2 writes the CA, adopts `jwt/gcp-0` and passes `deploy_identity_provider`

**Files:**
- Modify: `opentofu/gcp/gke/init/workflows.tm.hcl` (job `stage2-cilium-and-flux`)
- Create: `scripts/ci/tests/test-gcp-gke-init-workflow.py`

**Interfaces:** Produces a stage 2 that works from a fresh checkout and after a lineage restore.
`scripts/ci/tests/test-gcp-gke-init-workflow.py` exposes `job_body(text, name) -> str`, which Tasks 3.2 and
4.4 extend.

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `fix/gke-rebuild-hygiene`, then `git reset --hard origin/fix/openbao-stage2-gcp`.

- [ ] **Step 2: Write the failing test**

`scripts/ci/tests/test-gcp-gke-init-workflow.py`:

```python
#!/usr/bin/env python3
# requires: python3
"""gcp/gke/init's deploy jobs (GCP parity G-2/G-3). Each check is a bug a live
GCP deploy hit: 09-11 bug 3 (no CA, no jwt adopt in stage 2), the missing
deploy_identity_provider on the inline configure apply, the custom roles that a
teardown deleted (GP-15), and a hosting stage 3 that must configure the IdP
before its clients and mirror them into OpenBao (GP-5)."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
TEXT = (ROOT / "opentofu/gcp/gke/init/workflows.tm.hcl").read_text()


def job_body(text, name):
    m = re.search(r'name\s*=\s*"%s"(.*?)(?=\n  job \{|\nscript "|\Z)' % re.escape(name), text, re.S)
    return m.group(1) if m else ""


fails = []


def before(body, first, second, what):
    i, j = body.find(first), body.find(second)
    if i < 0 or j < 0 or i > j:
        fails.append(what)


s2 = job_body(TEXT, "stage2-cilium-and-flux")
if not s2:
    fails.append("no stage2-cilium-and-flux job")
before(s2, 'openbao-config.sh" ca', "init -lock-timeout", "stage 2 writes OpenBao's CA before init")
before(s2, "init -lock-timeout", "openbao-adopt-jwt-mount.sh", "stage 2 adopts jwt/gcp-0 after init")
before(s2, "openbao-adopt-jwt-mount.sh", "apply -auto-approve", "stage 2 adopts jwt/gcp-0 before its apply")
apply_line = next((l for l in s2.splitlines() if "apply -auto-approve" in l), "")
if "deploy_identity_provider=${global.deploy_identity_provider_gcp}" not in apply_line:
    fails.append("stage 2's apply passes deploy_identity_provider")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
```

- [ ] **Step 3: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-gcp-gke-init-workflow.py; echo "exit $?"`
Expected: four `FAIL` lines (the CA, both adopt checks, `deploy_identity_provider`), then `exit 1`.

- [ ] **Step 4: Rewrite the stage-2 job's heredoc**

Replace the command heredoc of `job { name = "stage2-cilium-and-flux" … }` with the text below. The job's
`name` and `description` lines stay as they are.

```hcl
      ["bash", "-c", <<-BASH
        ${global.cloud_gate}
        set -euo pipefail
        cd ../configure
        # ../configure's vault provider needs the CA chain before init, and a
        # fresh checkout has no .tls/ (gitignored). gke/configure's own deploy
        # writes it; this inline apply bypasses that script (09-11 bug 3).
        bash "${terramate.root.path.fs.absolute}/scripts/provision/openbao-config.sh" ca \
          --cloud gcp --project ogenki-435905 \
          --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file .tls/ca.pem
        ${global.provisioner} init -lock-timeout=5m
        # A restored lineage already holds jwt/gcp-0, and creating it again 400s
        # with "path is already in use". Same call as gke/configure's deploy.
        bash "${terramate.root.path.fs.absolute}/scripts/provision/openbao-adopt-jwt-mount.sh" \
          --cluster-name gcp-0 --url https://bao.priv.gcp.ogenki.io:8200 \
          --root-token-secret-name openbao-priv-gcp-root-token \
          --ca-file .tls/ca.pem --cloud gcp --project ogenki-435905 \
          -- -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' -var='deploy_identity_provider=${global.deploy_identity_provider_gcp}' $${TF_VAR_flux_git_ref:+-var="flux_git_ref=$${TF_VAR_flux_git_ref}"}
        # deploy_identity_provider here too: without it this apply publishes the
        # consumed (AWS) identity_provider_url until the standalone configure run.
        ${global.provisioner} apply -auto-approve -var-file=variables.tfvars -var='cilium_version=${global.cilium_version}' -var='gateway_api_version=${global.gateway_api_version}' -var='flux_operator_version=${global.flux_operator_version}' -var='flux_instance_version=${global.flux_instance_version}' -var='deploy_identity_provider=${global.deploy_identity_provider_gcp}' $${TF_VAR_flux_git_ref:+-var="flux_git_ref=$${TF_VAR_flux_git_ref}"}
        # Forget flux-operator here, in the job that just created it -- NOT only
        # in gke/configure's own `deploy`, which this job bypasses. Left in state,
        # the standalone gke/configure stack plans count=0 against a resource that
        # IS in state, and that is a destroy: a real `helm uninstall`.
        ${global.provisioner} state rm helm_release.flux_operator 2>/dev/null || true
      BASH
      ],
```

- [ ] **Step 5: Run it to see it pass**

Run: `python3 scripts/ci/tests/test-gcp-gke-init-workflow.py && (cd opentofu && terramate list >/dev/null && echo TM-OK)`
Expected: `PASS`, then `TM-OK` (the HCL still parses).

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/gke/init/workflows.tm.hcl scripts/ci/tests/test-gcp-gke-init-workflow.py
git commit -m "fix(gcp): stage 2 writes the CA, adopts jwt/gcp-0 and passes deploy_identity_provider"
```

### Task 3.2: Custom roles `_v3`, kept across teardowns

**Files:**
- Modify: `opentofu/gcp/gke/init/{iam.tf,variables.tf,variables.tfvars,outputs.tf,workflows.tm.hcl}`,
  `opentofu/gcp/gke/configure/kubernetes.tf`, `infrastructure/gcp-0/external-dns/workloadidentity.yaml`,
  `scripts/ci/flux-schema/render-bundle.py`, `scripts/ci/tests/test-gcp-gke-init-workflow.py`
- Create: `scripts/ops/gcp/adopt-custom-roles.sh`, `scripts/ci/tests/test-adopt-custom-roles.sh`,
  `scripts/ci/tests/test-gcp-custom-role-refs.sh`

**Interfaces:**
- Produces `var.custom_role_suffix` (tfvars `"_v3"`) and the output `dns_editor_role` (full role name).
- Produces the ConfigMap key `gcp_dns_editor_role`.
- Produces `adopt-custom-roles.sh --project ID --suffix S [--apply]`. It runs in `opentofu/gcp/gke/init`
  after `tofu init` and imports each existing, non-deleted role absent from state.

- [ ] **Step 1: Write the failing tests**

`scripts/ci/tests/test-gcp-custom-role-refs.sh`:

```bash
#!/usr/bin/env bash
#
# GCP parity GP-15: every custom role carries the generation suffix, and no
# manifest spells a custom role name -- they read ${gcp_dns_editor_role}, so a
# suffix bump never leaves a claim pointing at a deleted role.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
while IFS= read -r line; do
  case "$line" in
    *'${var.custom_role_suffix}"'*) ;;
    *) echo "FAIL iam.tf: $line"; fails=$((fails + 1)) ;;
  esac
done < <(grep -E '^[[:space:]]*role_id[[:space:]]*=' "$ROOT/opentofu/gcp/gke/init/iam.tf")
[ "$(grep -cE '^[[:space:]]*role_id[[:space:]]*=' "$ROOT/opentofu/gcp/gke/init/iam.tf")" -eq 3 ] \
  || { echo "FAIL expected 3 custom roles in iam.tf"; fails=$((fails + 1)); }
hits="$(grep -rnE 'roles/xplane_' --include=*.yaml "$ROOT"/{clusters,infrastructure,security,observability,tooling,apps} 2>/dev/null)"
[ -z "$hits" ] || { echo "FAIL a manifest spells a custom role:"; echo "$hits"; fails=$((fails + 1)); }
grep -q 'gcp_dns_editor_role' "$ROOT/opentofu/gcp/gke/configure/kubernetes.tf" \
  || { echo "FAIL gke-gcp-0-vars has no gcp_dns_editor_role"; fails=$((fails + 1)); }
[ "$fails" -eq 0 ] || exit 1
echo PASS
```

`scripts/ci/tests/test-adopt-custom-roles.sh`:

```bash
#!/usr/bin/env bash
#
# adopt-custom-roles.sh (GCP parity GP-15) with gcloud and tofu stubbed on PATH:
# a live role missing from state is imported, one in state is left alone, an
# absent one is left to the apply, and a soft-deleted one is reported, never imported.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"auth application-default print-access-token"*) echo fake-token ;;
  *"roles describe xplane_dns_editor_v3 "*) echo "" ;;
  *"roles describe xplane_storage_admin_v3 "*) echo "True" ;;
  *"roles describe xplane_role_reader_v3 "*) exit 1 ;;
  *) exit 1 ;;
esac
EOF
cat >"$T/bin/tofu" <<EOF
#!/usr/bin/env bash
case "\$1" in
  state) printf '%s\n' module.gke.google_container_cluster.primary ;;
  import) echo "\$*" >>"$T/imports" ;;
esac
EOF
chmod +x "$T/bin/gcloud" "$T/bin/tofu"
out="$(PATH="$T/bin:$PATH" bash "$ROOT/scripts/ops/gcp/adopt-custom-roles.sh" --project ogenki-435905 --suffix _v3 --apply 2>&1)"; rc=$?
fails=0
check() { if eval "$2"; then echo "  ok   $1"; else echo "  FAIL $1"; fails=1; fi; }
check "exit 0" '[ "$rc" -eq 0 ]'
check "the live dns role is imported" 'grep -q "import -var-file=variables.tfvars google_project_iam_custom_role.crossplane_dns projects/ogenki-435905/roles/xplane_dns_editor_v3" "$T/imports"'
check "exactly one import" '[ "$(wc -l <"$T/imports")" -eq 1 ]'
check "the soft-deleted storage role is reported" 'grep -q "\[deleted\].*xplane_storage_admin_v3" <<<"$out"'
check "the absent reader role is left to the apply" 'grep -q "\[absent \].*xplane_role_reader_v3" <<<"$out"'
[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
```

In `scripts/ci/tests/test-gcp-gke-init-workflow.py`, add before `for f in fails:`:

```python
s1 = job_body(TEXT, "stage1-cluster")
before(s1, "adopt-custom-roles.sh", "apply -auto-approve", "stage 1 adopts the kept custom roles before its apply")
confirm = job_body(TEXT, "confirm")
for addr in ("crossplane_dns", "crossplane_storage", "crossplane_role_reader"):
    if f"google_project_iam_custom_role.{addr}" not in confirm or "state rm" not in confirm:
        fails.append(f"the destroy keeps google_project_iam_custom_role.{addr} out of the teardown")
```

The file has two `stage1-cluster` jobs (`deploy` and `deploy-stage1`), and `job_body` returns the first. Both
get the same edit in Step 3.

- [ ] **Step 2: Run them to see them fail**

Run: `bash scripts/ci/tests/test-gcp-custom-role-refs.sh; bash scripts/ci/tests/test-adopt-custom-roles.sh; python3 scripts/ci/tests/test-gcp-gke-init-workflow.py; echo done`
Expected:
- three `FAIL iam.tf: …` lines, a `FAIL a manifest spells a custom role:` naming
  `infrastructure/gcp-0/external-dns/workloadidentity.yaml`, and the ConfigMap failure;
- the adopt test fails (the script does not exist);
- the workflow test prints two `FAIL` families.

- [ ] **Step 3: Implement**

`opentofu/gcp/gke/init/variables.tf`:

```hcl
# GCP reserves a deleted custom role's ID for 37 days and allows undelete for 7
# only, so a rebuild inside that window cannot recreate it (09-11 bug 2). The
# destroy now keeps the roles (they grant nothing without the bindings it does
# destroy) and the deploy adopts them; this suffix moved past the IDs already
# burned (unsuffixed before 2026-09-11, `_v2` on 2026-09-14).
variable "custom_role_suffix" {
  description = "Generation suffix on the three custom role IDs; bump only if a generation is lost"
  type        = string
  default     = ""
}
```

`variables.tfvars`: add `custom_role_suffix = "_v3"`. In `iam.tf`, the three `role_id`s become
`"xplane_dns_editor${var.custom_role_suffix}"`, `"xplane_storage_admin${var.custom_role_suffix}"` and
`"xplane_role_reader${var.custom_role_suffix}"`. `outputs.tf`:

```hcl
output "dns_editor_role" {
  description = "Full name of the custom DNS role, suffix included, for GCPWorkloadIdentity claims"
  value       = google_project_iam_custom_role.crossplane_dns.name
}
```

`opentofu/gcp/gke/configure/kubernetes.tf`, in `data`, under `# GCP-specific.`:

```hcl
      # Custom role names carry a generation suffix (gke/init var.custom_role_suffix),
      # so claims read the name rather than spelling it.
      gcp_dns_editor_role = local.init.dns_editor_role
```

In `infrastructure/gcp-0/external-dns/workloadidentity.yaml`, replace
`projects/${project_id}/roles/xplane_dns_editor` with `${gcp_dns_editor_role}`. Handle every other hit
Step 2's grep listed the same way. In `scripts/ci/flux-schema/render-bundle.py` `FIXTURE_VARS`, after
`"workload_pool"`:

```python
    # gcp-0 only: the custom DNS role's full name, generation suffix included.
    "gcp_dns_editor_role": "projects/ogenki-435905/roles/xplane_dns_editor_v3",
```

`scripts/ops/gcp/adopt-custom-roles.sh` (`chmod +x`):

```bash
#!/usr/bin/env bash
#
# Adopt gke/init's three custom IAM roles when they already exist.
#
# WHY: GCP reserves a deleted custom role's ID for 37 days and can undelete it
# for 7 only, so a rebuild within 37 days of a teardown that deleted the roles
# fails on the first create. gke/init's destroy therefore drops them from state
# instead of deleting them, and every deploy adopts them here (GCP parity GP-15).
#
# Usage (from opentofu/gcp/gke/init, after `tofu init`):
#   adopt-custom-roles.sh --project ID --suffix S [--apply]
# Dry-run unless --apply.
set -euo pipefail

# shellcheck source=scripts/lib/gcloud-adc.sh
. "$(dirname "$0")/../../lib/gcloud-adc.sh"

PROJECT="" SUFFIX="" APPLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --project) PROJECT="$2"; shift 2 ;;
    --suffix)  SUFFIX="$2"; shift 2 ;;
    --apply)   APPLY=true; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done
[ -n "$PROJECT" ] || { echo "--project is required" >&2; exit 2; }

ROLES=(
  "google_project_iam_custom_role.crossplane_dns=xplane_dns_editor"
  "google_project_iam_custom_role.crossplane_storage=xplane_storage_admin"
  "google_project_iam_custom_role.crossplane_role_reader=xplane_role_reader"
)

in_state="$(tofu state list 2>/dev/null || true)"
for entry in "${ROLES[@]}"; do
  addr="${entry%%=*}"
  id="${entry#*=}${SUFFIX}"
  name="projects/${PROJECT}/roles/${id}"
  if grep -qxF "$addr" <<<"$in_state"; then
    echo "[ok     ] ${addr} is in state"
    continue
  fi
  if ! deleted="$(gcp_gcloud iam roles describe "$id" --project "$PROJECT" --format='value(deleted)' 2>/dev/null)"; then
    echo "[absent ] ${name}: the apply creates it"
    continue
  fi
  if [ "$deleted" = "True" ]; then
    echo "[deleted] ${name} is soft-deleted: the provider undeletes it within 7 days; after that, bump custom_role_suffix" >&2
    continue
  fi
  if [ "$APPLY" = true ]; then
    tofu import -var-file=variables.tfvars "$addr" "$name"
    echo "[adopted] ${addr} <- ${name}"
  else
    echo "[dry-run] would import ${addr} <- ${name}"
  fi
done
```

If `gcp_gcloud` in `scripts/lib/gcloud-adc.sh` wraps `gcloud` in another way, the stub in the test still
receives the same arguments. Check with `grep -n 'gcp_gcloud()' -A8 scripts/lib/gcloud-adc.sh` and extend the
stub's `case` with any extra token call it makes.

In `opentofu/gcp/gke/init/workflows.tm.hcl`, add to **both** `stage1-cluster` jobs, between `validate` and
`trivy`:

```hcl
        bash "${terramate.root.path.fs.absolute}/scripts/ops/gcp/adopt-custom-roles.sh" \
          --project ogenki-435905 \
          --suffix "$(awk -F'"' '/^custom_role_suffix/{print $2}' variables.tfvars)" --apply
```

In the destroy script's `confirm` job, after `${global.provisioner} init -lock-timeout=5m`:

```hcl
        # Keep the custom roles (GCP parity GP-15): a deleted role ID stays
        # reserved for 37 days, so the next rebuild could not recreate it. They
        # grant nothing on their own; the bindings using them are destroyed as
        # usual, and the next deploy adopts them (adopt-custom-roles.sh).
        for addr in google_project_iam_custom_role.crossplane_dns google_project_iam_custom_role.crossplane_storage google_project_iam_custom_role.crossplane_role_reader; do
          ${global.provisioner} state rm "$addr" 2>/dev/null || true
        done
```

- [ ] **Step 4: Run them to see them pass**

Run: `bash scripts/ci/tests/test-gcp-custom-role-refs.sh && bash scripts/ci/tests/test-adopt-custom-roles.sh && python3 scripts/ci/tests/test-gcp-gke-init-workflow.py && tofu -chdir=opentofu/gcp/gke/init init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/gcp/gke/init validate && python3 scripts/ci/flux-schema/check-substitution.py`
Expected: `PASS`, then `all checks passed`, `PASS`, `Success! The configuration is valid.`, and
check-substitution exit 0.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/gke infrastructure/gcp-0/external-dns scripts/ops/gcp/adopt-custom-roles.sh scripts/ci
git commit -m "fix(gcp): custom roles take a generation suffix and survive a teardown"
```

### Task 3.3: Teardown reports what blocks a VPC delete; gates and PR G-2

**Files:**
- Modify: `scripts/ops/teardown/teardown.sh`
- Create: `scripts/ci/tests/test-teardown-gcp-sweep.sh`

**Interfaces:** Produces two new rows in `teardown.sh`'s GCP report, `Target pools` and
`k8s-* firewall rules`, counted like `Forwarding rules`.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-teardown-gcp-sweep.sh`:

```bash
#!/usr/bin/env bash
#
# memory gke_lb_orphans_block_vpc_delete: a deleted GKE cluster leaves a target
# pool and k8s-* firewall rules behind, and the firewall rules block the VPC
# delete. teardown.sh --verify-only must report both, and fail while they exist.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat >"$T/bin/gcloud" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  "projects describe"*) exit 0 ;;
  *"target-pools list"*) echo a2c53478 ;;
  *"firewall-rules list"*) printf '%s\n' k8s-fw-a2c53478 k8s-a6e2efd9258d71a1-node-http-hc ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$T/bin/gcloud"
out="$(TM_CLOUD=gcp PATH="$T/bin:$PATH" bash "$ROOT/scripts/ops/teardown/teardown.sh" --verify-only 2>&1)"; rc=$?
fails=0
grep -q 'Target pools' <<<"$out" || { echo "FAIL no Target pools row"; fails=1; }
grep -q 'k8s-\* firewall rules' <<<"$out" || { echo "FAIL no k8s-* firewall rules row"; fails=1; }
[ "$rc" -ne 0 ] || { echo "FAIL leftovers must fail the verify"; fails=1; }
[ "$fails" -eq 0 ] && echo PASS
exit "$fails"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-teardown-gcp-sweep.sh; echo "exit $?"`
Expected: `FAIL no Target pools row`, `FAIL no k8s-* firewall rules row` and `FAIL leftovers must fail the verify`, then `exit 1`.

- [ ] **Step 3: Implement**

In `scripts/ops/teardown/teardown.sh`, right after the `report "Forwarding rules" …` call:

```bash
    # A deleted cluster leaves its LoadBalancers' target pools and k8s-* firewall
    # rules behind, in no tofu state, and the firewall rules block the VPC delete
    # (memory gke_lb_orphans_block_vpc_delete). The health-check rule is named
    # after the node pool, not the LB, hence the prefix filter.
    report "Target pools" "$(gcloud compute target-pools list --project "$project" \
      --format='value(name)' 2>/dev/null)"
    report "k8s-* firewall rules" "$(gcloud compute firewall-rules list --project "$project" \
      --filter='name~^k8s-' --format='value(name)' 2>/dev/null)"
```

- [ ] **Step 4: Run it to see it pass**

Run: `bash scripts/ci/tests/test-teardown-gcp-sweep.sh`
Expected: `PASS`.

- [ ] **Step 5: Every gate**

Run: `(cd opentofu/gcp/gke/init && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .) && tofu -chdir=opentofu/gcp/gke/configure init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/gcp/gke/configure validate && ./scripts/ci/validate-manifests.sh && task check`
Expected: trivy exit 0, `Success! The configuration is valid.`, `Invalid: 0, Skipped: 0`, and exit 0.

- [ ] **Step 6: Commit and open G-2**

```bash
git add scripts/ops/teardown/teardown.sh scripts/ci/tests/test-teardown-gcp-sweep.sh
git commit -m "fix(teardown): report the target pools and k8s-* firewall rules a GKE cluster leaves"
```

Run `create-pr` with base `fix/openbao-stage2-gcp`. Title: `fix(gcp): GKE rebuilds that can repeat`. The body
lists 09-11 bugs 2 and 3, the missing `deploy_identity_provider` and the orphan sweep, and says: **platform
fix, it can merge on its own after G-1**.

---

## Phase 4 — G-3: a GCP-hosted IdP keeps its clients in step (platform fix)

### Task 4.1: One managed-store → OpenBao map

**Files:**
- Create: `scripts/lib/bao-map.sh`, `scripts/ci/tests/test-bao-map.sh`
- Modify: `scripts/provision/secret-store.sh`

**Interfaces:** Produces `bao_target_for KEY`. It prints `mount/path` and returns 0, or returns 1 when the key is unmapped.
`secret-store.sh` sources it, and so does `zitadel-oidc-clients.sh` (Task 4.2).

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `fix/gcp-hosted-idp`, then `git reset --hard origin/fix/gke-rebuild-hygiene`.

- [ ] **Step 2: Write the failing test**

`scripts/ci/tests/test-bao-map.sh`:

```bash
#!/usr/bin/env bash
#
# The managed-store -> OpenBao map lives in one file (GCP parity GP-5): migrate
# copies through it, and the OIDC sync mirrors through it. Two copies would drift
# and put a client secret where no ExternalSecret reads it.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
check() { if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1: want '$2' got '$3'"; fails=1; fi; }
# shellcheck source=scripts/lib/bao-map.sh
. "$ROOT/scripts/lib/bao-map.sh" || { echo "FAIL cannot source scripts/lib/bao-map.sh"; exit 1; }
check "grafana-envvars" "platform/victoria-metrics/grafana-envvars" "$(bao_target_for observability-victoria-metrics-k8s-stack-grafana-envvars)"
check "harbor-oidc" "platform/harbor/oidc" "$(bao_target_for harbor-oidc)"
check "app-wizard llm" "apps/app-wizard/llm" "$(bao_target_for apps-app-wizard-llm)"
bao_target_for openbao-oidc >/dev/null; check "openbao-oidc is unmapped" "1" "$?"
grep -q '^bao_target_for()' "$ROOT/scripts/provision/secret-store.sh" && { echo "  FAIL secret-store.sh still defines its own copy"; fails=1; }
grep -q 'lib/bao-map.sh' "$ROOT/scripts/provision/secret-store.sh" || { echo "  FAIL secret-store.sh does not source the map"; fails=1; }
[ "$fails" -eq 0 ] && echo "all checks passed"
exit "$fails"
```

- [ ] **Step 3: Run it to see it fail**

Run: `bash scripts/ci/tests/test-bao-map.sh; echo "exit $?"`
Expected: `FAIL cannot source scripts/lib/bao-map.sh`, then `exit 1`.

- [ ] **Step 4: Move the function**

Create `scripts/lib/bao-map.sh`:

```bash
#!/usr/bin/env bash
# Managed-store key -> OpenBao path, the one copy (GCP parity GP-5). Read by
# secret-store.sh's `migrate` and by zitadel-oidc-clients.sh's --mirror-openbao.
# Why the map is explicit and what must stay out of it: see the comment kept
# above the function below.
```

Then cut the comment block starting `# Managed-store key -> OpenBao path, for \`migrate\`.` and the whole
`bao_target_for() { … }` function from `scripts/provision/secret-store.sh`, and paste them unchanged below
that header. In `secret-store.sh`, next to the existing `. "$(dirname "$0")/../lib/gcloud-adc.sh"`, add:

```bash
# shellcheck source=scripts/lib/bao-map.sh
. "$(dirname "$0")/../lib/bao-map.sh"
```

- [ ] **Step 5: Run it to see it pass, with migrate's suite**

Run: `bash scripts/ci/tests/test-bao-map.sh && bash scripts/ci/tests/test-secret-store-migrate-keys.sh`
Expected: `all checks passed` twice.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/bao-map.sh scripts/provision/secret-store.sh scripts/ci/tests/test-bao-map.sh
git commit -m "refactor(secrets): one managed-store to OpenBao map, shared"
```

### Task 4.2: The OIDC sync mirrors consumer secrets into OpenBao

**Files:**
- Modify: `scripts/provision/zitadel-oidc-clients.sh`
- Create: `scripts/ci/tests/test-zitadel-oidc-clients-mirror.sh`

**Interfaces:**
- Consumes `bao_target_for` (Task 4.1), plus `openbao_token_config_write` and `openbao_req` from
  `scripts/lib/openbao-api.sh`.
- Produces the flag `--mirror-openbao` (requires `--openbao-url`) and two functions:
  - `mirror_to_openbao KEY` (payload on stdin, runs in a subshell);
  - `store_write_and_mirror KEY` (payload on stdin).

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-zitadel-oidc-clients-mirror.sh`:

```bash
#!/usr/bin/env bash
# requires: jq
#
# --mirror-openbao (GCP parity GP-5): a fresh directory re-registers every client
# each build, and gcp-0's consumers read OpenBao. The mirror merges into the mapped
# path (admin credentials survive), skips unmapped keys, and does nothing unset.
# mirror_to_openbao() is lifted out of the script, so this tests the code that ships.
set -uo pipefail
cd "$(dirname "$0")/../../.." || exit 1
S=scripts/provision/zitadel-oidc-clients.sh
fail=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fail=1; }

body="$(sed -n '/^mirror_to_openbao() (/,/^)/p' "$S")"
[ -n "$body" ] || { echo "could not extract mirror_to_openbao() from $S" >&2; exit 1; }
# shellcheck source=scripts/lib/bao-map.sh
. scripts/lib/bao-map.sh
eval "$body"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
openbao_token_config_write() { : >"$1"; }
openbao_req() {
    printf '%s %s\n' "$1" "$2" >>"$T/calls"
    case "$1" in
        GET)  printf '%s' '{"data":{"data":{"GF_SECURITY_ADMIN_USER":"admin","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"old"}}}' ;;
        POST) cat >"$T/body" ;;
    esac
}

MIRROR_OPENBAO=true
OPENBAO_ROOT_TOKEN_SECRET=fixture
printf '%s' '{"GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new"}' \
  | mirror_to_openbao observability-victoria-metrics-k8s-stack-grafana-envvars >/dev/null
grep -qx 'POST platform/data/victoria-metrics/grafana-envvars' "$T/calls" \
  && ok "grafana-envvars is written to its mapped path" || bad "grafana-envvars path: $(cat "$T/calls")"
[ "$(jq -c '.data' "$T/body")" = '{"GF_SECURITY_ADMIN_USER":"admin","GF_AUTH_GENERIC_OAUTH_CLIENT_ID":"new"}' ] \
  && ok "merged: the admin user kept, the client id replaced" || bad "merge: $(cat "$T/body")"

: >"$T/calls"
printf '%s' '{"client_id":"x"}' | mirror_to_openbao openbao-oidc
[ ! -s "$T/calls" ] && ok "openbao-oidc (unmapped) never reaches OpenBao" || bad "an unmapped key reached OpenBao"

: >"$T/calls"
MIRROR_OPENBAO=false
printf '%s' '{"a":"b"}' | mirror_to_openbao harbor-oidc
[ ! -s "$T/calls" ] && ok "without --mirror-openbao nothing is written" || bad "wrote without the flag"

grep -q -- '--mirror-openbao) MIRROR_OPENBAO="true"; shift ;;' "$S" && ok "--mirror-openbao is parsed" || bad "--mirror-openbao is not parsed"
[ "$(grep -c 'store_write_and_mirror "\$key"' "$S")" -eq 2 ] \
  && ok "both consumer writes go through store_write_and_mirror" || bad "a consumer write bypasses the mirror"

[ "$fail" -eq 0 ] && echo "all checks passed"
exit "$fail"
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-zitadel-oidc-clients-mirror.sh; echo "exit $?"`
Expected: `could not extract mirror_to_openbao() from scripts/provision/zitadel-oidc-clients.sh`, then `exit 1`.

- [ ] **Step 3: Implement**

In `scripts/provision/zitadel-oidc-clients.sh`:

1. After `. "$(dirname "$0")/../lib/openbao-api.sh"`:

```bash
# shellcheck source=scripts/lib/bao-map.sh
. "$(dirname "$0")/../lib/bao-map.sh"
```

2. After `OPENBAO_CA_FILE=""`:

```bash
# --mirror-openbao: also write each consumer secret to the OpenBao path its
# ExternalSecret reads. Only gcp-0's own sync sets it (GCP parity GP-5): a fresh
# directory re-registers every client on every build, and gcp-0 reads OpenBao.
MIRROR_OPENBAO="false"
```

3. In the argument `case`, after `--openbao-ca-file)`:

```bash
        --mirror-openbao) MIRROR_OPENBAO="true"; shift ;;
```

4. After the `if [ -n "$OPENBAO_URL" ]; then … fi` validation block:

```bash
if [ "$MIRROR_OPENBAO" = "true" ] && [ -z "$OPENBAO_URL" ]; then
    echo "--mirror-openbao requires --openbao-url" >&2; exit 2
fi
```

5. Right before `reconcile_openbao_oidc() (`:

```bash
# Mirror one consumer secret into the OpenBao path its ExternalSecret reads
# (--mirror-openbao). Merges into what is there -- grafana-envvars also carries
# the generated admin credentials -- and the payload wins on a shared key.
# Unmapped keys (openbao-oidc, headlamp-oauth2-proxy) are read from the managed
# store, so they are left alone. A subshell, like reconcile_openbao_oidc, so its
# token file and trap stay local; the secret goes through stdin, never argv.
mirror_to_openbao() (
    key="$1"
    [ "${MIRROR_OPENBAO:-false}" = "true" ] || exit 0
    target="$(bao_target_for "$key")" || exit 0
    mount="${target%%/*}"
    path="${target#*/}"
    payload="$(cat)"
    OPENBAO_TOKEN_CONFIG="$(umask 077 && mktemp -t openbao-mirror-curl.XXXXXX)" || exit 1
    trap 'rm -f "$OPENBAO_TOKEN_CONFIG"' EXIT
    if ! openbao_token_config_write "$OPENBAO_TOKEN_CONFIG" "${OPENBAO_ROOT_TOKEN_SECRET:-}"; then
        echo "[FAILED ] ${key} -- no OpenBao root token readable from ${OPENBAO_ROOT_TOKEN_SECRET:-<unset>}" >&2
        exit 1
    fi
    current="$(openbao_req GET "${mount}/data/${path}" 2>/dev/null | jq -c '.data.data // {}' 2>/dev/null)" || current=""
    [ -n "$current" ] || current='{}'
    if ! printf '%s\n%s\n' "$current" "$payload" \
        | jq -c -s '{data: (.[0] * .[1])}' \
        | openbao_req POST "${mount}/data/${path}" --data-binary @- >/dev/null; then
        echo "[FAILED ] ${key} -- not mirrored to ${target}" >&2
        exit 1
    fi
    echo "[mirrored] ${key} -> ${target}"
)

# The managed store first, then the mirror, with one payload.
store_write_and_mirror() {
    local key="$1" payload
    payload="$(cat)"
    printf '%s' "$payload" | store_write "$key" || return 1
    printf '%s' "$payload" | mirror_to_openbao "$key"
}
```

6. The two consumer writes (`grep -n 'store_write "\$key"' scripts/provision/zitadel-oidc-clients.sh` →
   two lines):
   - `printf '%s' "$desired" | store_write "$key"` becomes `printf '%s' "$desired" | store_write_and_mirror "$key"`;
   - `merge_secret "$key" "$consumer" "$client_id" "$client_secret" | store_write "$key"` becomes
     `… | store_write_and_mirror "$key"`.

   Keep whatever follows each (`|| exit 1` and the like).

7. In the header's usage block, add `[--openbao-url U --openbao-root-token-secret S --openbao-ca-file F [--mirror-openbao]]`
   to the `--cloud gcp` line.

- [ ] **Step 4: Run it to see it pass, with the script's neighbouring suites**

Run: `bash scripts/ci/tests/test-zitadel-oidc-clients-mirror.sh && task ci:test`
Expected: `all checks passed`, then `… 0 failed`. The existing `test-zitadel-*` suites stay green.

- [ ] **Step 5: Commit**

```bash
git add scripts/provision/zitadel-oidc-clients.sh scripts/ci/tests/test-zitadel-oidc-clients-mirror.sh
git commit -m "feat(zitadel): mirror consumer secrets into the OpenBao path they are read from"
```

### Task 4.3: `zitadel_project_id` through Secret Manager

**Files:**
- Modify: `scripts/provision/zitadel-oidc-clients.sh`, `opentofu/gcp/gke/configure/{data.tf,locals.tf,kubernetes.tf}`
- Create: `scripts/ci/tests/test-gcp-zitadel-project-id.sh`

**Interfaces:**
- Produces the Secret Manager secret `zitadel-project-id` (`{"project_id": "<id>"}`), written by a GCP hosting
  sync with `--apply`.
- Produces `local.zitadel_project_id` in `gke/configure`: the secret when hosting and present, else
  `var.zitadel_project_id`.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-gcp-zitadel-project-id.sh`:

```bash
#!/usr/bin/env bash
#
# GCP parity GP-4: a fresh directory has a new project id every build. The sync
# publishes it, and gke/configure reads it, so the standalone configure apply
# that runs after stage 3 cannot put the committed id back.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
C="$ROOT/opentofu/gcp/gke/configure"
fails=0
f() { echo "FAIL $*"; fails=$((fails + 1)); }
grep -Eq '^[[:space:]]*zitadel_project_id[[:space:]]*=[[:space:]]*local\.zitadel_project_id[[:space:]]*$' "$C/kubernetes.tf" || f "the ConfigMap does not publish local.zitadel_project_id"
grep -q 'data "google_secret_manager_secrets" "zitadel_project"' "$C/data.tf" || f "configure does not list zitadel-project-id before reading it"
grep -q 'data "google_secret_manager_secret_version" "zitadel_project"' "$C/data.tf" || f "configure does not read zitadel-project-id"
grep -Eq 'zitadel_project_id[[:space:]]*=.*var\.zitadel_project_id' "$C/locals.tf" || f "no fallback to the committed id"
grep -q 'store_write zitadel-project-id' "$ROOT/scripts/provision/zitadel-oidc-clients.sh" || f "the sync never publishes zitadel-project-id"
[ "$fails" -eq 0 ] || exit 1
echo PASS
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-gcp-zitadel-project-id.sh; echo "exit $?"`
Expected: five `FAIL` lines, then `exit 1`.

- [ ] **Step 3: Implement**

`opentofu/gcp/gke/configure/data.tf`, appended:

```hcl
# This directory's ZITADEL project id when the cluster HOSTS it (GCP parity GP-4).
# A fresh directory gets a new id every build; zitadel-oidc-clients.sh publishes
# it here in stage 3. Read at plan time so this stack's later apply agrees with
# the value the sync patched into the ConfigMap. Listed before it is read: absent
# is "first build", and var.zitadel_project_id stands in until stage 3.
data "google_secret_manager_secrets" "zitadel_project" {
  count   = var.deploy_identity_provider ? 1 : 0
  project = var.project_id
  filter  = "name:zitadel-project-id"
}

data "google_secret_manager_secret_version" "zitadel_project" {
  count   = local.zitadel_project_secret_present ? 1 : 0
  secret  = "zitadel-project-id"  # pragma: allowlist secret
  project = var.project_id
}
```

`opentofu/gcp/gke/configure/locals.tf`, inside `locals { … }`:

```hcl
  # The list filter is a substring match; contains() makes it exact.
  zitadel_project_secret_present = var.deploy_identity_provider && contains(
    [for s in try(data.google_secret_manager_secrets.zitadel_project[0].secrets, []) : s.secret_id],
    "zitadel-project-id"
  )
  # Not secret: nonsensitive() keeps the whole ConfigMap out of (sensitive) diffs.
  zitadel_project_id = local.zitadel_project_secret_present ? nonsensitive(jsondecode(data.google_secret_manager_secret_version.zitadel_project[0].secret_data)["project_id"]) : var.zitadel_project_id
```

In `kubernetes.tf`, `zitadel_project_id = var.zitadel_project_id` becomes
`zitadel_project_id = local.zitadel_project_id`. Its comment gains: "Live-reconciled when this cluster hosts
ZITADEL: see local.zitadel_project_id."

In `scripts/provision/zitadel-oidc-clients.sh`, find the call site with
`grep -n 'reconcile_workforce_audience "' scripts/provision/zitadel-oidc-clients.sh` (one line, inside the
sync function). Right after it, with the same project-id variable that call passes (written `$project_id`
here; use the local name that line uses):

```bash
    # GCP hosting: publish this directory's project id for gke/configure, which
    # reads it at plan time (GCP parity GP-4). A fresh directory gets a new id
    # every build, and the committed one would otherwise come back on the next
    # configure apply.
    if [ "$CLOUD" = "gcp" ] && [ "$IDP_CLOUD" = "$CLOUD" ] && [ "$APPLY" = "true" ] \
       && [ "$project_id" != "DRYRUN-PROJECT" ]; then
        jq -cn --arg p "$project_id" '{project_id: $p}' | store_write zitadel-project-id
        echo "project: zitadel-project-id -> ${project_id}"
    fi
```

- [ ] **Step 4: Run it to see it pass**

Run: `bash scripts/ci/tests/test-gcp-zitadel-project-id.sh && tofu -chdir=opentofu/gcp/gke/configure validate && ./scripts/ci/validate-idp-topology.sh && python3 scripts/ci/flux-schema/check-substitution.py`
Expected: `PASS`, `Success! The configuration is valid.`, the topology line unchanged (`aws hosts`), and
check-substitution exit 0.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/gke/configure scripts/provision/zitadel-oidc-clients.sh scripts/ci/tests/test-gcp-zitadel-project-id.sh
git commit -m "fix(gcp): a hosted ZITADEL's project id reaches gke/configure through Secret Manager"
```

### Task 4.4: Stage 3 configures the IdP, then the clients with OpenBao; gates and PR G-3

**Files:**
- Modify: `opentofu/gcp/gke/init/workflows.tm.hcl` (job `stage3-secrets-and-oidc`, the hosting branch),
  `scripts/ci/tests/test-gcp-gke-init-workflow.py`

**Interfaces:** Consumes `--mirror-openbao` (4.2) and `zitadel-idp.sh sync`. Produces a hosting stage 3 that
leaves a fresh ZITADEL with its Google IdP, the groups Action and every client, mirrored into OpenBao, with
`auth/oidc` rotated.

- [ ] **Step 1: Extend the failing test**

In `test-gcp-gke-init-workflow.py`, before `for f in fails:`:

```python
s3 = job_body(TEXT, "stage3-secrets-and-oidc")
hosting = s3[s3.find("== registering the OIDC clients"):] if "== registering the OIDC clients" in s3 else ""
before(s3, 'zitadel-idp.sh" sync', "== registering the OIDC clients", "a hosting stage 3 configures the IdP and Action before its clients")
for flag in ("--openbao-url", "--openbao-root-token-secret openbao-priv-gcp-root-token", "--openbao-ca-file", "--mirror-openbao"):
    if flag not in hosting:
        fails.append(f"the hosting clients sync passes {flag}")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-gcp-gke-init-workflow.py; echo "exit $?"`
Expected: five `FAIL` lines (the IdP ordering and four flags), then `exit 1`.

- [ ] **Step 3: Implement**

In `stage3-secrets-and-oidc`, the hosting branch, insert right before `echo "== registering the OIDC clients"`:

```hcl
        # A fresh directory (GCP parity GP-3) has neither the Google IdP nor the
        # groups Action; both must exist before the clients, or no token carries
        # a groups claim.
        echo "== registering the Google IdP and the groups Action"
        IDP_URL="https://auth.$${PUBLIC_DOMAIN}" \
          bash "$${ROOT}/scripts/provision/zitadel-idp.sh" sync \
            --cluster "$${NAME}" --cloud gcp --project "$${PROJECT}" --apply || \
          echo "[warn] IdP registration failed; re-run it by hand"
```

In the clients sync call right below it, add before `--apply`:

```hcl
            --openbao-url "https://bao.$${PRIVATE_DOMAIN}:8200" \
            --openbao-root-token-secret openbao-priv-gcp-root-token \
            --openbao-ca-file "$${ROOT}/opentofu/gcp/gke/configure/.tls/ca.pem" \
            --mirror-openbao \
```

The CA file is the one stage 2 wrote in this same run (Task 3.1).

- [ ] **Step 4: Run it to see it pass**

Run: `python3 scripts/ci/tests/test-gcp-gke-init-workflow.py && (cd opentofu && terramate list >/dev/null && echo TM-OK)`
Expected: `PASS`, then `TM-OK`.

- [ ] **Step 5: Every gate**

Run: `./scripts/ci/validate-manifests.sh && ./scripts/ci/validate-openbao-policies.sh && ./scripts/ci/validate-idp-topology.sh && task check`
Expected: `Invalid: 0, Skipped: 0`, parity passes, the topology is `aws hosts`, and exit 0.

- [ ] **Step 6: Commit and open G-3**

```bash
git add opentofu/gcp/gke/init/workflows.tm.hcl scripts/ci/tests/test-gcp-gke-init-workflow.py
git commit -m "fix(gcp): a hosting stage 3 registers the IdP, then mirrors every client into OpenBao"
```

Run `create-pr` with base `fix/gke-rebuild-hygiene`. Title: `fix(gcp): a GCP-hosted ZITADEL keeps its consumers in step`.
The body names 09-11 bug 9 (the sync wrote Secret Manager only) and bug 8 (`zitadel_project_id` committed per
directory). It says the change is **inert while AWS is primary** (the hosting branch does not run) and is a
**platform fix that can merge on its own after G-2**.

---

## Phase 5 — G-4: GCP is primary, with a fresh ZITADEL (platform decision)

### Task 5.1: ADR and the topology flip

**Files:**
- Modify: `opentofu/config.tm.hcl`, `clusters/gcp-0/security/zitadel.yaml`, `clusters/aws-0/security/zitadel.yaml`,
  `opentofu/AGENTS.md`, `website/content/docs/decisions/_index.md`
- Create: `website/content/docs/decisions/00NN-gcp-primary-platform.md`

**Interfaces:** Produces `global.deploy_identity_provider_gcp = true`. The gcp-0 `zitadel` Kustomization is
unsuspended and aws-0's is suspended.

- [ ] **Step 1: Worktree**

`EnterWorktree` with branch `feat/gcp-primary`, then `git reset --hard origin/fix/gcp-hosted-idp`.

- [ ] **Step 2: The failing check: flip only `primary_cloud`**

In `opentofu/config.tm.hcl`, set `primary_cloud = "gcp"`.
Run: `./scripts/ci/validate-idp-topology.sh; echo "exit $?"`
Expected:
`FAIL: aws-0 is not on the primary cloud (gcp) but would run its own identity provider.` and
`FAIL: gcp-0 is on the primary cloud (gcp) but its identity provider is suspended.`, then
`FAIL: expected exactly one cluster to host the identity provider, found 0.`, then `exit 1`.

- [ ] **Step 3: Flip both Kustomizations and record the decision**

- `clusters/gcp-0/security/zitadel.yaml`: `suspend: false`.
  - The `── INACTIVE ──` header block becomes one paragraph: "ACTIVE: GCP is primary (ADR-00NN). This is the
    platform's only directory, fresh every build; see security/gcp-0/zitadel/kustomization.yaml."
  - The `# SUSPENDED:` comment above `suspend` goes.
- `clusters/aws-0/security/zitadel.yaml`: add `suspend: true` under `spec:`, with
  `# GCP is primary (ADR-00NN): aws-0 does not host, and a GCP-only platform has no aws-0 at all.`
- `opentofu/config.tm.hcl`, above `primary_cloud`, one line:
  `# "gcp" since 2026-09-29 (ADR-00NN): AWS keeps Route53, the federation, the state bucket and the lineage stacks.`
- `opentofu/AGENTS.md`, under *Choosing the cloud — `TM_CLOUD`*, one paragraph: "The platform is GCP-primary
  (ADR-00NN). `TM_CLOUD=gcp` is the normal deploy. It still needs AWS credentials, for the two shared stacks'
  S3 state and the federation role. Every AWS stack prints `[skip]`, and `aws/openbao/lineage` is kept."

The ADR, `website/content/docs/decisions/00NN-gcp-primary-platform.md`, uses `template.md`:

```markdown
# ADR-00NN: GCP is the primary cloud; AWS keeps the essentials

**Status:** Accepted (2026-09-29) · **Supersedes in part:** ADR-0027's "relocation carries the directory's data"

## Context
The agent factory and the platform run on one cluster. Running aws-0 and gcp-0 side by side doubles the cost
and the operations for no user. ADR-0027 made placement a single switch, `primary_cloud`.

## Decision
- **GCP is primary.** gcp-0 hosts ZITADEL and runs against GCP's own OpenBao lineage (`gcpckms`).
- **AWS keeps four things:** the Route53 zone, the AWS↔GCP federation (`opentofu/shared/aws-gcp-federation`),
  the S3 state bucket, and the OpenBao lineage stacks. No AWS cluster, no AWS OpenBao server.
- **The directory is fresh on every build.** Its keys are generated in-cluster by ESO `Password` generators,
  and it is never restored. The deploy re-registers the Google IdP, the groups Action and every OIDC client.
  The owner logs in once and re-grants.
- **The one owner-written exception:** the agents' GitHub App key, the factory App key and the Z.ai key go to
  `agents/` once per GCP lineage. The AWS raft snapshot cannot be restored across KMS seals.

## Stacks under `TM_CLOUD=gcp`
| Runs | `shared/tailscale`, `shared/aws-gcp-federation`, `gcp/network`, `gcp/openbao/{lineage,cluster,management}`, `gcp/workforce-identity`, `gcp/gke/{init,configure}` |
|---|---|
| Prints `[skip]` | `aws/{network,eks/init,eks/configure,openbao/cluster,openbao/management,llm-platform}` |
| Kept, untouched | `aws/openbao/lineage`, the Route53 zone, the S3 state bucket |

## Consequences
- `TM_CLOUD=aws` builds a cluster with no identity provider until this is reverted. A revert means: flip
  `primary_cloud` back, swap the two `suspend`s, and re-register aws-0's clients.
- Every build loses ZITADEL users and IdP links. Grants are re-applied with
  `zitadel-oidc-clients.sh --grant-admin`.
- Each build uses one Let's Encrypt issuance for `auth.gcp.cloud.ogenki.io`; five a week is the ceiling.

## Alternatives rejected
- **Restore gcp-0's seed `zitadel-20260828`** (the 2026-09-11 test): a masterkey read from a store, and a
  directory that is weeks stale.
- **Relocate AWS's directory:** its data and snapshot are `awskms`-bound.
- **Keep AWS primary with gcp-0 consuming:** that needs aws-0 running, which is the cost this removes.
```

Add its row to `website/content/docs/decisions/_index.md` the way the other rows are written.

- [ ] **Step 4: Run it to see it pass**

Run: `./scripts/ci/validate-idp-topology.sh`
Expected: `==> identity provider topology is consistent: gcp hosts, all other clouds suspended.`

- [ ] **Step 5: Commit**

```bash
git add opentofu/config.tm.hcl opentofu/AGENTS.md clusters/gcp-0/security/zitadel.yaml clusters/aws-0/security/zitadel.yaml website/content/docs/decisions
git commit -m "feat(platform): GCP is the primary cloud (ADR-00NN)"
```

### Task 5.2: A fresh ZITADEL on gcp-0; gates and PR G-4

**Files:**
- Modify: `security/gcp-0/zitadel/kustomization.yaml`
- Create: `security/gcp-0/zitadel/{password-generators.yaml,externalsecrets-generated.yaml,helmrelease-env-patch.yaml}`,
  `scripts/ci/tests/test-zitadel-gcp-fresh.py`

**Interfaces:**
- Consumes `xplane-zitadel-cnpg-superuser` (the SQLInstance composition; keys `username`, `password`).
- Produces the Secrets `zitadel-masterkey` (`masterkey`), `zitadel-db-user` (`password`) and
  `zitadel-first-human` (`password`) in `security`, all generated.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-zitadel-gcp-fresh.py`:

```python
#!/usr/bin/env python3
# requires: python3 kustomize
"""GCP parity GP-3: gcp-0's ZITADEL starts from initdb with every key generated
in-cluster, and reads its DB admin from CNPG's own superuser Secret."""
import pathlib
import subprocess
import sys

try:
    import yaml
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[3]
out = subprocess.run(["kustomize", "build", str(ROOT / "security/gcp-0/zitadel"), "--load-restrictor=LoadRestrictionsNone"],
                     capture_output=True, text=True, check=True).stdout
docs = [d for d in yaml.safe_load_all(out) if d]
by = {(d["kind"], d["metadata"]["name"]): d for d in docs}
fails = []

for d in docs:
    if d["kind"] == "ExternalSecret" and (d["spec"].get("secretStoreRef") or {}).get("name") in ("openbao-platform", "clustersecretstore"):
        fails.append(f"ExternalSecret {d['metadata']['name']} still reads a store")
if ("ExternalSecret", "zitadel-envvars") in by:
    fails.append("zitadel-envvars must be gone on gcp-0")
for name in ("zitadel-masterkey", "zitadel-db-user", "zitadel-first-human"):
    es = by.get(("ExternalSecret", name))
    if not es:
        fails.append(f"no ExternalSecret {name}")
        continue
    ref = es["spec"]["dataFrom"][0]["sourceRef"]["generatorRef"]
    if ref.get("kind") != "Password" or es["spec"].get("refreshPolicy") != "CreatedOnce":
        fails.append(f"{name} is not a CreatedOnce Password generator")
    if es["spec"]["target"].get("deletionPolicy") != "Retain":
        fails.append(f"{name} must Retain its Secret")
mk = by.get(("Password", "zitadel-masterkey"), {}).get("spec", {})
if mk.get("length") != 32 or mk.get("symbols") != 0:
    fails.append("the masterkey generator must make 32 characters without symbols")
sql = by.get(("SQLInstance", "xplane-zitadel"), {}).get("spec", {})
if "objectStoreRecovery" in sql or "backup" not in sql:
    fails.append("the SQLInstance must initdb (no objectStoreRecovery) and keep its backups")
vals = by.get(("HelmRelease", "zitadel"), {}).get("spec", {}).get("values", {})
if vals.get("envVarsSecret"):
    fails.append("envVarsSecret must be empty on gcp-0")
env = {e["name"]: e for e in vals.get("env", [])}
for var in ("ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME", "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD"):
    if env.get(var, {}).get("valueFrom", {}).get("secretKeyRef", {}).get("name") != "xplane-zitadel-cnpg-superuser":
        fails.append(f"{var} must come from xplane-zitadel-cnpg-superuser")
for var, secret in (("ZITADEL_DATABASE_POSTGRES_USER_PASSWORD", "zitadel-db-user"),
                    ("ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD", "zitadel-first-human")):
    if env.get(var, {}).get("valueFrom", {}).get("secretKeyRef", {}).get("name") != secret:
        fails.append(f"{var} must come from {secret}")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-zitadel-gcp-fresh.py; echo "exit $?"`
Expected: `FAIL ExternalSecret zitadel-envvars still reads a store` (and the masterkey one), then the
generator, SQLInstance and env failures, then `exit 1`.

- [ ] **Step 3: Implement**

`security/gcp-0/zitadel/password-generators.yaml`:

```yaml
# ZITADEL's keys, generated in-cluster (ADR-00NN, GCP parity GP-3). Each consumer
# is CreatedOnce: generated on the first reconcile and never rotated for the life
# of the cluster, because a rotated masterkey makes the database unreadable.
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: zitadel-masterkey
  namespace: security
spec:
  # ZITADEL requires exactly 32 characters; no symbols, the key is read raw.
  length: 32
  digits: 8
  symbols: 0
  noUpper: false
  allowRepeat: true
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: zitadel-db-user
  namespace: security
spec:
  length: 32
  digits: 8
  symbols: 0
  noUpper: false
  allowRepeat: true
---
apiVersion: generators.external-secrets.io/v1alpha1
kind: Password
metadata:
  name: zitadel-first-human
  namespace: security
spec:
  # ZITADEL's default password policy wants upper, lower, digit and symbol.
  length: 32
  digits: 6
  symbols: 4
  symbolCharacters: "-_!#%+="
  noUpper: false
  allowRepeat: true
```

`security/gcp-0/zitadel/externalsecrets-generated.yaml`:

```yaml
# Retain: deleting the ExternalSecret must never take the Secret with it, since a
# regenerated value would not match what ZITADEL already wrote.
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: zitadel-db-user
  namespace: security
spec:
  refreshPolicy: CreatedOnce
  target:
    name: zitadel-db-user
    creationPolicy: Owner
    deletionPolicy: Retain
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: zitadel-db-user
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: zitadel-first-human
  namespace: security
spec:
  refreshPolicy: CreatedOnce
  target:
    name: zitadel-first-human
    creationPolicy: Owner
    deletionPolicy: Retain
  dataFrom:
    - sourceRef:
        generatorRef:
          apiVersion: generators.external-secrets.io/v1alpha1
          kind: Password
          name: zitadel-first-human
```

`security/gcp-0/zitadel/helmrelease-env-patch.yaml`:

```yaml
# No envVarsSecret on gcp-0: what it carried on AWS is generated here, or read
# from CNPG's own superuser Secret, so ZITADEL and CNPG can never disagree on the
# admin password (the 2026-08-28 init failure). The masterkey keeps base's
# masterkeySecretName, now filled by a generator.
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: zitadel
spec:
  values:
    envVarsSecret: ""
    env:
      - name: ZITADEL_DATABASE_POSTGRES_ADMIN_USERNAME
        valueFrom: {secretKeyRef: {name: xplane-zitadel-cnpg-superuser, key: username}}
      - name: ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD
        valueFrom: {secretKeyRef: {name: xplane-zitadel-cnpg-superuser, key: password}}
      - name: ZITADEL_DATABASE_POSTGRES_ADMIN_SSL_MODE
        value: require
      - name: ZITADEL_DATABASE_POSTGRES_USER_USERNAME
        value: zitadel
      - name: ZITADEL_DATABASE_POSTGRES_USER_PASSWORD
        valueFrom: {secretKeyRef: {name: zitadel-db-user, key: password}}
      - name: ZITADEL_DATABASE_POSTGRES_USER_SSL_MODE
        value: require
      - name: ZITADEL_FIRSTINSTANCE_ORG_HUMAN_USERNAME
        value: zitadel-admin
      - name: ZITADEL_FIRSTINSTANCE_ORG_HUMAN_PASSWORD
        valueFrom: {secretKeyRef: {name: zitadel-first-human, key: password}}
```

`security/gcp-0/zitadel/kustomization.yaml`:
1. Replace the header comment with the GP-3 summary: fresh every build, generated keys, the DB admin from
   CNPG, no restore, and the deploy re-registering the IdP and clients.
2. `resources` gains `password-generators.yaml` and `externalsecrets-generated.yaml`.
3. In the existing SQLInstance patch, the two `objectStoreRecovery` ops become one `- op: remove` with
   `path: /spec/objectStoreRecovery`. Keep the compositionRef, instances and backup ops.
4. Append to `patches`:

```yaml
  - target: {group: external-secrets.io, kind: ExternalSecret, name: zitadel-envvars}
    patch: |-
      $patch: delete
      apiVersion: external-secrets.io/v1
      kind: ExternalSecret
      metadata:
        name: zitadel-envvars
  - target: {group: external-secrets.io, kind: ExternalSecret, name: zitadel-masterkey}
    patch: |-
      - op: remove
        path: /spec/data
      - op: remove
        path: /spec/secretStoreRef
      - op: add
        path: /spec/refreshPolicy
        value: CreatedOnce
      - op: add
        path: /spec/dataFrom
        value:
          - sourceRef:
              generatorRef:
                apiVersion: generators.external-secrets.io/v1alpha1
                kind: Password
                name: zitadel-masterkey
      - op: replace
        path: /spec/target/template/data/masterkey
        value: "{{ .password }}"
  - path: helmrelease-env-patch.yaml
    target: {group: helm.toolkit.fluxcd.io, kind: HelmRelease, name: zitadel}
```

- [ ] **Step 4: Run it to see it pass, then check the chart takes `env` into its Jobs**

Run: `python3 scripts/ci/tests/test-zitadel-gcp-fresh.py && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`, then `Invalid: 0, Skipped: 0`. Then:

```bash
python3 - <<'PY'
import pathlib, yaml
hits = {}
for f in pathlib.Path(".bundle").glob("*gcp-0-zitadel*"):
    for d in yaml.safe_load_all(f.read_text()):
        if not d or d.get("kind") not in ("Deployment", "Job"):
            continue
        spec = d["spec"]["template"]["spec"]
        names = {e["name"] for c in spec.get("containers", []) + spec.get("initContainers", []) for e in c.get("env", [])}
        hits[f'{d["kind"]}/{d["metadata"]["name"]}'] = "ZITADEL_DATABASE_POSTGRES_ADMIN_PASSWORD" in names
print(hits)
PY
```

Expected: every entry `True`: the Deployment `zitadel`, and the `zitadel-init` and `zitadel-setup` Jobs. A
`False` on a Job means chart 10.0.6 does not take `env` there. Then apply GP-3's fallback: an ESO
`kubernetes`-provider SecretStore in `security`, allowed to `get` only `xplane-zitadel-cnpg-superuser`, that
feeds an ExternalSecret `zitadel-envvars` combining those keys with the generators. `envVarsSecret` returns.

- [ ] **Step 5: Every gate**

Run: `./scripts/ci/validate-manifests.sh && ./scripts/ci/validate-idp-topology.sh && ./scripts/ci/validate-openbao-policies.sh && ./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh && task check`
Expected: `Invalid: 0, Skipped: 0`, `gcp hosts`, parity passes, and exit 0.

- [ ] **Step 6: Commit and open G-4**

```bash
git add security/gcp-0/zitadel scripts/ci/tests/test-zitadel-gcp-fresh.py
git commit -m "feat(zitadel): gcp-0's directory is fresh every build, its keys generated in-cluster"
```

Run `create-pr` with base `fix/gcp-hosted-idp`. Title: `feat(platform): GCP is the primary cloud, with a fresh ZITADEL`.
The body carries ADR-00NN's decision and its first consequence (`TM_CLOUD=aws` has no IdP while this is
merged). It says: **platform decision, the owner merges it or it waits for Phase 7** ([OWNER]).

---

## Phase 6 — G-5: the agent platform on gcp-0 (programme stack)

### Task 6.1: The `agents` mount on both clouds (M1, GP-8)

**Files:**
- Modify: `opentofu/aws/openbao/management/{mounts.tf,policies.tf,policies/agents-secrets.hcl,policies/secrets-admin.hcl,policies/external-secrets.hcl}`,
  `opentofu/gcp/openbao/management/{mounts.tf,policies.tf}`,
  `opentofu/shared/modules/openbao-store-of-record/policies/secrets-admin.hcl`,
  `opentofu/gcp/gke/configure/openbao.tf`, `opentofu/aws/eks/configure/openbao.tf` (comment),
  `security/base/agent-secrets/secretstore.yaml`, `security/base/octo-sts/externalsecret.yaml`,
  `infrastructure/base/agent-router/externalsecret-zai.yaml`
- Create: `opentofu/gcp/openbao/management/policies/agents-secrets.hcl`, `scripts/ci/tests/test-openbao-agent-mounts.sh`

**Interfaces:**
- Produces a kv-v2 mount `agents` on both OpenBaos, and the policy `agents-secrets`: read on `agents/data/*`,
  read and list on `agents/metadata/*`.
- `secrets-admin` gains `agents/*`, and `external-secrets` never names it.
- Produces the JWT role `agents-secrets` on `jwt/gcp-0`.
- The SecretStore `agents-secrets` reads path `agents`. The keys become `github-app`, `zai` and `factory-app`.

- [ ] **Step 1: Worktree and stack**

`EnterWorktree` with branch `feat/gcp-agent-platform`, then:

```bash
git reset --hard origin/fix/agent-review-hardening
git merge --no-ff origin/feat/gcp-primary -m "merge: GCP primary (G-4) into the gcp-0 agent platform"
git merge origin/main
```

Expected: both merges clean. On a conflict in `docs/runbooks/` or `opentofu/`, keep H-1's side and re-apply
G-4's lines. PR base: `fix/agent-review-hardening`, merge-only (GP-19).

- [ ] **Step 2: Write the failing test**

`scripts/ci/tests/test-openbao-agent-mounts.sh`:

```bash
#!/usr/bin/env bash
#
# SP2 ruling P38 (external review M1), on both clouds (GCP parity GP-8): the
# agents' secrets live on a mount only agent-system's own store reads.
# `external-secrets` backs a ClusterSecretStore any namespace can use (T14), so it
# must never name it. The real tree.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }

for cloud in aws gcp; do
  P="$ROOT/opentofu/$cloud/openbao/management"
  grep -Eq '^[[:space:]]*path[[:space:]]*=[[:space:]]*"agents"' "$P/mounts.tf" || fail "$cloud: no vault_mount with path agents"
  grep -Eq '^path "platform/' "$P/policies/agents-secrets.hcl" && fail "$cloud: agents-secrets still reads platform/"
  [ "$(grep -c '^path "agents/' "$P/policies/agents-secrets.hcl")" -eq 2 ] || fail "$cloud: agents-secrets reads agents/data and agents/metadata, nothing else"
done
for f in opentofu/aws/openbao/management/policies/external-secrets.hcl opentofu/shared/modules/openbao-store-of-record/policies/external-secrets.hcl; do
  grep -Eq '^path "agents/' "$ROOT/$f" && fail "$f names the agents mount"
done
for f in opentofu/aws/openbao/management/policies/secrets-admin.hcl opentofu/shared/modules/openbao-store-of-record/policies/secrets-admin.hcl; do
  grep -q '^path "agents/data/\*"' "$ROOT/$f" || fail "$f cannot write the agents mount (the owner's bao kv put)"
done
grep -q 'agents-secrets = {' "$ROOT/opentofu/gcp/gke/configure/openbao.tf" || fail "gcp: no agents-secrets role on jwt/gcp-0"
grep -q '^      path: "agents"$' "$ROOT/security/base/agent-secrets/secretstore.yaml" || fail "the agents-secrets SecretStore is not on the agents mount"
grep -rq 'key: agents/' "$ROOT/security/base/octo-sts" "$ROOT/infrastructure/base/agent-router" && fail "an ExternalSecret still carries the old agents/ prefix"

[ "$fails" -eq 0 ] || exit 1
echo PASS
```

- [ ] **Step 3: Run it to see it fail**

Run: `bash scripts/ci/tests/test-openbao-agent-mounts.sh; echo "exit $?"`
Expected: `FAIL` lines for both clouds' mount and policy, both `secrets-admin`s, the gcp role, the SecretStore
and the ExternalSecret keys, then `exit 1`.

- [ ] **Step 4: Implement**

Append to **both** `opentofu/{aws,gcp}/openbao/management/mounts.tf`:

```hcl
# The agents' own secrets (SP2 ruling P38, external review M1; GCP parity GP-8):
# the GitHub App keys and the agents' Z.ai key. A mount of its own because
# `external-secrets` reads all of platform/ through a ClusterSecretStore any
# namespace can use (T14): only `agents-secrets` and `secrets-admin` name it.
resource "vault_mount" "agents" {
  path        = "agents"
  type        = "kv-v2"
  description = "Agent platform secrets, read only by agent-system's SecretStore (SP2 P38)"
}
```

`opentofu/aws/openbao/management/policies/agents-secrets.hcl` is replaced by, and
`opentofu/gcp/openbao/management/policies/agents-secrets.hcl` is created with:

```hcl
# agent-system's namespaced SecretStore reads the `agents` mount and nothing else
# (SP1 S9, SP2 ruling P38). A mount of its own, not platform/agents/*:
# `external-secrets` reads all of platform/ through a ClusterSecretStore any
# namespace can use (T14, review M1).

path "agents/data/*" {
  capabilities = ["read"]
}

path "agents/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
```

`opentofu/gcp/openbao/management/policies.tf`, appended:

```hcl
# agent-system's own store (SP1 S9, SP2 P38): the `agents` mount only. Attached
# to the `agents-secrets` role on jwt/gcp-0 by NAME, like `external-secrets`.
resource "vault_policy" "agents_secrets" {
  name   = "agents-secrets"
  policy = file("${path.module}/policies/agents-secrets.hcl")
}
```

In `opentofu/aws/openbao/management/policies.tf`, the comment above `vault_policy.agents_secrets` becomes
"the `agents` mount only (SP2 P38)".

In both `policies/secrets-admin.hcl` (AWS and the module), add before the `sys/mounts` block:

```hcl
# The agents' mount (SP2 ruling P38): an administrator writes the GitHub App keys
# and the Z.ai key there once per lineage, and deletes a leaked one.
path "agents/data/*" {
  capabilities = ["create", "read", "update", "patch", "delete", "list"]
}

path "agents/metadata/*" {
  capabilities = ["create", "read", "update", "list", "delete"]
}

path "agents/delete/*" {
  capabilities = ["update"]
}

path "agents/undelete/*" {
  capabilities = ["update"]
}

path "agents/destroy/*" {
  capabilities = ["update"]
}

path "agents/config" {
  capabilities = ["read", "update"]
}
```

In AWS's `policies/external-secrets.hcl`, add to the header:

```hcl
# Never the `agents` mount (SP2 ruling P38, external review M1): this identity
# backs `openbao-platform`, a ClusterSecretStore any namespace can use (T14).
# scripts/ci/tests/test-openbao-agent-mounts.sh fails if a path here names it.
```

`opentofu/gcp/gke/configure/openbao.tf`, in `local.openbao_roles`:

```hcl
    agents-secrets = {
      service_account = "agents-secrets"
      namespace       = "agent-system"
      # SP1 S9, SP2 P38: the agent-system SecretStore, the `agents` mount only.
      policies = ["default", "agents-secrets"]
    }
```

In `opentofu/aws/eks/configure/openbao.tf`, the `agents-secrets` role's comment becomes
`# SP1 S9, SP2 P38: the agent-system SecretStore, the \`agents\` mount only.`

In `security/base/agent-secrets/secretstore.yaml`, set `path: "agents"`, and make the header's first
sentence "Its OpenBao role reads the `agents` mount and nothing else (SP2 P38)". In
`security/base/octo-sts/externalsecret.yaml`, every `key: agents/github-app` becomes `key: github-app`. In
`infrastructure/base/agent-router/externalsecret-zai.yaml`, `key: agents/zai` becomes `key: zai`.

- [ ] **Step 5: Run it to see it pass, with the gates it touches**

Run: `bash scripts/ci/tests/test-openbao-agent-mounts.sh && ./scripts/ci/validate-openbao-policies.sh && for d in aws/openbao/management gcp/openbao/management gcp/gke/configure; do tofu -chdir=opentofu/$d init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/$d validate; done && tofu -chdir=opentofu/shared/modules/openbao-store-of-record test`
Expected: `PASS`, parity passes, `Success! The configuration is valid.` three times, and `2 passed, 0 failed`.

- [ ] **Step 6: Commit**

```bash
git add opentofu security/base/agent-secrets security/base/octo-sts infrastructure/base/agent-router/externalsecret-zai.yaml scripts/ci/tests/test-openbao-agent-mounts.sh
git commit -m "fix(openbao): the agents' secrets on their own mount, on both clouds (SP2 P38)"
```

### Task 6.2: Per-cloud issuer variables (GP-12)

**Files:**
- Modify: `opentofu/aws/eks/configure/kubernetes.tf`, `opentofu/gcp/gke/configure/{locals.tf,kubernetes.tf,openbao.tf}`,
  `infrastructure/base/agent-router/{securitypolicy-public.yaml,securitypolicy-internal.yaml,securitypolicy-sts.yaml,network-policy-data-plane.yaml}`,
  `infrastructure/base/agent-mcp/mcproutes.yaml`, `security/base/octo-sts/network-policy.yaml`,
  `scripts/ci/flux-schema/render-bundle.py`
- Create: `scripts/ci/tests/test-oidc-issuer-vars.sh`

**Interfaces:**
- Produces the keys `oidc_issuer_url`, `oidc_jwks_uri` and `oidc_jwks_host` in both `eks-aws-0-vars` and
  `gke-gcp-0-vars`.
- Produces `local.oidc_issuer_url` in `gcp/gke/configure`, which `openbao.tf` reuses.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-oidc-issuer-vars.sh`:

```bash
#!/usr/bin/env bash
#
# GCP parity GP-12: the agents' issuer, JWKS URI and JWKS host are per-cloud
# variables. EKS serves <issuer>/keys at oidc.eks.<region>.amazonaws.com; GKE serves
# <issuer>/jwks at container.googleapis.com. A same-named ${region} renders a host
# that does not exist on gcp-0 while the bundle stays clean
# (memory flux_render_fixture_cross_cloud_blindspot).
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0
f() { echo "FAIL $*"; fails=$((fails + 1)); }
hits="$(grep -rnE 'oidc_issuer_url\}/keys|oidc\.eks\.\$\{region\}' "$ROOT/infrastructure" "$ROOT/security" --include=*.yaml)"
[ -z "$hits" ] || f "AWS-shaped issuer in base manifests:"$'\n'"$hits"
for cm in opentofu/aws/eks/configure/kubernetes.tf opentofu/gcp/gke/configure/kubernetes.tf; do
  for k in oidc_issuer_url oidc_jwks_uri oidc_jwks_host; do
    grep -Eq "^[[:space:]]*${k}[[:space:]]*=" "$ROOT/$cm" || f "$cm defines no $k"
  done
done
grep -q '"/jwks"\|}/jwks"' "$ROOT/opentofu/gcp/gke/configure/kubernetes.tf" || f "gcp's JWKS URI is not <issuer>/jwks"
python3 - "$ROOT/scripts/ci/flux-schema/render-bundle.py" <<'PY' || f "render-bundle.py has no GKE-shaped gcp-0 fixtures"
import re, sys
t = open(sys.argv[1]).read()
g = t[t.index('"gcp-0": {'):]
ok = all(k in g[:2000] for k in ('"oidc_issuer_url": "https://container.googleapis.com/', '"oidc_jwks_host": "container.googleapis.com"', '/jwks"'))
sys.exit(0 if ok else 1)
PY
[ "$fails" -eq 0 ] || exit 1
echo PASS
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-oidc-issuer-vars.sh; echo "exit $?"`
Expected:
- the AWS-shaped hits: three `securitypolicy-*.yaml`, `mcproutes.yaml` twice, `network-policy-data-plane.yaml`
  and `security/base/octo-sts/network-policy.yaml`;
- then the missing ConfigMap keys and the fixture;
- then `exit 1`.

- [ ] **Step 3: Implement**

`opentofu/aws/eks/configure/kubernetes.tf`, next to `oidc_issuer_url`:

```hcl
      # Per-cloud JWKS (GCP parity GP-12): EKS serves <issuer>/keys on a
      # region-scoped host; gke-gcp-0-vars carries GKE's /jwks and host.
      oidc_jwks_uri  = "${local.oidc_issuer_url}/keys"
      oidc_jwks_host = "oidc.eks.${var.region}.amazonaws.com"
```

`opentofu/gcp/gke/configure/locals.tf`:

```hcl
  # The GKE issuer: deterministic from project, location and name, and public.
  # Its JWKS is <issuer>/jwks; EKS's is <issuer>/keys.
  oidc_issuer_url = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${local.init.cluster_location}/clusters/${var.cluster_name}"
```

`opentofu/gcp/gke/configure/kubernetes.tf`, under `# GCP-specific.`:

```hcl
      # The agents' token issuer (GCP parity GP-12). Same keys as eks-aws-0-vars,
      # GKE-shaped values: agent-router, agent-mcp and octo-sts read these.
      oidc_issuer_url = local.oidc_issuer_url
      oidc_jwks_uri   = "${local.oidc_issuer_url}/jwks"
      oidc_jwks_host  = "container.googleapis.com"
```

In `opentofu/gcp/gke/configure/openbao.tf`, `oidc_discovery_url` and `bound_issuer` both become
`local.oidc_issuer_url`.

In the base manifests:

| File | Change |
|---|---|
| `securitypolicy-public.yaml`, `securitypolicy-internal.yaml`, `securitypolicy-sts.yaml` | `uri: ${oidc_issuer_url}/keys` → `uri: ${oidc_jwks_uri}`. In `-public`'s header, "EKS JWKS is served at <issuer>/keys" → "the JWKS URI is per cloud (`${oidc_jwks_uri}`)" |
| `infrastructure/base/agent-mcp/mcproutes.yaml` | both `uri: ${oidc_issuer_url}/keys` → `uri: ${oidc_jwks_uri}` |
| `network-policy-data-plane.yaml` | `- matchName: oidc.eks.${region}.amazonaws.com` → `- matchName: ${oidc_jwks_host}` |
| `security/base/octo-sts/network-policy.yaml` | the same line, and its comment becomes "The issuer's JWKS host, per cloud (GCP parity GP-12)." |

In `scripts/ci/flux-schema/render-bundle.py`, `FIXTURE_VARS` gains, after `oidc_issuer_url`:

```python
    "oidc_jwks_uri": "https://oidc.eks.eu-west-3.amazonaws.com/id/EXAMPLE0123456789ABCDEF/keys",
    "oidc_jwks_host": "oidc.eks.eu-west-3.amazonaws.com",
```

`CLUSTER_FIXTURE_VARS["gcp-0"]` gains:

```python
        # GKE's issuer and JWKS (GCP parity GP-12): a gcp-0 overlay that still
        # rendered EKS values would look right here and fail on the cluster.
        "oidc_issuer_url": "https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0",
        "oidc_jwks_uri": "https://container.googleapis.com/v1/projects/ogenki-435905/locations/europe-west4-a/clusters/gcp-0/jwks",
        "oidc_jwks_host": "container.googleapis.com",
```

- [ ] **Step 4: Run it to see it pass**

Run: `bash scripts/ci/tests/test-oidc-issuer-vars.sh && python3 scripts/ci/flux-schema/check-substitution.py && tofu -chdir=opentofu/gcp/gke/configure validate && tofu -chdir=opentofu/aws/eks/configure init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/aws/eks/configure validate`
Expected: `PASS`, check-substitution exit 0, and `Success! The configuration is valid.` twice.

- [ ] **Step 5: Commit**

```bash
git add opentofu/aws/eks/configure opentofu/gcp/gke/configure infrastructure/base/agent-router infrastructure/base/agent-mcp security/base/octo-sts scripts/ci
git commit -m "fix(agents): the token issuer and its JWKS are per-cloud variables"
```

### Task 6.3: GKE Sandbox pool, Cilium per-packet LB, tolerations, smoke probe

**Files:**
- Create: `opentofu/gcp/gke/init/sandbox.tf`, `scripts/ops/k8s/gvisor-smoke.yaml`, `scripts/ci/tests/test-gcp-agents-pool.sh`
- Modify: `opentofu/gcp/gke/init/{variables.tf,helm_values/cilium.yaml}`, and each file that tolerates
  `agents.ogenki.io/runtime` (Step 1 lists them)

**Interfaces:**
- Produces the node pool `agents-gvisor`. GKE labels and taints it `sandbox.gke.io/runtime=gvisor` and ships
  the RuntimeClass `gvisor` (GP-9, GP-10).
- Produces `var.agents_pool_machine_type` (`"e2-standard-8"`) and `var.agents_pool_max_nodes` (`2`).
- Produces the probe manifest used in Task 8.5.

- [ ] **Step 1: Find the tolerations and write the failing test**

Run: `grep -rln 'key: agents.ogenki.io/runtime' observability infrastructure security --include=*.yaml | grep -v -e karpenter-nodepools-agents -e runtimeclass-gvisor`
Expected: the Vector values file(s) SP1 PR 2 changed ("Vector toleration"). Note each path; Step 3 edits them.

`scripts/ci/tests/test-gcp-agents-pool.sh`:

```bash
#!/usr/bin/env bash
# requires: python3
#
# GCP parity GP-9..GP-11: gcp-0's runs land on a GKE Sandbox pool through GKE's
# own `gvisor` RuntimeClass; gVisor needs Cilium's per-packet LB; and every
# DaemonSet that follows runs onto aws-0's gVisor nodes follows them onto GKE's.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
F="$ROOT/opentofu/gcp/gke/init/sandbox.tf"
C="$ROOT/opentofu/gcp/gke/init/helm_values/cilium.yaml"
fails=0; fail() { printf 'FAIL  %s\n' "$*" >&2; fails=$((fails + 1)); }
if [ -f "$F" ]; then
  grep -Eq 'sandbox_type[[:space:]]*=[[:space:]]*"gvisor"' "$F" || fail "the pool is not a GKE Sandbox pool"
  grep -Eq 'spot[[:space:]]*=[[:space:]]*true' "$F" || fail "the pool is not spot"
  grep -Eq 'min_node_count[[:space:]]*=[[:space:]]*0' "$F" || fail "the pool does not scale to zero"
  grep -q 'node.cilium.io/agent-not-ready' "$F" || fail "no Cilium startup taint"
else
  fail "no $F"
fi
python3 - "$C" <<'PY' || fail "cilium.yaml: socketLB.hostNamespaceOnly must be true"
import re, sys
sys.exit(0 if re.search(r'(?m)^socketLB:\n[ \t]+hostNamespaceOnly:[ \t]*true\b', open(sys.argv[1]).read()) else 1)
PY
grep -rqs 'runtimeclass-gvisor\|karpenter-nodepools-agents' "$ROOT"/clusters/gcp-0* \
  && fail "gcp-0 must not apply aws-0's RuntimeClass or Karpenter pool: GKE ships both"
while IFS= read -r f; do
  grep -q 'sandbox.gke.io/runtime' "$f" || fail "$f tolerates agents.ogenki.io/runtime but not sandbox.gke.io/runtime"
done < <(grep -rl --include=*.yaml 'key: agents.ogenki.io/runtime' "$ROOT/observability" "$ROOT/infrastructure" "$ROOT/security" | grep -v -e karpenter-nodepools-agents -e runtimeclass-gvisor)
[ -f "$ROOT/scripts/ops/k8s/gvisor-smoke.yaml" ] || fail "no scripts/ops/k8s/gvisor-smoke.yaml"
[ "$fails" -eq 0 ] || exit 1
echo PASS
```

- [ ] **Step 2: Run it to see it fail**

Run: `bash scripts/ci/tests/test-gcp-agents-pool.sh; echo "exit $?"`
Expected: `FAIL no …/sandbox.tf`, the socketLB failure, one line per toleration file, and the missing probe,
then `exit 1`.

- [ ] **Step 3: Implement**

`opentofu/gcp/gke/init/variables.tf`:

```hcl
# The agents' GKE Sandbox pool (GCP parity GP-10). 2 x e2-standard-8 = 16 vCPU /
# 64 GiB, aws-0's agents-gvisor limits. The NAP ceiling
# (autoscaling_max_cpu_cores = 32) counts these nodes too.
variable "agents_pool_machine_type" {
  description = "Machine type of the agents-gvisor GKE Sandbox pool"
  type        = string
  default     = "e2-standard-8"
}

variable "agents_pool_max_nodes" {
  description = "Upper bound of the agents-gvisor pool; it scales from zero"
  type        = number
  default     = 2
}
```

`opentofu/gcp/gke/init/sandbox.tf`:

```hcl
# agents-gvisor: GKE Sandbox (native gVisor) for agent runs, gcp-0's half of
# ADR-0041. GKE labels and taints the pool sandbox.gke.io/runtime=gvisor and
# ships the `gvisor` RuntimeClass whose scheduling pins every gVisor pod here, so
# the AgentRun composition names only runtimeClassName on both clouds (GP-9).
#
# A standalone pool on google-beta rather than a module node_pools entry: sandbox
# support differs between the module's beta and GA variants, and this pool must
# not ride on that difference.
resource "google_container_node_pool" "agents_gvisor" {
  provider = google-beta

  project        = var.project_id
  name           = "agents-gvisor"
  cluster        = module.gke.name
  location       = module.gke.location
  node_locations = [local.net.zone]

  initial_node_count = 0
  autoscaling {
    min_node_count  = 0
    max_node_count  = var.agents_pool_max_nodes
    location_policy = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.agents_pool_machine_type
    image_type      = "COS_CONTAINERD"
    spot            = true
    disk_size_gb    = var.node_disk_size_gb
    disk_type       = "pd-balanced"
    service_account = module.gke.service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = local.labels
    metadata = {
      disable-legacy-endpoints = "true"
    }

    sandbox_config {
      sandbox_type = "gvisor"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Same as the static pool: nothing schedules before Cilium is ready, and
    # Cilium clears it. GKE adds its own sandbox taint.
    taint {
      key    = "node.cilium.io/agent-not-ready"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  depends_on = [module.gke]
}
```

`opentofu/gcp/gke/init/helm_values/cilium.yaml`: remove `socketLB.hostNamespaceOnly` from the
*Still absent* list and its paragraph. Then append:

```yaml
# gVisor's netstack sends packets from the Sentry and never calls connect() in
# the host kernel, so socket-LB cannot translate a ClusterIP for a GKE Sandbox
# pod; per-packet LB in the pod namespace does (GCP parity GP-11). aws-0 runs the
# same value, for Tailscale (tailscale#15478). Proved on gcp-0 by the gVisor
# smoke probe (scripts/ops/k8s/gvisor-smoke.yaml) and the gateway checks.
socketLB:
  hostNamespaceOnly: true
```

In each file Step 1 listed, next to the `agents.ogenki.io/runtime` toleration, add:

```yaml
        - key: sandbox.gke.io/runtime
          operator: Equal
          value: gvisor
          effect: NoSchedule
```

Indent it like its neighbour, and add a comment line: `# gcp-0's GKE Sandbox taint (GCP parity GP-9)`.

`scripts/ops/k8s/gvisor-smoke.yaml`:

```yaml
# gVisor smoke probe for gcp-0 (GCP parity Task 8.5). Proves in one pod:
#   - the GKE Sandbox pool scales from zero, through GKE's RuntimeClass;
#   - threads start under RuntimeDefault seccomp (the AWS spike's clone3 trap);
#   - DNS through kube-dns's ClusterIP and a TCP connection to a ClusterIP work,
#     i.e. per-packet LB (socketLB.hostNamespaceOnly).
# Prints: threads=4 dns=ok tcp=ok release=4.4.0 (gVisor's reported kernel).
# Apply, read, delete: kubectl delete -f scripts/ops/k8s/gvisor-smoke.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: gvisor-smoke
  labels:
    pod-security.kubernetes.io/enforce: restricted
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: gvisor-smoke
  namespace: gvisor-smoke
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: gvisor-smoke
  ingress: []
  egress:
    - toEndpoints:
        - matchLabels:
            io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
          rules:
            dns:
              - matchPattern: "*"
    - toEntities:
        - kube-apiserver
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
---
apiVersion: v1
kind: Pod
metadata:
  name: gvisor-smoke
  namespace: gvisor-smoke
  labels:
    app.kubernetes.io/name: gvisor-smoke
spec:
  runtimeClassName: gvisor
  restartPolicy: Never
  automountServiceAccountToken: false
  enableServiceLinks: false
  securityContext:
    runAsNonRoot: true
    runAsUser: 10001
    runAsGroup: 10001
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: probe
      image: python:3.13-slim
      command:
        - python3
        - -c
        - |
          import os, socket, threading
          ts = [threading.Thread(target=lambda: None) for _ in range(4)]
          [t.start() for t in ts]; [t.join() for t in ts]
          ip = socket.getaddrinfo("kubernetes.default.svc.cluster.local.", 443, proto=socket.IPPROTO_TCP)[0][4][0]
          socket.create_connection((ip, 443), timeout=5).close()
          print(f"threads={len(ts)} dns=ok tcp=ok release={os.uname().release}")
      resources:
        requests: {cpu: 50m, memory: 64Mi}
        limits: {cpu: 200m, memory: 128Mi}
      securityContext:
        allowPrivilegeEscalation: false
        readOnlyRootFilesystem: true
        capabilities:
          drop: ["ALL"]
```

- [ ] **Step 4: Run it to see it pass, then validate and scan**

Run: `bash scripts/ci/tests/test-gcp-agents-pool.sh && tofu -chdir=opentofu/gcp/gke/init init -backend=false -input=false >/dev/null && tofu -chdir=opentofu/gcp/gke/init validate && (cd opentofu/gcp/gke/init && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .)`
Expected: `PASS`, `Success! The configuration is valid.`, trivy exit 0. On a trivy finding against
`google_container_node_pool.agents_gvisor`, set the attribute it names rather than ignoring it. If
`module.gke.service_account` or `module.gke.location` is not an output of module v45, `validate` names it:
use `module.gke.name`'s sibling output that `outputs.tf` already reads for the cluster location.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/gke/init scripts/ops/k8s/gvisor-smoke.yaml scripts/ci/tests/test-gcp-agents-pool.sh observability infrastructure security
git commit -m "feat(gcp): a GKE Sandbox pool for agent runs, and per-packet LB for gVisor"
```

### Task 6.4: The AgentRun XRD and Kyverno reach gcp-0

**Files:**
- Modify: `infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml`,
  `security/gcp-0/controllers/kustomization.yaml`
- Create: `scripts/ci/tests/test-gcp-agent-prereqs.sh`

**Interfaces:**
- Produces `crossplane-configuration-gcp` pinned to the same tag as `-aws`, so its `core` dependency carries
  AgentRun.
- Produces Kyverno in gcp-0's `security` Kustomization, which `agent-policies` depends on.

- [ ] **Step 1: The grant allowlist is not triggered**

Run: `git -C /home/smana/Sources/crossplane-configuration fetch origin && git -C /home/smana/Sources/crossplane-configuration diff origin/main "origin/$(grep -o 'pr[0-9]*' infrastructure/base/crossplane/configuration-aws/configuration-packages.yaml | head -1 | sed 's/pr/pull\//')/head" -- 'apis/*/kcl/*.k' 2>/dev/null | grep -E '^\+.*roles/' || echo "no new GCP role"`
Expected: `no new GCP role`. If the ref cannot be resolved, run the same `diff` against `origin/feat/agentrun-harness`
and expect the same line. A new `roles/…` needs its allowlist entry in `opentofu/gcp/gke/init/iam.tf`
(memory `gcp_crossplane_grant_allowlist_contract`).

- [ ] **Step 2: Write the failing test**

`scripts/ci/tests/test-gcp-agent-prereqs.sh`:

```bash
#!/usr/bin/env bash
#
# What the agent platform needs on gcp-0 before any child applies (GCP parity):
# the gcp package at the same crossplane-configuration version as aws, whose core
# dependency ships the AgentRun XRD, and Kyverno, which agent-policies needs.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
fails=0; f() { echo "FAIL $*"; fails=$((fails + 1)); }
tag() { sed -n "s#.*crossplane-configuration-$1:\(v[^[:space:]\"']*\).*#\1#p" "$ROOT/infrastructure/base/crossplane/configuration-$1/configuration-packages.yaml" | head -1; }
aws="$(tag aws)"; gcp="$(tag gcp)"
[ -n "$aws" ] && [ "$aws" = "$gcp" ] || f "crossplane-configuration pins differ: aws=$aws gcp=$gcp"
if [ -e "$ROOT/clusters/gcp-0-agent-platform/security-agent-policies.yaml" ] || [ ! -d "$ROOT/clusters/gcp-0-agent-platform" ]; then
  grep -q '\.\./\.\./base/kyverno' "$ROOT/security/gcp-0/controllers/kustomization.yaml" || f "gcp-0's security Kustomization has no Kyverno"
fi
[ "$fails" -eq 0 ] || exit 1
echo PASS
```

- [ ] **Step 3: Run it to see it fail**

Run: `bash scripts/ci/tests/test-gcp-agent-prereqs.sh; echo "exit $?"`
Expected: `FAIL crossplane-configuration pins differ: aws=v0.7.2-pr… gcp=v0.7.0` and
`FAIL gcp-0's security Kustomization has no Kyverno`, then `exit 1`.

- [ ] **Step 4: Implement**

In `configuration-gcp/configuration-packages.yaml`, set `package:` to
`ghcr.io/smana/crossplane-configuration-gcp:<the tag in configuration-aws>`, with the line comment
`# lockstep with configuration-aws (GCP parity): core's AgentRun XRD`. Check the pre-release exists:
`skopeo inspect --format '{{.Digest}}' docker://ghcr.io/smana/crossplane-configuration-gcp:<tag>` → a
`sha256:` digest. No digest is a **blocker**: the CC pre-release job publishes only some packages. Ask for
the gcp package to be published with the same version (CC-H1's owner) before Task 7.1.

In `security/gcp-0/controllers/kustomization.yaml`, add `- ../../base/kyverno` first in `resources`, and extend
the header's resource commentary with:
"kyverno: agent-policies' admission and GC need it (GCP parity), as aws-0's security does; its chart admits
nothing in ../openbao."

- [ ] **Step 5: Run it to see it pass**

Run: `bash scripts/ci/tests/test-gcp-agent-prereqs.sh && ./scripts/ci/validate-manifests.sh`
Expected: `PASS`, then `Invalid: 0, Skipped: 0`.

- [ ] **Step 6: Commit**

```bash
git add infrastructure/base/crossplane/configuration-gcp security/gcp-0/controllers scripts/ci/tests/test-gcp-agent-prereqs.sh
git commit -m "feat(gcp): AgentRun's package and Kyverno on gcp-0"
```

### Task 6.5: A render root per cloud for every substituted agent base (GP-14)

**Files:**
- Create: 12 one-line kustomizations:

  | Base | aws-0 overlay | gcp-0 overlay |
  |---|---|---|
  | `infrastructure/base/agent-router` | `infrastructure/aws-0/agent-router` | `infrastructure/gcp-0/agent-router` |
  | `infrastructure/base/agent-mcp` | `infrastructure/aws-0/agent-mcp` | `infrastructure/gcp-0/agent-mcp` |
  | `infrastructure/base/envoy-ai-gateway` | `infrastructure/aws-0/envoy-ai-gateway` | `infrastructure/gcp-0/envoy-ai-gateway` |
  | `security/base/octo-sts` | `security/aws-0/octo-sts` | `security/gcp-0/octo-sts` |
  | `security/base/agent-secrets` | `security/aws-0/agent-secrets` | `security/gcp-0/agent-secrets` |
  | `observability/base/agent-platform` | `observability/aws-0/agent-platform` | `observability/gcp-0/agent-platform` |

- Modify: the aws-0 children's `path:` in `clusters/aws-0-agent-platform/{infrastructure-agent-router,infrastructure-agent-mcp,security-octo-sts,security-agent-secrets,observability-agent-platform}.yaml`,
  `clusters/aws-0-ai-gateway/infrastructure-envoy-ai-gateway.yaml`, and
  `clusters/gcp-0-llm-platform/infrastructure-envoy-ai-gateway.yaml` (moved by 6.6)

**Interfaces:** Produces the bundle files `overlay-<area>-{aws-0,gcp-0}-<name>.yaml`, each substituted with
its own cloud's fixture. The base render roots for these six disappear.

- [ ] **Step 1: The failing check**

Run: `./scripts/ci/validate-manifests.sh >/dev/null && ls .bundle | grep -cE '^overlay-(infrastructure|security|observability)-(aws|gcp)-0-(agent-router|agent-mcp|envoy-ai-gateway|octo-sts|agent-secrets|agent-platform)\.yaml$'`
Expected: `0`.

- [ ] **Step 2: Create the overlays**

Each file is `<area>/<cloud>/<name>/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# A render root of its own, so CI renders this base with <cloud>'s fixture values
# (GCP parity GP-14). The Flux child for <cloud> points here.
resources:
  - ../../base/<name>
```

Use `aws-0` or `gcp-0` for `<cloud>`, and the base directory's name for `<name>`.

- [ ] **Step 3: Repoint the children**

In each child listed under *Modify*, `path: ./<area>/base/<name>` becomes `path: ./<area>/<cloud>/<name>`,
with its own cluster.

- [ ] **Step 4: Run the check to see it pass**

Run: `./scripts/ci/validate-manifests.sh && ls .bundle | grep -cE '^overlay-(infrastructure|security|observability)-(aws|gcp)-0-(agent-router|agent-mcp|envoy-ai-gateway|octo-sts|agent-secrets|agent-platform)\.yaml$' && grep -c 'container.googleapis.com' .bundle/overlay-infrastructure-gcp-0-agent-router.yaml`
Expected: `Invalid: 0, Skipped: 0`, then `12`, then a count ≥ 4: three issuers, three JWKS URIs and the
data-plane CNP host. `assert-ai-gateway.py` also passes inside `validate-manifests.sh`, now with an aws-0 and a
gcp-0 agent-router.

- [ ] **Step 5: Commit**

```bash
git add infrastructure/aws-0 infrastructure/gcp-0 security/aws-0 security/gcp-0 observability/aws-0 observability/gcp-0 clusters
git commit -m "feat(ci): one render root per cloud for every substituted agent base"
```

### Task 6.6: The gcp-0 `ai-gateway` umbrella and the shared rate limit (GP-17)

**Files:**
- Create: `clusters/gcp-0/ai-gateway.yaml`, `clusters/gcp-0-ai-gateway/{kustomization.yaml,infrastructure-llm-gateway.yaml}`,
  `infrastructure/base/envoy-gateway-ratelimit/kustomization.yaml`
- Move (`git mv`):
  - `clusters/gcp-0-llm-platform/{infrastructure-envoy-gateway,infrastructure-envoy-ai-gateway,infrastructure-vllm-semantic-router}.yaml`
    → `clusters/gcp-0-ai-gateway/`;
  - `infrastructure/aws-0/envoy-gateway/{kvstore.yaml,externalsecret-ratelimit-valkey.yaml,network-policy-ratelimit.yaml,vmpodscrape-ratelimit.yaml,helmrelease-ratelimit.yaml}`
    → `infrastructure/base/envoy-gateway-ratelimit/`
- Modify: `clusters/gcp-0/llm-platform.yaml`, `clusters/gcp-0-llm-platform/kustomization.yaml`,
  `infrastructure/{aws-0,gcp-0}/envoy-gateway/kustomization.yaml`,
  `clusters/gcp-0-ai-gateway/infrastructure-envoy-gateway.yaml`

**Interfaces:** Produces the Flux Kustomization `ai-gateway` on gcp-0 (`suspend: true`, `deletionPolicy: Orphan`),
with the children `envoy-gateway`, `envoy-ai-gateway`, `vllm-semantic-router` and `llm-gateway`, names
unchanged. `llm-platform` depends on it.

- [ ] **Step 1: The failing check**

Run: `kustomize build clusters/gcp-0-ai-gateway 2>&1 | grep -c '^kind: Kustomization'; kustomize build infrastructure/gcp-0/envoy-gateway | grep -c '^kind: KVStore'`
Expected: an error (no directory) or `0`, then `0`.

- [ ] **Step 2: Move and write**

```bash
mkdir -p clusters/gcp-0-ai-gateway infrastructure/base/envoy-gateway-ratelimit
git mv clusters/gcp-0-llm-platform/infrastructure-envoy-gateway.yaml clusters/gcp-0-llm-platform/infrastructure-envoy-ai-gateway.yaml clusters/gcp-0-llm-platform/infrastructure-vllm-semantic-router.yaml clusters/gcp-0-ai-gateway/
git mv infrastructure/aws-0/envoy-gateway/kvstore.yaml infrastructure/aws-0/envoy-gateway/externalsecret-ratelimit-valkey.yaml infrastructure/aws-0/envoy-gateway/network-policy-ratelimit.yaml infrastructure/aws-0/envoy-gateway/vmpodscrape-ratelimit.yaml infrastructure/aws-0/envoy-gateway/helmrelease-ratelimit.yaml infrastructure/base/envoy-gateway-ratelimit/
```

`infrastructure/base/envoy-gateway-ratelimit/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Envoy Gateway plus the global rate limit and its Valkey KVStore, which the
# llm-gateway token budgets need (SP4 PR 1). Cloud-neutral: both clusters'
# envoy-gateway overlays reference it (GCP parity GP-17).
resources:
  - ../envoy-gateway
  - kvstore.yaml
  - externalsecret-ratelimit-valkey.yaml
  - network-policy-ratelimit.yaml
  - vmpodscrape-ratelimit.yaml
patches:
  - path: helmrelease-ratelimit.yaml
```

Both `infrastructure/{aws-0,gcp-0}/envoy-gateway/kustomization.yaml` become:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# A render root per cloud (GCP parity GP-14) over the shared rate-limited base.
resources:
  - ../../base/envoy-gateway-ratelimit
```

In `clusters/gcp-0-ai-gateway/infrastructure-envoy-gateway.yaml`, add under `dependsOn`, as aws-0 has it:

```yaml
    # The KVStore claim needs its XRD.
    - name: crossplane-configuration
```

`clusters/gcp-0-ai-gateway/infrastructure-llm-gateway.yaml`:

```yaml
---
# Human and system frontier routes and backends on the ai-gateway Gateway, in
# namespace llm-gateway, plus that Gateway's token budgets and price rules.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: llm-gateway
  namespace: flux-system
spec:
  prune: true
  interval: 5m0s
  timeout: 5m0s
  path: ./infrastructure/base/llm-gateway
  sourceRef:
    kind: ExternalArtifact
    name: infra-artifact
  dependsOn:
    - name: envoy-ai-gateway
    - name: envoy-gateway
```

`clusters/gcp-0-ai-gateway/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Children of gcp-0's opt-in ai-gateway umbrella (../gcp-0/ai-gateway.yaml). The
# first three moved from gcp-0-llm-platform/ with their names unchanged, so every
# dependsOn edge that names them still resolves.
resources:
  - infrastructure-envoy-gateway.yaml
  - infrastructure-envoy-ai-gateway.yaml
  - infrastructure-vllm-semantic-router.yaml
  - infrastructure-llm-gateway.yaml
```

`clusters/gcp-0/ai-gateway.yaml`:

```yaml
---
# AI gateway layer, gcp-0's opt-in umbrella (the aws-0 twin, GCP parity). The
# Envoy Gateway and Agent Router controllers, the Semantic Router, and the
# frontier routes. agent-platform and llm-platform depend on it.
#
# Default: suspend: true. Only integration/agent-factory unsuspends it, in a
# test-only commit.
#
# deletionPolicy Orphan: removing this object must not uninstall Envoy Gateway
# and every Gateway on the cluster.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: ai-gateway
  namespace: flux-system
spec:
  suspend: true
  prune: true
  deletionPolicy: Orphan
  interval: 5m0s
  timeout: 5m0s
  # A sibling of clusters/gcp-0/, never a sub-path: flux-system syncs that tree
  # recursively and would apply the children around this suspend.
  path: ./clusters/gcp-0-ai-gateway
  sourceRef:
    kind: GitRepository
    name: flux-system
```

In `clusters/gcp-0-llm-platform/kustomization.yaml`, drop the three moved entries (keep `apps-llm.yaml`,
`security-llm-workloadidentity.yaml` and `tooling-promptfoo.yaml`). In `clusters/gcp-0/llm-platform.yaml`,
add under `spec` (before `path`):

```yaml
  # The GPU fleet attaches to the ai-gateway Gateway and its controllers.
  dependsOn:
    - name: ai-gateway
```

In its *Full teardown* comment, the `flux delete kustomization` list keeps only `llm-platform-apps`,
`llm-platform-security-wi` and `llm-platform-promptfoo`.

- [ ] **Step 3: Run the check to see it pass**

Run: `kustomize build clusters/gcp-0-ai-gateway | grep -c '^kind: Kustomization' && kustomize build infrastructure/gcp-0/envoy-gateway | grep -c '^kind: KVStore' && ./scripts/ci/validate-manifests.sh && python3 scripts/ci/flux-schema/check-substitution.py`
Expected: `4`, then `1`, then `Invalid: 0, Skipped: 0` (the AI-gateway budget gate included), and
check-substitution exit 0.

- [ ] **Step 4: Commit**

```bash
git add clusters/gcp-0 clusters/gcp-0-ai-gateway clusters/gcp-0-llm-platform infrastructure/base/envoy-gateway-ratelimit infrastructure/aws-0/envoy-gateway infrastructure/gcp-0/envoy-gateway
git commit -m "feat(gcp): gcp-0's ai-gateway umbrella, with the rate limit its budgets need"
```

### Task 6.7: The gcp-0 `agent-platform` umbrella

**Files:**
- Create: `clusters/gcp-0/agent-platform.yaml`, and in `clusters/gcp-0-agent-platform/`: `kustomization.yaml`,
  `infrastructure-agent-sandbox.yaml`, `infrastructure-agent-runtime.yaml`, `security-agent-policies.yaml`,
  `security-agent-secrets.yaml`, `infrastructure-agent-router.yaml`, `security-octo-sts.yaml`,
  `infrastructure-agent-mcp.yaml`, `observability-agent-platform.yaml`
- Modify: `.doc-claims.yaml`

**Interfaces:** Produces the Flux Kustomization `agent-platform` on gcp-0 (`suspend: true`, dependsOn
`ai-gateway`), whose children carry the same names as aws-0's. It has no `agents-nodepool` and no
`runtimeclass-gvisor` (GP-9).

- [ ] **Step 1: The failing check**

Run: `bash scripts/ci/tests/test-gcp-agent-prereqs.sh; kustomize build clusters/gcp-0-agent-platform 2>&1 | grep -c '^kind: Kustomization'`
Expected: `PASS` (Kyverno was added in 6.4), then an error or `0`.

- [ ] **Step 2: Write the umbrella and its children**

`clusters/gcp-0/agent-platform.yaml`:

```yaml
---
# Agent platform, gcp-0's opt-in umbrella (the aws-0 twin, GCP parity). Default
# suspend: true, so none of clusters/gcp-0-agent-platform/ exists. The sandbox
# pool is OpenTofu (gke/init sandbox.tf) and GKE ships the gvisor RuntimeClass,
# so unlike aws-0 no child builds nodes or a RuntimeClass.
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: agent-platform
  namespace: flux-system
spec:
  suspend: true
  prune: true
  interval: 1m0s
  timeout: 5m0s
  path: ./clusters/gcp-0-agent-platform
  sourceRef:
    kind: GitRepository
    name: flux-system
  # Agents run on frontier models through the ai-gateway controllers, with zero
  # GPUs: never llm-platform (C1).
  dependsOn:
    - name: ai-gateway
```

`clusters/gcp-0-agent-platform/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

# Flat list of gcp-0's agent-platform children: aws-0's minus agents-nodepool and
# runtimeclass-gvisor (GKE Sandbox provides both halves, GCP parity GP-9). A
# child that substitutes gke-gcp-0-vars points at a */gcp-0/* overlay
# (assert-cloud-shape.py).
resources:
  - infrastructure-agent-sandbox.yaml
  - infrastructure-agent-runtime.yaml
  - security-agent-policies.yaml
  - security-agent-secrets.yaml
  - infrastructure-agent-router.yaml
  - security-octo-sts.yaml
  - infrastructure-agent-mcp.yaml
  - observability-agent-platform.yaml
```

Write each child as a **copy of its aws-0 namesake** in `clusters/aws-0-agent-platform/`, with exactly these
changes:

| Child | `path:` | `substituteFrom` |
|---|---|---|
| `infrastructure-agent-sandbox.yaml` | `./infrastructure/base/agent-sandbox` | none (as aws-0) |
| `infrastructure-agent-runtime.yaml` | `./infrastructure/base/agent-runtime` | none |
| `security-agent-policies.yaml` | `./security/base/agent-policies` | none |
| `security-agent-secrets.yaml` | `./security/gcp-0/agent-secrets` | `gke-gcp-0-vars` |
| `infrastructure-agent-router.yaml` | `./infrastructure/gcp-0/agent-router` | `gke-gcp-0-vars` |
| `security-octo-sts.yaml` | `./security/gcp-0/octo-sts` | `gke-gcp-0-vars` |
| `infrastructure-agent-mcp.yaml` | `./infrastructure/gcp-0/agent-mcp` | `gke-gcp-0-vars` |
| `observability-agent-platform.yaml` | `./observability/gcp-0/agent-platform` | `gke-gcp-0-vars` |

Names, `dependsOn`, health checks, intervals and header comments stay identical. Copy them rather than
retyping.

In `.doc-claims.yaml`, find the claim H-1 Task 0.5.9 added for aws-0's umbrellas
(`grep -n 'agent-platform' .doc-claims.yaml`). Add a sibling claim of the same shape for
`clusters/gcp-0/agent-platform.yaml` and `clusters/gcp-0/ai-gateway.yaml` holding `suspend: true`.

- [ ] **Step 3: Run the check to see it pass**

Run: `kustomize build clusters/gcp-0-agent-platform | grep -c '^kind: Kustomization' && ./scripts/ci/validate-doc-claims.sh && python3 scripts/ci/flux-schema/check-substitution.py && ./scripts/ci/validate-manifests.sh`
Expected: `8`, doc-claims exit 0, check-substitution exit 0 (every `${…}` the gcp-0 children reach is a
`gke-gcp-0-vars` key), then `Invalid: 0, Skipped: 0`.

- [ ] **Step 4: Commit**

```bash
git add clusters/gcp-0/agent-platform.yaml clusters/gcp-0-agent-platform .doc-claims.yaml
git commit -m "feat(gcp): gcp-0's agent-platform umbrella"
```

### Task 6.8: The GCP render gate, `assert-cloud-shape.py` (GP-14)

**Files:**
- Create: `scripts/ci/flux-schema/assert-cloud-shape.py`, `scripts/ci/tests/flux-schema/test-assert-cloud-shape.py`
- Modify: `scripts/ci/validate-manifests.sh`

**Interfaces:** Produces `assert-cloud-shape.py BUNDLE_DIR [ROOT]`, with importable
`check_bundle(bundle_dir) -> list[str]` and `check_umbrellas(root) -> list[str]`. It exits 1 on any problem,
and prints `==> cloud shape: N gcp-0 overlay(s), M umbrella child(ren), 0 problem(s)`.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/flux-schema/test-assert-cloud-shape.py`:

```python
#!/usr/bin/env python3
"""assert-cloud-shape.py (GCP parity GP-14) against fixture bundles and trees."""
import importlib.util
import pathlib
import sys
import tempfile

try:
    import yaml  # noqa: F401
except ImportError:
    print("PyYAML is not installed")
    sys.exit(77)

ROOT = pathlib.Path(__file__).resolve().parents[4]
spec = importlib.util.spec_from_file_location("acs", ROOT / "scripts/ci/flux-schema/assert-cloud-shape.py")
if spec is None or not (ROOT / "scripts/ci/flux-schema/assert-cloud-shape.py").exists():
    print("FAIL assert-cloud-shape.py does not exist")
    sys.exit(1)
acs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(acs)

GKE = "https://container.googleapis.com/v1/projects/p/locations/z/clusters/gcp-0"
GOOD = f"""apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata: {{name: agent-router-public, namespace: agent-system}}
spec:
  jwt:
    providers:
      - name: p
        issuer: {GKE}
        remoteJWKS:
          uri: {GKE}/jwks
"""
fails = []


def bundle(files):
    d = pathlib.Path(tempfile.mkdtemp())
    for name, text in files.items():
        (d / name).write_text(text)
    return d


if acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD})):
    fails.append("a GKE-shaped gcp-0 agent-router must pass")
if not acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD.replace("/jwks", "/keys")})):
    fails.append("an EKS-shaped JWKS path on gcp-0 must fail")
if not acs.check_bundle(bundle({"overlay-security-gcp-0-octo-sts.yaml": "toFQDNs:\n  - matchName: oidc.eks.europe-west4.amazonaws.com\n"})):
    fails.append("an amazonaws.com host in a gcp-0 agent overlay must fail")
if not acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD.replace(GKE + "\n", "https://oidc.eks.x/id/Y\n", 1)})):
    fails.append("an EKS issuer on gcp-0 must fail")
if not acs.check_bundle(bundle({"overlay-infrastructure-aws-0-agent-router.yaml": GOOD})):
    fails.append("a bundle with no gcp-0 agent overlay is vacuous and must fail")
if acs.check_bundle(bundle({"overlay-infrastructure-gcp-0-agent-router.yaml": GOOD, "overlay-security-gcp-0-cert-manager-public.yaml": "region: eu-west-3\nrole: arn:aws:iam::1:role/x\nsts.amazonaws.com\n"})):
    fails.append("an out-of-scope gcp-0 overlay (Route53 federation) must not be judged")

tree = pathlib.Path(tempfile.mkdtemp())
(tree / "clusters/gcp-0-agent-platform").mkdir(parents=True)
child = """apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: {{name: agent-router, namespace: flux-system}}
spec:
  path: {path}
  postBuild:
    substituteFrom:
      - {{kind: ConfigMap, name: gke-gcp-0-vars}}
"""
(tree / "clusters/gcp-0-agent-platform/infrastructure-agent-router.yaml").write_text(child.format(path="./infrastructure/gcp-0/agent-router"))
if acs.check_umbrellas(tree):
    fails.append("a substituted child on a gcp-0 overlay must pass")
(tree / "clusters/gcp-0-agent-platform/infrastructure-agent-router.yaml").write_text(child.format(path="./infrastructure/base/agent-router"))
if not acs.check_umbrellas(tree):
    fails.append("a substituted child on a base/ path must fail")

for f in fails:
    print("FAIL", f)
if fails:
    sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/flux-schema/test-assert-cloud-shape.py; echo "exit $?"`
Expected: `FAIL assert-cloud-shape.py does not exist`, then `exit 1`.

- [ ] **Step 3: Implement**

`scripts/ci/flux-schema/assert-cloud-shape.py`:

```python
#!/usr/bin/env python3
"""Fail when gcp-0's agent and AI-gateway renders carry AWS-shaped values (GCP parity GP-14).

render-bundle.py substitutes a */gcp-0/* overlay with CLUSTER_FIXTURE_VARS["gcp-0"],
so these files show what gcp-0 will receive. A same-named variable holding an AWS
value -- ${region} inside oidc.eks.<region>.amazonaws.com, an EKS /keys JWKS --
renders schema-valid and fails only on the cluster (memory
flux_render_fixture_cross_cloud_blindspot). check-substitution.py catches a
MISSING key; this catches a wrong-shaped one, and a child that bypasses the
gcp-0 overlay so the render never sees gcp-0's values at all.

Scope is the agent platform and the AI gateway. Other gcp-0 overlays legitimately
name AWS (the Route53 federation) and are not judged here.
"""
import pathlib
import re
import sys

import yaml

SCOPED = re.compile(r"^overlay-(infrastructure|security|observability)-gcp-0-(agent-[a-z-]+|octo-sts|envoy-ai-gateway|envoy-gateway)\.yaml$")
# Only run tokens are judged by issuer: another gcp-0 policy may trust ZITADEL.
RUN_TOKEN = re.compile(r"-gcp-0-agent-(router|mcp)\.yaml$")
FORBIDDEN = [(re.compile(r"amazonaws\.com"), "an amazonaws.com host"), (re.compile(r"oidc\.eks\."), "an EKS issuer host")]
GKE_ISSUER = "https://container.googleapis.com/"
UMBRELLAS = ("clusters/gcp-0-agent-platform", "clusters/gcp-0-ai-gateway")


def _walk(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key:
                yield v
            yield from _walk(v, key)
    elif isinstance(node, list):
        for v in node:
            yield from _walk(v, key)


def check_bundle(bundle_dir):
    problems, seen = [], 0
    for f in sorted(pathlib.Path(bundle_dir).glob("overlay-*.yaml")):
        if not SCOPED.match(f.name):
            continue
        seen += 1
        text = f.read_text()
        for pattern, what in FORBIDDEN:
            if pattern.search(text):
                problems.append(f"{f.name}: {what} on gcp-0")
        if not RUN_TOKEN.search(f.name):
            continue
        for doc in yaml.safe_load_all(text):
            if not doc or doc.get("kind") not in ("SecurityPolicy", "MCPRoute"):
                continue
            for iss in _walk(doc, "issuer"):
                if isinstance(iss, str) and not iss.startswith(GKE_ISSUER):
                    problems.append(f"{f.name}: {doc['kind']} {doc['metadata']['name']} issuer {iss} is not GKE's")
            for uri in _walk(doc, "uri"):
                if isinstance(uri, str) and uri.startswith(GKE_ISSUER) and not uri.endswith("/jwks"):
                    problems.append(f"{f.name}: {doc['kind']} {doc['metadata']['name']} JWKS {uri} is not <issuer>/jwks")
    if seen == 0:
        problems.append("no gcp-0 agent or AI-gateway overlay in the bundle: the gate would be vacuous")
    return problems


def check_umbrellas(root):
    problems = []
    for d in UMBRELLAS:
        for f in sorted((pathlib.Path(root) / d).glob("*.yaml")):
            for doc in yaml.safe_load_all(f.read_text()):
                if not doc or doc.get("kind") != "Kustomization" or "toolkit.fluxcd.io" not in doc.get("apiVersion", ""):
                    continue
                subs = ((doc.get("spec") or {}).get("postBuild") or {}).get("substituteFrom") or []
                if any(s.get("name") == "gke-gcp-0-vars" for s in subs) and "/gcp-0/" not in doc["spec"].get("path", ""):
                    problems.append(f"{f.relative_to(root)}: substitutes gke-gcp-0-vars into {doc['spec']['path']}, "
                                    "which CI renders with AWS values; point it at a */gcp-0/* overlay")
    return problems


def main():
    bundle_dir = sys.argv[1] if len(sys.argv) > 1 else ".bundle"
    root = sys.argv[2] if len(sys.argv) > 2 else pathlib.Path(__file__).resolve().parents[3]
    problems = check_bundle(bundle_dir) + check_umbrellas(root)
    for p in problems:
        print(f"FAIL: {p}")
    scoped = sum(1 for f in pathlib.Path(bundle_dir).glob("overlay-*.yaml") if SCOPED.match(f.name))
    children = sum(1 for d in UMBRELLAS for f in (pathlib.Path(root) / d).glob("*.yaml") if f.name != "kustomization.yaml")
    print(f"==> cloud shape: {scoped} gcp-0 overlay(s), {children} umbrella child(ren), {len(problems)} problem(s)")
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
```

In `scripts/ci/validate-manifests.sh`, after the `assert-ai-gateway.py "${BUNDLE_DIR}"` line:

```bash
# gcp-0's agent and AI-gateway renders must be GKE-shaped (GCP parity GP-14).
python3 scripts/ci/flux-schema/assert-cloud-shape.py "${BUNDLE_DIR}"
```

- [ ] **Step 4: Run it to see it pass, then on the real bundle**

Run: `python3 scripts/ci/tests/flux-schema/test-assert-cloud-shape.py && ./scripts/ci/validate-manifests.sh 2>&1 | grep -E 'cloud shape|Invalid:'`
Expected: `PASS`. Then `==> cloud shape: 7 gcp-0 overlay(s), 12 umbrella child(ren), 0 problem(s)`:
- the 7 overlays are `agent-router`, `agent-mcp`, `envoy-ai-gateway`, `envoy-gateway`, `octo-sts`,
  `agent-secrets` and `agent-platform`;
- the 12 children are 8 plus 4.

Then `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/ci/flux-schema/assert-cloud-shape.py scripts/ci/tests/flux-schema/test-assert-cloud-shape.py scripts/ci/validate-manifests.sh
git commit -m "feat(ci): gate gcp-0's agent renders on GKE-shaped values"
```

### Task 6.9: The runbooks on gcp-0; gates and PR G-5

**Files:**
- Modify: `docs/runbooks/agent-factory/{README.md,01-runtime-sandbox.md,02-identity-tokens.md,03-egress.md,04-gateway-secrets-budgets.md,05-github-octo-sts.md,06-mcp.md,07-end-to-end.md,08-observability.md}`
- Create: `scripts/ci/tests/test-runbooks-gcp.py`

**Interfaces:** Produces runbooks whose every command targets gcp-0. Past rounds' results stay as history.

- [ ] **Step 1: Write the failing test**

`scripts/ci/tests/test-runbooks-gcp.py`:

```python
#!/usr/bin/env python3
# requires: python3
"""Every command in the agent-factory runbooks targets gcp-0 (GCP parity).
Only fenced code is judged: past rounds' prose and results stay as history."""
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[3]
AWSISMS = re.compile(r"priv\.aws\.ogenki\.io|opentofu/aws/|eks-aws-0|jwt/aws-0|\baws (sts|secretsmanager|ssm)\b|karpenter_nodepools|auth\.cloud\.ogenki\.io")
fails = []
for f in sorted((ROOT / "docs/runbooks/agent-factory").glob("*.md")):
    fenced = False
    for n, line in enumerate(f.read_text().splitlines(), 1):
        if line.lstrip().startswith("```"):
            fenced = not fenced
            continue
        if fenced and AWSISMS.search(line):
            fails.append(f"{f.name}:{n}: {line.strip()}")
for x in fails:
    print("FAIL", x)
if fails:
    sys.exit(1)
print("PASS")
```

- [ ] **Step 2: Run it to see it fail**

Run: `python3 scripts/ci/tests/test-runbooks-gcp.py | tail -3; echo "exit ${PIPESTATUS[0]}"`
Expected: `FAIL` lines across README, 02, 04, 05 and 08, then `exit 1`.

- [ ] **Step 3: Retarget**

In fenced code, everywhere:

| Replace | With |
|---|---|
| `priv.aws.ogenki.io` | `priv.gcp.ogenki.io` |
| `opentofu/aws/openbao/management/.tls/ca.pem` | `opentofu/gcp/openbao/management/.tls/ca.pem` |
| `eks-aws-0-vars` | `gke-gcp-0-vars` |
| `jwt/aws-0` | `jwt/gcp-0` |
| `auth.cloud.ogenki.io` | `auth.gcp.cloud.ogenki.io` |
| `aws sts get-caller-identity` | `gcloud auth application-default print-access-token >/dev/null && echo ADC-OK` |

Specific rewrites:
- **`README.md`**
  - Title: `# Agent Factory live test session — gcp-0`.
  - *Prerequisites*:
    - Tailscale reaching `*.priv.gcp.ogenki.io`;
    - gcloud ADC plus AWS credentials (the shared stacks only);
    - context `gke_ogenki-435905_europe-west4-a_gcp-0`;
    - `VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200`;
    - VictoriaLogs at `https://vl.priv.gcp.ogenki.io`.
  - *Runbook 00*: gcp-0 tracks `integration/agent-factory` (the parity plan's first deploy).
  - Owner action 1 is done by G-5: the `agents-secrets` policy and role are in the stacks.
  - Actions 2 and 4 become `bao kv put -mount=agents zai api_key=-` and
    `bao kv put -mount=agents github-app app_id=<id> private_key=@<pem file>`.
  - New action 4b: `bao kv put -mount=agents factory-app app_id=<id> private_key=@<pem file>`.
  - Add the note: "These three keys are the platform's one owner-written exception: GitHub and Z.ai issue
    them, and the AWS snapshot cannot be restored across KMS seals (GCP parity). Once per GCP lineage."
  - The footgun: "Deploy `*/openbao/management` and `gke/configure` only from an `integration/agent-factory`
    checkout, with `TF_VAR_flux_git_ref`: from `main`, the `agents` mount is destroyed and the agent platform
    pruned."
  - The *Out of scope* line about "The gcp-0 follow-up is a separate, unscoped design" goes.
  - A new *Status* line: "Retargeted to gcp-0 on 2026-09-29 (GCP parity plan); rounds 1–6 below ran on aws-0."
- **`04-gateway-secrets-budgets.md`**: Step 3's probes use `jwt/gcp-0` and `agents/data/zai`, and expect
  `read`, `deny`, `deny`, `deny` for `agents/data/zai`, `platform/data/agents/zai`, `platform/data/llm/zai`,
  `apps/data/anything`.
- **`05-github-octo-sts.md`**: the App key is at `github-app` on the `agents` mount. The trust policy accepts
  gcp-0's GKE issuer (G-0).
- **`08-observability.md`**: the pool check becomes

  ```bash
  kubectl get nodes -l sandbox.gke.io/runtime=gvisor --no-headers | wc -l
  gcloud container node-pools describe agents-gvisor --cluster gcp-0 --location europe-west4-a \
    --project ogenki-435905 --format='value(autoscaling.maxNodeCount)'
  ```

  with Expected `1` while a run is live and `2` for the maximum. The Karpenter panel is noted as empty on
  gcp-0 (GP-17).

- [ ] **Step 4: Run it to see it pass**

Run: `python3 scripts/ci/tests/test-runbooks-gcp.py && ./scripts/ci/validate-links.sh && ./scripts/ci/verify-doc-paths.sh`
Expected: `PASS`, then exit 0 twice.

- [ ] **Step 5: Every gate**

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh && ./scripts/ci/validate-vmrules.sh && ./scripts/ci/validate-doc-claims.sh && ./scripts/ci/validate-idp-topology.sh && ./scripts/ci/validate-openbao-policies.sh && python3 scripts/ci/flux-schema/check-substitution.py && task check`
Expected: `Invalid: 0, Skipped: 0` with `==> cloud shape: … 0 problem(s)`, then every command exit 0.

- [ ] **Step 6: Commit and open G-5 as a draft**

```bash
git add docs/runbooks/agent-factory scripts/ci/tests/test-runbooks-gcp.py
git commit -m "docs(runbooks): the agent-factory runbooks target gcp-0"
git merge origin/main
git push -u origin feat/gcp-agent-platform
```

Run `create-pr` as a **draft**, base `fix/agent-review-hardening`. Title:
`feat(agents): the agent platform on gcp-0 (GCP parity)`. The body:
- links the spec and plan;
- names G-1 to G-4 as merged-in prerequisites (the diff narrows once they reach `main`);
- names M1's move from SP2 S1 (GP-8);
- gives the Phase 7 position `#2111 → H-1 → G-5 → O-1 → S1`;
- says **programme stack: nothing merges before the owner's UX sign-off** (P33);
- carries a *Live evidence* section that Tasks 8.5 and 8.6 fill in.

Run: `gh pr checks <G-5> --watch`
Expected: every check green, `Kubernetes validation ☸` included.

---

## Phase 7 — The integration branch

### Task 7.1: `integration/agent-factory` carries the slice and unsuspends gcp-0

**Files:**
- Modify (integration branch only, never a PR): `clusters/gcp-0/ai-gateway.yaml`, `clusters/gcp-0/agent-platform.yaml`

**Interfaces:** Produces the ref gcp-0 syncs tonight.

- [ ] **Step 1: Worktree and merges**

`EnterWorktree` with branch `integration/agent-factory`, then `git reset --hard origin/integration/agent-factory`.

```bash
git merge --no-ff origin/feat/gcp-agent-platform -m "merge: GCP parity G-5 (with H-1 and G-1..G-4) into the integration branch"
```

If G-5 is not pushed by then, merge `origin/feat/gcp-primary` alone (G-1 to G-4). The platform deploys without
the agent platform, and G-5 lands later through Flux and three stack re-applies (GP-19).

- [ ] **Step 2: The test-only commit**

In both files, set `suspend: false  # integration branch only: the gcp-0 live test (never merged)`.

```bash
git add clusters/gcp-0/ai-gateway.yaml clusters/gcp-0/agent-platform.yaml
git commit -m "test: unsuspend gcp-0's ai-gateway and agent-platform (integration only, never merged)"
```

- [ ] **Step 3: Validate**

Run: `export XRD_CRDS_FILE="$(./scripts/ci/fetch-xrd-crds.sh)" && ./scripts/ci/validate-manifests.sh && ./scripts/ci/validate-idp-topology.sh && ./scripts/ci/validate-openbao-policies.sh`
Expected: `Invalid: 0, Skipped: 0`, `gcp hosts, all other clouds suspended.`, and parity passes.

- [ ] **Step 4: Push**

Run: `git push origin integration/agent-factory && git log -1 --format='%h %s' origin/integration/agent-factory`
Expected: the test-only commit.

---

## Phase 8 — Live, after the reset (2026-09-29 21:00)

### Task 8.1: [OWNER] Pre-flight, read-only

**Files:** none. Record the verdict table in G-1's *Live evidence*.

**Interfaces:** Produces three verdicts: `LINEAGE` (RESTORE or NEW), `ROLE_SUFFIX` (`_v3`, or the next free
one) and `LE_OK`.

- [ ] **Step 1 (P-1): AWS credentials, for the two shared stacks**

Run: `aws sts get-caller-identity --query Account --output text`
Expected: `396740644681`.

- [ ] **Step 2 (P-2): [OWNER] fresh ADC** (memory `gcp_reauth_expires_adc_mid_run`)

Run (owner, interactive): `! gcloud auth application-default login`, then
`gcloud auth application-default print-access-token >/dev/null && echo ADC-OK`.
Expected: `ADC-OK`.

- [ ] **Step 3 (P-3): Let's Encrypt budget**

Run: `curl -s 'https://crt.sh/?q=auth.gcp.cloud.ogenki.io&output=json' | jq --arg since "$(date -u -d '7 days ago' +%FT%T)" '[.[] | select(.not_before > $since and .name_value == "auth.gcp.cloud.ogenki.io")] | unique_by(.serial_number) | length'`
Expected: a number `< 5`. 5 or more: **stop.** The deploy would sit in `FailedMount` on
`zitadel-certificate` (memory `letsencrypt_rate_limit_blocks_rebuilds`).

- [ ] **Step 4 (P-4): Lineage inventory → RESTORE or NEW**

```bash
B=gs://ogenki-435905-ogenki-openbao-snapshot
gcloud storage ls "$B/" | sort | tail -3
gcloud storage ls "$B/*-gcpckms.snap" 2>/dev/null | sort | tail -1
gcloud secrets versions list openbao-priv-gcp-root-token --project ogenki-435905 --limit 1 --format='value(name,createTime)'
```

The verdict is **RESTORE** when a `-gcpckms` object exists and the root token's latest version was created
between 2026-09-11 and that object's timestamp. It is **NEW** otherwise, including when the token was re-copied
for the `awskms` standby after that snapshot (GP-7).

- [ ] **Step 5 (P-5): Management state addresses**

Run: `cd opentofu/gcp/openbao/management && tofu init -input=false >/dev/null && tofu state list | grep -c '^module.store_of_record'; cd -`
Expected: RESTORE: a count > 0 (the 09-11 addresses). NEW: any count; the new lineage is empty, and resources
in state that OpenBao no longer holds are re-created by the apply. RESTORE with 0: the apply's create of
`module.store_of_record.vault_mount.platform` collides with the restored mount. Before Task 8.2, import:
`tofu import 'module.store_of_record.vault_mount.platform' platform` and the same for `apps`. Terramate
cannot, so run it by hand from this directory with `-var-file=variables.tfvars`.

- [ ] **Step 6 (P-6): Custom role IDs**

Run: `gcloud iam roles list --project ogenki-435905 --show-deleted --filter='name~xplane_' --format='table(name.basename(),deleted)'`
Expected: no `_v3` row, or `_v3` rows with an empty `deleted`. A `_v3` row with `deleted=True`: set
`custom_role_suffix = "_v4"` on the integration branch (one commit, pushed) before Task 8.2 (GP-15).

- [ ] **Step 7 (P-7): Secret Manager holds the bootstrap tier and the sources**

```bash
for k in flux-github-app zitadel-google-idp openbao-priv-gcp-ca-chain openbao-priv-gcp-root-token \
         cnpg-xplane-zitadel-superuser runlore-credentials observability-victoria-metrics-k8s-stack-grafana-envvars \
         harbor-admin-password tailscale-k8s-operator-oauth headlamp-oauth2-proxy; do
  printf '%-58s %s\n' "$k" "$(gcloud secrets describe "$k" --project ogenki-435905 --format='value(name)' >/dev/null 2>&1 && echo present || echo MISSING)"
done
```

Expected: `present` ten times. `MISSING` on `cnpg-xplane-zitadel-superuser` is recoverable: stage 0's `seed`
derives it only from `zitadel-envvars`, so check that key too. Any other `MISSING`: stop and ask the owner.

- [ ] **Step 8 (P-8): [OWNER] The Google OAuth client**

The owner confirms, in the Google Cloud console, that the OAuth client `zitadel-google-idp` names lists
`https://auth.gcp.cloud.ogenki.io/ui/login/login/externalidp/callback`.

- [ ] **Step 9 (P-9): Leftovers from the last teardown** (memory `gke_lb_orphans_block_vpc_delete`)

Run: `bash scripts/ops/teardown/teardown.sh --verify-only; echo "exit $?"` with `TM_CLOUD=gcp`.
Expected: every GCP row empty. A leftover is cost, not a blocker; note it for the next teardown.

- [ ] **Step 10 (P-10): Stale `openbao-oidc`, only if NEW**

Run (owner, NEW only): `gcloud secrets delete openbao-oidc --project ogenki-435905 --quiet`
Expected: `Deleted secret [openbao-oidc]`. The first management apply then runs without OIDC, and Task 8.4
Step 3 enables it (GP-7).

### Task 8.2: [OWNER] The first deploy

**Files:** none. **Interfaces:** Produces gcp-0, tracking `refs/heads/integration/agent-factory`.

- [ ] **Step 1: A clean, current integration checkout**

```bash
git fetch origin && git merge --ff-only origin/integration/agent-factory
git status --short | wc -l
git log -1 --format='%h %s'
```

Expected: `0`, and the head is Task 7.1's test-only commit or later.

- [ ] **Step 2: Deploy** (the command the owner approved, with the pre-flight's lineage flag)

```bash
cd opentofu
export TM_CLOUD=gcp TF_VAR_flux_git_ref=refs/heads/integration/agent-factory
export OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true   # P-4 RESTORE. For NEW: unset it and export OPENBAO_NEW_LINEAGE=true
LOG="$HOME/gcp-deploy-$(date +%Y%m%dT%H%M).log"
terramate script run deploy >"$LOG" 2>&1; echo "TERRAMATE_EXIT=$?" >>"$LOG"
tail -1 "$LOG"
```

Expected: `TERRAMATE_EXIT=0` (memory `terramate_destroy_false_success`: the exit code is Terramate's, recorded
explicitly).
- An `invalid_rapt` in the log means the ADC expired mid-run. Re-login (P-2) and re-run the same command; it
  is idempotent.
- A `git-out-of-sync` refusal means Step 1 was not current. Re-run Step 1; never pass `-X`.

- [ ] **Step 3: Read the log**

```bash
grep -E 'STARTING A NEW|gcpckms.snap' "$LOG" | head -3
grep -nE 'Resources: [0-9]+ added, [0-9]+ changed, [1-9][0-9]* destroyed' "$LOG"
grep -cE '^\[skip\] aws stack' "$LOG"
grep -E '^\[(adopted|ok     |absent |deleted)\] (google_project_iam_custom_role|projects/ogenki-435905/roles/xplane_)|\[mirrored\]|zitadel-project-id ->' "$LOG"
```

Expected:
- the rehydrate names the `-gcpckms` object it restored (RESTORE), or prints `STARTING A NEW 'gcpckms' LINEAGE` (NEW);
- **no line** for the `destroyed` grep: a management apply that destroys anything means a stale checkout or
  wrong addresses, so stop;
- a positive `[skip]` count (the AWS lane);
- three role lines, four `[mirrored]` lines (grafana-envvars, headlamp-envvars, security-flux-ui-oidc,
  harbor-oidc) and one `zitadel-project-id ->`.

- [ ] **Step 4: Kube context and the core package** (Crossplane never upgrades an installed dependency)

```bash
gcloud container clusters get-credentials gcp-0 --location europe-west4-a --project ogenki-435905
TAG="$(sed -n 's#.*crossplane-configuration-gcp:\(v[^[:space:]]*\).*#\1#p' ../infrastructure/base/crossplane/configuration-gcp/configuration-packages.yaml)"
kubectl patch configuration.pkg.crossplane.io smana-crossplane-configuration-core --type merge -p "{\"spec\":{\"package\":\"ghcr.io/smana/crossplane-configuration-core:${TAG}\"}}"
kubectl wait --for=condition=Established crd/agentruns.cloud.ogenki.io --timeout=10m
```

Expected: `configuration… patched`, then `condition met`.

### Task 8.3: [LIVE] Platform gates and the migration

**Files:** none. Record every output in G-1's and G-4's *Live evidence*.

**Interfaces:** Consumes the verdicts and the running gcp-0.

- [ ] **Step 1: The break-glass login**

```bash
export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200 VAULT_CACERT="$PWD/opentofu/gcp/openbao/management/.tls/ca.pem"
gcloud secrets versions access latest --secret=openbao-priv-gcp-admin-credentials --project ogenki-435905 \
  | jq -r .password | bao login -method=userpass username=admin password=- >/dev/null
bao token lookup -format=json | jq -c '.data.policies'
```

Expected: `["admin","default","pki-admin","secrets-admin"]`.

- [ ] **Step 2: Mounts and policies**

Run: `bao secrets list -format=json | jq -r 'keys[]' | sort | tr '\n' ' '; echo; bao policy list | tr '\n' ' '`
Expected: the mounts include `agents/ apps/ lineage/ pki_private_issuer/ platform/`. The policies include
`admin agents-secrets cert-manager default external-secrets pki-admin secrets-admin snapshot`.

- [ ] **Step 3: [OWNER] Migrate the platform keys (GP-6)**

```bash
KEYS="harbor-admin-password,harbor-oidc,harbor-valkey-password,headlamp-envvars,runlore-credentials,runlore-slack-app,runlore-webhook,security-flux-ui-oidc,observability-flux-slack-app,observability-victoria-metrics-k8s-stack-grafana-envvars,observability-victoria-metrics-k8s-stack-alertmanager-slack-app,apps-app-wizard-llm,apps-app-wizard-oauth"
scripts/provision/secret-store.sh migrate --cloud gcp --project ogenki-435905 --keys "$KEYS"
scripts/provision/secret-store.sh migrate --cloud gcp --project ogenki-435905 --keys "$KEYS" --apply
```

Expected: the dry run lists 13 rows. The apply's summary is `copied: N, exists: M, absent: 0, skipped: 0`
with `N + M = 13`: RESTORE mostly `exists`, and the four OIDC keys `exists` (mirrored in stage 3).

- [ ] **Step 4: Force-sync, then every ExternalSecret and Kustomization**

```bash
kubectl annotate externalsecrets -A --all force-sync="$(date +%s)" --overwrite >/dev/null
sleep 60
kubectl get externalsecrets -A -o json | jq -r '.items[] | select((.status.conditions // [] | map(select(.type=="Ready"))[0].status) != "True") | "\(.metadata.namespace)/\(.metadata.name)"'
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -n flux-system -o json | jq -r '.items[] | select(.spec.suspend != true) | select((.status.conditions // [] | map(select(.type=="Ready"))[0].status) != "True") | .metadata.name'
```

Expected: both lists empty. The agent-system ExternalSecrets wait for Task 8.6's three keys; they are the
only allowed entries now.

- [ ] **Step 5: No store reads AWS**

Run: `kubectl get clustersecretstores,secretstores -A -o json | jq -r '.items[].spec.provider | keys[0]' | sort | uniq -c`
Expected: only `gcpsm` and `vault`.

- [ ] **Step 6: Capability probes on `jwt/gcp-0`**

```bash
T=$(bao write -field=token auth/jwt/gcp-0/login role=external-secrets jwt="$(kubectl create token external-secrets -n security --audience openbao --duration 10m)")
bao token capabilities "$T" platform/data/harbor/oidc; bao token capabilities "$T" agents/data/github-app; bao token revoke "$T"
T=$(bao write -field=token auth/jwt/gcp-0/login role=agents-secrets jwt="$(kubectl create token agents-secrets -n agent-system --audience openbao --duration 10m)")
bao token capabilities "$T" agents/data/github-app; bao token capabilities "$T" platform/data/harbor/oidc; bao token revoke "$T"
```

Expected, in order: `read`, `deny`; then `read`, `deny`.

- [ ] **Step 7: ZITADEL is fresh**

```bash
kubectl get sqlinstance -n security xplane-zitadel -o jsonpath='{.spec.objectStoreRecovery}{"|"}{.spec.backup.bucketName}{"\n"}'
kubectl get externalsecret -n security zitadel-masterkey -o jsonpath='{.spec.dataFrom[0].sourceRef.generatorRef.kind}{" "}{.status.conditions[0].reason}{"\n"}'
kubectl get deploy -n security zitadel -o jsonpath='{.status.readyReplicas}{"\n"}'
kubectl get cm -n flux-system gke-gcp-0-vars -o jsonpath='{.data.zitadel_project_id}{" "}{.data.identity_provider_url}{"\n"}'
gcloud secrets versions access latest --secret=zitadel-project-id --project ogenki-435905 | jq -r .project_id
```

Expected:
- `|ogenki-435905-ogenki-cnpg-backups`: no recovery, backups on;
- `Password SecretSynced`;
- `1` or more ready replicas;
- the ConfigMap's project id equals the Secret Manager one, and the IdP URL is `https://auth.gcp.cloud.ogenki.io`.

- [ ] **Step 8: Public DNS for the IdP** (memory `external_dns_child_domain_filter`)

Run: `dig +short auth.gcp.cloud.ogenki.io; kubectl get deploy -A -o json | jq -r '.items[] | select(.metadata.name | test("external-dns-public")) | .spec.template.spec.containers[0].args[]' | grep -c -- '--aws-zone-match-parent'`
Expected: an IP address, then `1`.

### Task 8.4: [OWNER] Identity: login, grant, OpenBao OIDC, SSO

**Files:** none. **Interfaces:** Produces the owner's `admin` grant in the fresh directory, and the OpenBao
OIDC login.

- [ ] **Step 1: [OWNER] First Google login**, at `https://grafana.priv.gcp.ogenki.io`. ZITADEL creates the
  human user.

- [ ] **Step 2: [OWNER] Grant**

```bash
IDP_URL=https://auth.gcp.cloud.ogenki.io PRIVATE_DOMAIN=priv.gcp.ogenki.io \
  scripts/provision/zitadel-oidc-clients.sh sync --cluster gcp-0 --cloud gcp --project ogenki-435905 \
  --openbao-url https://bao.priv.gcp.ogenki.io:8200 --openbao-root-token-secret openbao-priv-gcp-root-token \
  --openbao-ca-file opentofu/gcp/gke/configure/.tls/ca.pem --mirror-openbao \
  --grant-admin <owner email> --apply
```

Expected: a grant line for `admin` on the owner's user, and `[ok     ] openbao -- auth/oidc already uses client …`
or `[reconciled] …`. Nothing `[FAILED ]`.

- [ ] **Step 3: NEW lineage only: the second management apply creates OIDC**

Run: `TM_CLOUD=gcp terramate -C opentofu/gcp/openbao/management script run deploy 2>&1 | grep -E 'Plan:|Apply complete'`
Expected: `0 to change, 0 to destroy`, and only additions:
- the OIDC backend, its role, `openbao-admin` and its alias;
- one policy, group and alias per `secret_owning_apps` entry in `variables.tfvars`.

Then `Apply complete! … 0 destroyed.`

- [ ] **Step 4: [OWNER] OpenBao OIDC login**

Run: `bao login -method=oidc` (a browser), then `bao token lookup -format=json | jq -c '.data.identity_policies'`
Expected: `["admin","pki-admin","secrets-admin"]`.

- [ ] **Step 5: [OWNER] SSO on every consumer** (memory `gcp_gateway_hairpin_cross_node`)

| Consumer | URL | Expected |
|---|---|---|
| Grafana | `https://grafana.priv.gcp.ogenki.io` | logged in as Admin |
| Headlamp | `https://headlamp.priv.gcp.ogenki.io` | namespaces listed (workforce RBAC) |
| Flux UI | `https://flux-ui-gcp-0.priv.gcp.ogenki.io` | Kustomizations listed |
| Harbor | `https://harbor.priv.gcp.ogenki.io` | logged in via OIDC |

A consumer that hangs at the IdP redirect: its CNP has a port-scoped egress to `auth.gcp.cloud.ogenki.io`.
Fix it the way `tooling/gcp-0/headlamp/network-policy.yaml` does, in a G-4 commit. Harbor needs
`flux reconcile helmrelease harbor -n tooling` after a rotated client (09-11 bug 9).

### Task 8.5: [LIVE] The gVisor smoke probe

**Files:** uses `scripts/ops/k8s/gvisor-smoke.yaml` (Task 6.3). Record the output in G-5's *Live evidence*.

**Interfaces:** Proves GP-9, GP-10 and GP-11 before any agent run.

- [ ] **Step 1: GKE's RuntimeClass**

Run: `kubectl get runtimeclass gvisor -o jsonpath='{.handler} {.scheduling.nodeSelector}{"\n"}'`
Expected: `gvisor {"sandbox.gke.io/runtime":"gvisor"}`.

- [ ] **Step 2: Run the probe (scale from zero)**

```bash
kubectl apply -f scripts/ops/k8s/gvisor-smoke.yaml
kubectl wait -n gvisor-smoke pod/gvisor-smoke --for=jsonpath='{.status.phase}'=Succeeded --timeout=10m
kubectl logs -n gvisor-smoke gvisor-smoke
kubectl get node "$(kubectl get pod -n gvisor-smoke gvisor-smoke -o jsonpath='{.spec.nodeName}')" -o jsonpath='{.metadata.labels.sandbox\.gke\.io/runtime}{"\n"}'
```

Expected: `condition met`, then `threads=4 dns=ok tcp=ok release=4.4.0`, then `gvisor`. Failures:

| Output | Meaning | Action |
|---|---|---|
| a `RuntimeError: can't start new thread` or `Operation not permitted` | GKE Sandbox enforces RuntimeDefault with the clone3 trap | Stop. Owner decision: every AgentRun sets RuntimeDefault, and the constitution requires it |
| `socket.gaierror` | no DNS through a ClusterIP: per-packet LB is off | Check `kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose \| grep -i socket` |
| `TimeoutError` on connect | the CNP | `hubble observe --namespace gvisor-smoke --verdict DROPPED` |
| Pending > 10 min | the pool did not scale | `kubectl describe pod`; GP-10's machine-type fallback |

- [ ] **Step 3: Clean up, and the pool scales back to zero**

Run: `kubectl delete -f scripts/ops/k8s/gvisor-smoke.yaml --wait && sleep 900 && kubectl get nodes -l sandbox.gke.io/runtime=gvisor --no-headers | wc -l`
Expected: `namespace "gvisor-smoke" deleted`, then `0`.

### Task 8.6: [OWNER] The agents' keys, and the agent gates on gcp-0

**Files:** `docs/runbooks/agent-factory/*.md`: results tables, committed on G-5.

**Interfaces:** Produces the agent platform live on gcp-0, and the entry point for the programme gates.

- [ ] **Step 1: [OWNER] The one exception: three keys, once per GCP lineage**

```bash
bao kv put -mount=agents github-app app_id=<agents App id> private_key=@<pem file>
bao kv put -mount=agents factory-app app_id=<factory App id> private_key=@<pem file>
bao kv put -mount=agents zai api_key=-          # the key on stdin, never as an argument
shred -u <pem files>
for k in github-app factory-app zai; do printf '%s: %s\n' "$k" "$(bao kv get -format=json -mount=agents "$k" | jq -c '.data.data | keys')"; done
```

Expected: `github-app: ["app_id","private_key"]`, `factory-app: ["app_id","private_key"]`, `zai: ["api_key"]`.

- [ ] **Step 2: The agent platform is up**

```bash
kubectl annotate externalsecret -n agent-system --all force-sync="$(date +%s)" --overwrite >/dev/null
flux get kustomizations -n flux-system | grep -E '^(agent-secrets|agent-router|octo-sts|agent-mcp|agent-policies|llm-gateway)[[:space:]]'
```

Expected: every row `True`.

- [ ] **Step 3: G-0 is on `main`**

Run: `gh api repos/Smana/cloud-native-ref/contents/.github/chainguard/agent-implementer.sts.yaml --jq .content | base64 -d | grep -c 'container\\.googleapis'`
Expected: `1`. `0` means the owner has not merged G-0 yet (Task 1.1), and runbooks 05 and 07 wait for it.

- [ ] **Step 4: The runbooks, 01 to 08, on gcp-0**

Run them in order, as retargeted in Task 6.9, filling each results table in place.
Expected:
- 01 to 06 and 08 pass;
- 07 passes SC-04 (`task agent:run -- --role implementer --class public --task <issue url>` → a PR);
- the run's pod ran on a `sandbox.gke.io/runtime=gvisor` node;
- the run's token was accepted by `agent-router` (JWKS from `container.googleapis.com`) and by octo-sts.

Commit the results on G-5: `docs(runbooks): round 7, gcp-0`.

- [ ] **Step 5: Hand-off**

The programme gates now run on gcp-0 through their own plans, as amended in *Cross-plan edits*:
- H-1's Task 0.5.14, with CC-H1 through H-1's CI;
- O-1's Phase 3, with CC-O1 through O-1;
- SP2's `[LIVE]` tasks, once GP-18's TLS lands.

Teardown, when the owner asks: `TM_CLOUD=gcp scripts/ops/teardown/teardown.sh`, then `--verify-only` until
every row is empty.

---

## Self-review

**1. Spec coverage.**

| Spec item | Task |
|---|---|
| 1. Stage 2 on GCP: mounts, ESO and persona policies, OIDC | 2.1–2.5 (module + stack), 8.3, 8.4 |
| 1. `agents` mount; gcp-0 JWT roles `external-secrets` and `agents-secrets` | 6.1 (`external-secrets` was already a role; its policy now exists: 2.3) |
| 1. Reuse the AWS Stage 2 design, only the glue changes | GP-1, GP-2; AWS untouched until 6.1's M1 |
| 2. `primary_cloud = "gcp"`, one host | 5.1 |
| 2. A fresh ZITADEL with in-cluster keys, no seed | 5.2, 8.3 Step 7 |
| 2. Clients recreated; `zitadel_project_id` handled | 4.2–4.4, 4.3 (GP-4), 8.2 Step 3 |
| 3. `migrate --cloud gcp` | 2.4, 8.3 Step 3 |
| 3. The owner's three keys, and the exception recorded | spec *Secrets*, Global Constraints, ADR (5.1), 6.9 README, 8.6 Step 1 |
| 4. GKE Sandbox pool, spot, scale to zero, RuntimeClass `gvisor` | 6.3, 8.5 |
| 4. Composition and aws-0 selection checked; neutral or per-cloud | GP-9 (RuntimeClass carries it on both), 6.3 tolerations |
| 5. Umbrellas `gcp-0-ai-gateway` and `gcp-0-agent-platform` with GCP overlays | 6.5–6.7 |
| 5. DNS, issuers, node selection, observability | 6.2 (issuers), 6.5 (per-cloud `${private_domain_name}`), 6.3, 6.5 (observability overlay), GP-17 |
| 5. A GCP render fixture in CI | 6.2 (fixtures), 6.5, 6.8 |
| 6. AWS keeps only …; stacks under `TM_CLOUD=gcp` | spec table, ADR (5.1), `opentofu/AGENTS.md` (5.1) |
| 7. Runbooks retargeted | 6.9, 8.6 |
| 7. H-1, CC-H1, O-1, CC-O1 and SP2 gates on gcp-0 | *Cross-plan edits*, 0.1, 8.6 Step 5 |
| Every named risk has an early check | *Risks → early checks* table, 8.1 |
| The first deploy after the reset, with its gates | 8.2, 8.3–8.6 |
| Platform-fix PRs marked | PR map *Class* column |

No gap found.

**2. Placeholder scan.**
- `00NN` is resolved by a deterministic rule (Global Constraints). `<tag>` and `<owner email>` are values read
  in the same step.
- Two steps discover before they edit, each with an expected result: Task 6.3 Step 1 (the Vector toleration
  files) and Task 4.3 Step 3 (the `reconcile_workforce_audience` call site).
- Task 6.7 says "copy of its aws-0 namesake with exactly these changes". This is deliberate: retyping eight
  manifests invites drift, and the changes table is exhaustive.

**3. Consistency.**

| Name | Defined | Used |
|---|---|---|
| `store_write_and_mirror`, `mirror_to_openbao` | 4.2 | 4.2 (the test counts two call sites) |
| `bao_target_for` | 4.1 | 4.2 |
| `gcp_dns_editor_role` | 3.2 (ConfigMap, fixture) | the claim |
| `oidc_jwks_uri`, `oidc_jwks_host` | 6.2 | 6.8's gate |
| `custom_role_suffix` | 3.2 | 8.1 P-6 |
| `agents-secrets` | 6.1 (policy, role) | 8.3 Step 6 |
| `zitadel-project-id` | 4.3 | 8.3 Step 7 |
| `job_body()` | 3.1 | 3.2, 4.4 |
| `check_bundle`, `check_umbrellas` | 6.8 | its test |

The expected counts agree: 12 overlays (6.5), 4 ai-gateway and 8 agent-platform children (6.6, 6.7), and
`7 gcp-0 overlay(s), 12 umbrella child(ren)` (6.8). 6.8 counts 7 of the 12 overlays: the six gcp-0 ones
from 6.5, plus `envoy-gateway` from 6.6.

Fixed during review:
- 6.8's counts: `kustomization.yaml` is no longer counted as a child, and the overlay total is 7, not 8.
- The issuer rule is scoped to agent-router and agent-mcp, so a gcp-0 policy that trusts ZITADEL is not
  misjudged.
- 8.2's role grep matched no `[absent ]` line.
- 8.4's plan count no longer assumes an empty `secret_owning_apps`.
- 0.1 targets `main`, where the SP2 plan lives, plus the observability plan's own branch.
