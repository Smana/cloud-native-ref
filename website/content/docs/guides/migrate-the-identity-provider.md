---
title: Migrate the identity provider
weight: 50
description: Move ZITADEL between clouds — the database seed, the admin PAT and the client secrets travel together, or the result authenticates nobody.
lastVerified: 2026-09-06
---

ZITADEL is a **primary-cloud singleton**
([ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}})):
one directory, hosted on AWS by default, that *relocates* rather than duplicates.
You need this page in one situation — you bootstrapped on one cloud and now want
the other to host the identity provider. It is not part of a normal deploy.

{{< callout type="warning" >}}
**Designed, not yet proven end to end.** ADR-0027 says so plainly. Every step
below uses scripts verified in
[Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}) and
[Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}), but
the sequence as a whole has not been run.
{{< /callout >}}

## Three things move, not one

This is the part worth reading. ZITADEL's state lives in three places, and
copying only the obvious one produces a cluster that starts, looks healthy, and
authenticates nobody:

| # | What | Where it lives | Why the database is not enough |
|---|---|---|---|
| 1 | **Database seed** | CNPG backup | Holds users, IdP links, role grants, and OIDC app rows — but client secret **hashes**, not plaintext |
| 2 | **Admin PAT** | the source cloud's secret store | Never in the database. Every setup script resolves it first |
| 3 | **Five client secrets** | the source cloud's secret store | Written once at creation, because ZITADEL returns a client secret exactly once |

Move only the database and you get the compounding failure: the restored rows
point every OIDC client at the **old** domain, and the one tool that fixes that —
the setup scripts — needs the PAT you left behind. Recovery is minting a fresh
PAT through the console, which requires logging in, which is what the stale
configuration broke.

## The procedure

Examples are AWS → GCP; reverse the cloud arguments to go the other way.

**1. Freeze a seed on the source cloud** — same step as
[Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}):

```bash
./scripts/cnpg-promote-seed.sh --cluster xplane-zitadel --namespace security \
  --cloud aws --bucket eu-west-3-ogenki-cnpg-backups --apply
```

**2. Copy the seed to the target cloud's backup bucket**, then verify it:

```bash
aws s3 sync s3://eu-west-3-ogenki-cnpg-backups/zitadel-20260902/ /tmp/zitadel-seed/
gcloud storage rsync --recursive /tmp/zitadel-seed/ \
  gs://<gcp-project>-ogenki-cnpg-backups/zitadel-20260902/

./scripts/cnpg-promote-seed.sh --verify-seed zitadel-20260902 \
  --cloud gcp --bucket <gcp-project>-ogenki-cnpg-backups
```

**3. Copy the admin PAT:**

```bash
. scripts/lib/cloud-secret-store.sh

CLOUD=aws REGION=eu-west-3
pat="$(store_read zitadel/iam-admin-pat)"
[ -n "$pat" ] || { echo "source PAT is empty or absent — stop" >&2; exit 1; }

CLOUD=gcp GCP_PROJECT=<gcp-project>
store_write zitadel-iam-admin-pat <<< "$pat"
```

**4. Copy the five consumer client secrets:**

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

**5. Flip the two gates**, in the same commit. Both live on the GCP side — AWS
has no gate: whenever an `aws-0` cluster exists, it hosts ZITADEL.

| Gate | Where | For GCP-hosted |
|---|---|---|
| `primary_cloud` | `opentofu/config.tm.hcl` | `"gcp"` |
| `spec.suspend` | `clusters/gcp-0/security/zitadel.yaml` | `false` |

**Do not set `deploy_identity_provider` in `variables.tfvars`.** It is derived
from `primary_cloud` and passed as a `-var`, which wins over the file — adding
it there changes nothing and reports no error. `./scripts/validate-idp-topology.sh`
fails in CI if the two gates disagree.

**6. Deploy:**

```bash
cd opentofu && terramate script run deploy
flux reconcile kustomization zitadel -n flux-system
```

**7. Converge configuration to the new domain.** The seed carried identity and
the app rows, but every redirect URI and the Google IdP's `clientId` still name
the *source* domain. Run the steps from
[Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}) against the
target cluster — expect `[STALE]`/`[updated]` on fields naming the old domain
and `[ok]` elsewhere, since client IDs and secrets are unchanged by the move.
That same run rewrites Harbor's `harbor-oidc` entry; force it through with
`flux reconcile helmrelease harbor -n tooling --with-source` rather than waiting.

**8. Verify a login** at any consumer on the target cluster, with the same
Google account. The seed carried the IdP link and the role grant, so you should
land as the same user with the same roles. The Google OAuth client needs the
target cluster's callback URI listed once — a single OAuth client accepts every
cluster's callback, so if both were added at first setup, nothing changes there.

{{< callout type="warning" >}}
**Suspending is not decommissioning.** `spec.suspend: true` stops Flux
reconciling the outgoing instance; it does not remove what is already running.
Delete the outgoing cluster's ZITADEL release, its `SQLInstance` claim, TLSRoute
and certificate once the new host is serving — otherwise two directories keep
running while the topology check, which reads committed YAML rather than the
cluster, reports "consistent".
{{< /callout >}}

## Related

- [ADR-0027]({{< relref "/docs/decisions/0027-primary-cloud-provider.md" >}}) — why one directory relocates rather than duplicating
- [ADR-0024]({{< relref "/docs/decisions/0024-identity-provider-per-cloud.md" >}}) — what makes it deployable on either cloud
- [Set up single sign-on]({{< relref "/docs/get-started/sso.md" >}}) — the scripts step 7 runs
- [Restore a database]({{< relref "/docs/guides/restore-a-database.md" >}}) — the seed mechanism
