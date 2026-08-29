---
title: Migrate the identity provider
weight: 50
description: Move ZITADEL from AWS to a GCP-only platform, or back — the database seed, the admin PAT and the client secrets travel together, or the result authenticates nobody.
lastVerified: 2026-08-29
---

[ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}})
names ZITADEL a **primary-cloud singleton**: one identity directory, hosted on
AWS by default, that *relocates* rather than duplicates when the platform runs
GCP-only. [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}})
is what makes relocating possible — ZITADEL is deployable on either cloud
behind two gates. This page is the written procedure both records point at
instead of automation, because the move is deliberate and occasional, not
something that should happen as a side effect of enabling a cluster.

{{< callout type="warning" >}}
**Designed, not yet proven end to end.** ADR-0027 says so plainly: "this
relocation has never been performed end to end; until it has, treat the
GCP-only path as designed rather than proven." Every step below is built from
the same scripts and mechanisms verified in
[Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}) and
[Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}), but
the sequence as a whole has not been run.
{{< /callout >}}

## Why three things, not one

ZITADEL's state splits across three places, and a move that copies only the
obvious one — the database — produces a cluster that starts, looks healthy, and
authenticates nobody:

1. **The database seed.** Users, Google IdP links, role grants, and the OIDC
   app rows (client IDs and secret *hashes*, not the plaintext).
2. **The admin PAT**, in the source cloud's secret store. Every setup script —
   the only thing that can converge configuration to the new domain — resolves
   it from there first (see
   [Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}})). It is
   not in the seed; it never was in the database at all.
3. **The five consumer client secrets**, also in the source cloud's secret
   store. The database only ever held their hashes — the plaintext was written
   to the store once, at creation, because ZITADEL returns a client secret
   exactly once.

Move only #1 and the result is the failure mode this design exists to close,
compounded: the restored database points every OIDC client at the *old*
domain, and the one tool that fixes that — the setup scripts — needs the PAT
the move left behind. Without it every script fails at
`resolve_zitadel_pat`'s first line, on every cluster, and the only documented
recovery is minting a fresh PAT by hand through the ZITADEL console — which
itself depends on being able to log in, which is exactly what a stale
configuration on the new domain breaks. Move all three together and none of
this applies: the scripts authenticate immediately and converge the stale
domain in the same run that Tasks 4 and 5 of this plan built for precisely this
purpose.

## 1. Freeze a seed on the source cloud

Identical to the "Freeze a seed" step of
[Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}): take
a one-shot `Backup`, wait for `phase=completed`, then copy the cluster's live
prefix to a dated one so the seed is a known, unmoving state rather than
whatever the live archive happens to hold when you read it later.

```bash
kubectl apply -n security -f - <<'EOF'
apiVersion: postgresql.cnpg.io/v1
kind: Backup
metadata:
  name: zitadel-migration-seed
  namespace: security
spec:
  cluster:
    name: xplane-zitadel-cnpg-cluster
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
EOF

kubectl get backup -n security zitadel-migration-seed -w   # wait for phase=completed
```

## 2. Copy the seed to the target cloud's backup bucket

AWS → GCP:

```bash
aws s3 sync s3://eu-west-3-ogenki-cnpg-backups/xplane-zitadel-cnpg-cluster/ \
  /tmp/zitadel-seed/
gcloud storage rsync /tmp/zitadel-seed/ \
  gs://<gcp-project>-ogenki-cnpg-backups/zitadel-$(date +%Y%m%d)/
```

GCP → AWS is the reverse: `gcloud storage rsync` down, `aws s3 sync` up. Then
point the *target* cluster's claim at the new dated prefix — on GCP that is
`security/gcp-0/zitadel/kustomization.yaml`'s `objectStoreRecovery.path`
patch, on AWS `security/base/zitadel/sqlinstance.yaml`'s.

`bootstrap` is immutable on an existing CloudNativePG cluster, so this only
takes effect on a cluster created fresh from that claim — the same
force-a-recreate procedure as the "Force the bootstrap" step of
[Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}),
including clearing the target's live WAL archive first if it already holds
one, or the restore refuses with `Expected empty archive`.

## 3. Copy the admin PAT

The PAT lives in the source cloud's secret store, not in the seed. Both
`store_read`/`store_write` in `scripts/lib/cloud-secret-store.sh` key purely
off the `CLOUD`/`REGION`/`GCP_PROJECT` shell variables, so reading from one
cloud and writing to the other is a plain round trip through those functions —
no reshaping, since the stored value is already the `{"pat": "..."}` object
`resolve_zitadel_pat` expects on read:

```bash
# from the repo root
. scripts/lib/cloud-secret-store.sh

# AWS -> GCP
CLOUD=aws REGION=eu-west-3
pat="$(store_read zitadel/iam-admin-pat)"
[ -n "$pat" ] || { echo "source PAT is empty or absent — stop" >&2; exit 1; }

CLOUD=gcp GCP_PROJECT=<gcp-project>
store_write zitadel-iam-admin-pat <<< "$pat"
```

GCP → AWS is the same shape, reversed — `zitadel-iam-admin-pat` (GCP; Secret
Manager forbids `/`) becomes `zitadel/iam-admin-pat` (AWS).

## 4. Copy the five consumer client secrets

Same round trip, same keys on both clouds — these names carry no cloud prefix
([ADR-0023]({{< relref "/docs/decisions/0023-portable-secret-store-names.md" >}}) is why):

```bash
for key in \
  observability-victoria-metrics-k8s-stack-grafana-envvars \
  headlamp-envvars \
  security-flux-ui-oidc \
  headlamp-oauth2-proxy \
  harbor-oidc
do
  CLOUD=aws REGION=eu-west-3
  val="$(store_read "$key")"
  [ -n "$val" ] || { echo "MISSING on source: $key" >&2; continue; }

  CLOUD=gcp GCP_PROJECT=<gcp-project>
  store_write "$key" <<< "$val"
  echo "copied: $key"
done
```

These five are consumer-side conveniences, not what actually authenticates a
login — Grafana, Headlamp and the rest read them into environment variables at
pod start. Missing one only breaks that one consumer's SSO button; it does not
block the scripts in the next section, which read ZITADEL and Harbor directly.

## 5. Flip the two ADR-0024 gates

Both gates live on the GCP side — AWS has no gate at all; whenever an `aws-0`
cluster exists, it hosts ZITADEL. "GCP-only" means no `aws-0` cluster running,
not a flag flipped there.

| Gate | Where | Target value for GCP-hosted |
|---|---|---|
| `deploy_identity_provider` | `opentofu/gcp/gke/configure/variables.tfvars` | `true` |
| `spec.suspend` | `clusters/gcp-0/security/zitadel.yaml` | `false` |

They must agree in the same commit — one alone points every consumer at a
hostname nothing serves, or runs an instance nothing is configured to use, and
neither half can detect the other is wrong.

Migrating back to AWS is the reverse: `deploy_identity_provider = false` and
`spec.suspend: true` on the GCP side; nothing to flip on AWS, since it has no
gate to begin with.

## 6. Deploy

```bash
cd opentofu && terramate script run deploy
flux reconcile kustomization zitadel -n flux-system
```

This is what creates the cluster from the claim you pointed at the new seed in
step 2, and what applies the gate flip from step 5.

## 7. Run the setup scripts to converge configuration to the new domain

The database seed carried over identity and the OIDC app rows, but every
redirect URI, the Google IdP's `clientId`, and the action script still name the
*source* cloud's domain. This is exactly the convergence this design built:
`zitadel-oidc-clients.sh` reconciles redirect URIs in place rather than
skipping the existing clients (#1919), and `zitadel-idp.sh` converges drifted
fields instead of reporting stale objects as fine (this plan's Task 4). Run the
steps from [Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}})
with the target cluster's values — expect `[STALE]`/`[updated]` on the fields
that name the old domain, and `[ok]`/`[skip]` on everything else, since client
IDs and secrets are unchanged by the move.

Harbor's `oidc_endpoint` still names the source cloud's domain too, but there is
no script to run for it: `zitadel-oidc-clients.sh`, re-run above against the
target cluster, already rewrote the `harbor-oidc` store entry with the new
endpoint. The target cluster's `ExternalSecret` + `HelmRelease` reconcile pick
that up on their own schedule — see
[ADR-0028]({{< relref "/docs/decisions/0028-harbor-oidc-config-overwrite-json.md" >}}).
Force it immediately rather than waiting out the intervals with
`flux reconcile helmrelease harbor -n tooling --with-source` after confirming
the `harbor-oidc-config` Secret already holds the new values.

## 8. Verify a login

Log in through Google at any consumer on the target cluster, using the same
Google account you used on the source cloud. The seed carried the IdP link and
the role grant, so you should land as the same user with the same roles — no
re-grant needed, unlike a fresh (unrestored) bootstrap.

The Google OAuth client's authorized redirect URI needs the target cluster's
callback URI listed once — see "The one step no script can do" in
[Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}).
If both clusters' callback URIs were already added when the source cloud was
first set up, nothing changes on Google's side; a single OAuth client accepts
every cluster's callback URI, and this is unaffected by which cloud currently
hosts ZITADEL.

## Related

- [Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}) — the
  scripts this procedure re-runs, and what "converge" means for each
- [Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}) —
  the seed/freeze/force-bootstrap mechanics this procedure reuses
- [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) —
  the two gates
- [ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}}) —
  why ZITADEL relocates instead of duplicating
