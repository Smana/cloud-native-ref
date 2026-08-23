# GCP foundation — status and resume plan

**Date:** 2026-08-23
**Branch:** `worktree-gcp-foundation` · **PR:** [#1818](https://github.com/Smana/cloud-native-ref/pull/1818) (47 commits)
**Infrastructure:** everything torn down. Nothing running on AWS or GCP.

---

## Where things stand

| | State |
|---|---|
| PR #1818 | Open, `MERGEABLE`, **6/6 required checks green** |
| Checkov | Red — see [Blocker 1](#blocker-1--checkov-cannot-be-made-green-in-code) |
| GCP | Deployed, validated end-to-end, torn down. All three states empty |
| AWS | Rebuilt today from empty state, validated, torn down |
| Design | [ADR-0017](../../../website/content/docs/decisions/0017-multi-cloud-dns-naming.md) records the DNS decision |

Both clouds have been proven to build from nothing and be destroyed cleanly. That
was the point of the exercise; the remaining work is merge mechanics and follow-ups.

---

## Blockers

### Blocker 1 — Checkov cannot be made green in code

**This needs a decision in the GitHub UI, not a commit.** Do not spend time trying
to annotate your way out of it; that was tried and verified not to work.

The inline `checkov:skip` annotations are *correct* — verified locally:

```
checkov -f opentofu/gcp/network/nat.tf   →  Skipped checks: 1
```

But the Checkov **GitHub App does not honour them**, and re-reports the findings
anyway. Meanwhile `main` itself carries **72 open Checkov alerts**, six of which
are the same `CKV_TF_1` module-pinning rule this PR is flagged for. The PR is
being blocked by a policy the default branch does not satisfy either.

Remaining alerts, all either refuted on review or pre-existing on `main`:

| Alert | Verdict |
|---|---|
| `CKV_SECRET_6` on `flux-instance.yaml:41` | False positive — the line is `pullSecret: "flux-system"`, a Secret *name*. AWS's identical file carries the identical alert on `main` |
| `CKV_TF_1` × 5 | `main` has 6 open right now |
| `CKV_GCP_36` / `CKV_GCP_38` | Refuted on security review; already accepted for trivy, which passes clean |

**The real security finding was fixed, not silenced** — the two `roles/editor`
errors are gone because the resource is gone.

Options: dismiss the alerts in the Security tab; make Checkov advisory to match
how it already behaves for `main`; or leave it red. There is no admin bypass —
`enforce_admins` is on.

### Blocker 2 — merge order will 404 the cluster's Git source

Only relevant if a cluster is running at merge time. The `FluxInstance` tracks
`refs/heads/worktree-gcp-foundation`, and this repo **auto-deletes head branches on
merge**. Merging #1818 with a live cluster pointed at that branch breaks its source.

Before merging, either cut the FluxInstance over to `main` first, or restore the
branch immediately after:

```bash
git push origin worktree-gcp-foundation:worktree-gcp-foundation
flux reconcile source git flux-system
```

---

## What is left

### Deferred, needs AWS running

- **Task 9** — AWS Gateway API re-key onto the shared `gateway-api-crds` module.
  The module exists and GCP uses it; AWS still hand-lists 11 URLs in
  `opentofu/aws/eks/configure/locals.tf`. Needs `moved` blocks.
- **Task 10** — acceptance pass.
- Task 7 (tailnet singletons) is **done** — that was the substance of it.

### Follow-ups found by review, not yet actioned

- **`terraform_remote_state` hard-fails on an empty upstream state.** Today's
  teardown needed `tofu destroy -refresh=false` to get past it. Any repeated or
  out-of-order destroy hits it again.
- **`shared/tailscale` has no `opt-in` tag**, so a root `--reverse destroy` would
  take the tailnet ACL down for **both** clouds.
- **Four Terramate scripts run ungated on GCP** — `init`, `drift detect`,
  `drift reconcile`, `render` have no GCP override, so the opt-in gate is
  incomplete.
- **Teardown leaks, three found today** (see [Traps](#traps-found-today)).
- **Unreviewed by more than one pair of eyes:** destroy-ordering under every
  failure mode, `depends_on` gaps, and the `clusters/gcp-mycluster-0/` Flux wiring.
  Two review agents produced nothing across repeated asks.

### ClusterMesh prerequisites (recorded in ADR-0017, not implemented)

- `cluster.id` is unset on both clusters; ClusterMesh needs a unique 1–255 ID.
- AWS does not advertise its pod CIDR (`100.64.0.0/16`) into the tailnet, so
  cross-cloud pod-to-pod has no route. GCP does advertise its own.
- **Unverified:** whether ClusterMesh works across the clusters' different Cilium
  IPAM modes (`eni` vs `kubernetes`) and asymmetric encryption (WireGuard on AWS
  only). Test on throwaway clusters before designing on it.

---

## Resume procedure

### Rebuild AWS

```bash
cd opentofu/aws/network        && terramate script run --disable-check-git-remote deploy
cd ../openbao/cluster          && terramate script run --disable-check-git-remote deploy
```

OpenBao then needs initialising before its management stack will apply:

```bash
./scripts/openbao-config.sh init \
  --url https://bao.priv.aws.ogenki.io:8200 \
  --root-token-secret-name openbao/cloud-native-ref/tokens/root \
  --recovery-keys-secret-name openbao/cloud-native-ref/tokens/recovery \
  --skip-verify

cd opentofu/aws/openbao/management
bash ../../../../scripts/openbao-config.sh ca \
  --root-ca-secret-name certificates/priv.aws.ogenki.io/root-ca \
  --ca-output-file .tls/ca.pem
terramate script run --disable-check-git-remote deploy
```

Then the cluster, tracking the branch:

```bash
cd opentofu/aws/eks/init
TF_VAR_flux_git_ref='refs/heads/worktree-gcp-foundation' \
  terramate script run --disable-check-git-remote deploy
```

`--disable-check-git-remote` is needed because the branch is ahead of `main`;
Terramate's freshness check otherwise refuses to run.

### Before rebuilding — clear the CNPG live prefixes

Both recovering databases fail if their **live** WAL prefix is non-empty:

```bash
aws s3 rm s3://eu-west-3-ogenki-cnpg-backups/xplane-zitadel-cnpg-cluster/ --recursive --region eu-west-3
aws s3 rm s3://eu-west-3-ogenki-cnpg-backups/xplane-harbor-cnpg-cluster/  --recursive --region eu-west-3
```

Do **not** touch the recovery sources — `zitadel-20260719/` and `harbor-20241111/`
are what they bootstrap *from*. `xplane-image-gallery-cnpg-cluster/` is a live
prefix for an instance that bootstraps `initdb`; leave it alone.

### Rebuild GCP

Gated behind `TM_GCP_ENABLED=true`; the default deploy skips it.

```bash
cd opentofu/gcp/network        && TM_GCP_ENABLED=true terramate script run --disable-check-git-remote deploy
cd ../gke/init                 && TM_GCP_ENABLED=true terramate script run --disable-check-git-remote deploy
```

Requires application-default credentials, separate from the gcloud active account:

```bash
gcloud auth application-default login --scopes=openid,https://www.googleapis.com/auth/cloud-platform
```

---

## Traps found today

Each of these cost real time and is invisible until it bites.

1. **A background task's exit code lied.** The EKS deploy reported exit 0 while
   stage 2 had failed. Read the output, not the status line.
2. **Teardown leaks, in three different places**, each breaking a *different* part
   of the next rebuild:
   - **Route53 records** — 20 stale external-dns records blocked the zone
     replacement with `HostedZoneNotEmpty`.
   - **CNPG WAL archives** — non-empty live prefixes made both recovering
     databases `unrecoverable`. The bucket still holds archives from earlier
     rebuilds (`harbor-20241111`, `zitadel-20260505`, `zitadel-20260719`).
   - **CSI EBS volumes** — previously recorded, unfixed.

   These share one root cause worth fixing once, in the teardown scripts, rather
   than symptom by symptom.
3. **A domain rename invalidates leaf certificates, not just names.** Copying the
   CA preserved a *hostname-bound* server cert. Worse, the intermediate that signed
   it had **no private key stored anywhere** — OpenBao issued it, so the key lives
   inside OpenBao. Circular: to re-issue the cert OpenBao needs to serve, OpenBao
   must already be serving. That forced a fresh CA.
4. **`opentofu/aws/eks/configure/variables.tfvars` was never tracked** — fixed in
   `bf83b4b7`. It only ever worked from a checkout holding an untracked local copy.
5. **Two scanners want their directives in different places.** trivy's
   `#trivy:ignore` must sit immediately above the resource (a prose comment between
   voids it); checkov's must sit *inside* the block. Recorded in
   `opentofu/gcp/network/tailscale.tf`.
