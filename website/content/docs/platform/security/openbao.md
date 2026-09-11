---
title: OpenBao
weight: 10
description: Namespace layout, the lineage and rehydrate-at-boot, operator login, JWT machine auth, backup and restore, and the 2.6.x concurrency constraint.
lastVerified: 2026-09-02
---

[Foundations]({{< relref "/docs/platform/foundations/aws.md#the-openbao-cluster-stack" >}})
covers how the OpenBao cluster is provisioned — a single Raft node
as committed (`mode = "dev"`), or five Raft nodes (3 on-demand + 2 spot)
with RAID-0 NVMe at `mode = "ha"`, with KMS auto-unseal either way. This page
covers what runs on top of that cluster:
`opentofu/aws/openbao/management/` layers namespaces, auth methods, the PKI, and
policies onto it, and this is the operational surface every other security
page and the [Access]({{< relref "/docs/get-started/access.md" >}}) guide
build on. `gcp-0` runs its own pair of stacks with a handful of deltas — see
[On GCP](#on-gcp-gcp-0) at the bottom.

One secret predates both stacks: OpenBao's own server certificate — the leaf
terminating TLS on `bao.priv.aws.ogenki.io:8200`, see
[PKI & Secrets]({{< relref "/docs/platform/security/pki-and-secrets.md#building-the-chain" >}})
— is generated offline and read from Secrets Manager at
`certificates/priv.aws.ogenki.io/openbao` (the `openbao_certificates_secret_name`
default in `opentofu/aws/openbao/cluster/variables.tf`, set explicitly in that
stack's `variables.tfvars`) by `opentofu/aws/openbao/cluster/` before the
management stack in this page ever runs.

{{< callout type="warning" >}}
**OpenBao stays on the 2.6 line (currently 2.6.2), not pinned back to an
older release.** 2.6.x carries [openbao/openbao#3411](https://github.com/openbao/openbao/issues/3411)
(inconsistent lock ordering between the core mounts lock and the namespace
lock, still open upstream) — but the concurrency that triggers it is the
management stack's own, not OpenBao's, and the fix is `-parallelism=1` on
both `apply` and `destroy` in `opentofu/aws/openbao/management/workflows.tm.hcl`,
marked in-code as load-bearing, not a caution. Older notes said "pin back to
2.5.5" — that's stale; don't repeat it. If you ever see `bao status` hang
against `127.0.0.1`, that's a **core deadlock**, not a VPN problem — check
the parallelism setting before chasing network connectivity.
{{< /callout >}}

## Namespace layout

Namespaces are tenancy boundaries, not folders. Earlier revisions nested the
PKI and operator logins under `admin`/`admin/pki`, which didn't hold up: an
`admin` namespace is a role, not a tenant, and cluster-wide operations
(`sys/storage/raft/*`, audit devices, seal operations) are root-only
regardless — a snapshot agent parked in a child namespace could never reach
them. **Both clusters are now root-namespace-only**, verified against
`opentofu/aws/openbao/management/` — there is no longer a `namespaces.tf` on
either side, because the last tenant namespace was removed with ADR-0036:

- **Root namespace** holds every shared platform service: the PKI mount
  (`pki_private_issuer`), the per-cluster JWT auth mounts (`jwt/aws-0`,
  `jwt/gcp-0`), the `lineage/` bookkeeping mount, the `oidc/` mount and its
  identity groups, the `userpass` operator login, and the **two kv-v2 secret
  mounts** — `platform/` and `apps/`. One login carries every platform policy,
  instead of one login per namespace.
- **The secret mounts are in root on purpose.** A policy binds only within the
  namespace it is created in, so a mount in a child namespace cannot be reached
  by a policy attached to a root identity group — and the OIDC groups that
  authorise humans are all in root. Who may read each mount, and what a
  developer writes to use one, is on the
  [Secrets]({{< relref "/docs/platform/security/secrets.md" >}}) page;
  [ADR-0036]({{< relref "/docs/decisions/0036-per-app-secret-ownership-via-zitadel-groups.md" >}})
  records why the alternative — a namespace per app — was rejected.
- **No tenant namespace exists.** An `app` namespace held a `secret/` kv-v2 mount
  and its own AppRole, built as a worked example for future tenants and consumed
  by nothing. It was removed with ADR-0036, because it was not merely unused but
  unusable in the direction that mattered: a policy binds only within its own
  namespace, so nothing attached to a root identity group — where the OIDC groups
  live — could reach that mount. Only a root token could. Left in place it read
  as the intended design rather than as the wrong turn it was.
- Cluster-wide endpoints such as `sys/storage/raft/*` are callable **only**
  from root — the API rejects them from any child namespace with a 404
  `unsupported path`, no matter what the token's policy grants.

## The lineage, and rehydrate at boot

OpenBao's storage is **derived state**. What persists is the *lineage*
([ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}})):

![What survives a teardown versus what is rebuilt on every deploy. On the left, the lineage that persists: the multi-region KMS seal key alias/openbao-seal with its eu-west-1 replica, five bootstrap secrets per cloud, the versioned S3 snapshot bucket whose objects are named UTC-timestamp-seal.snap, and the GCS mirror populated daily by Storage Transfer. In the centre, everything rebuilt on each deploy: the single-node EC2 OpenBao instance auto-unsealed by the seal key with no operator input, its Raft store, the pki_private_issuer mount holding the offline-signed intermediate, the lineage kv-v2 mount carrying check_timestamp, and one jwt mount per cluster. On the right, the consumers, which authenticate by JWT only with no AppRole anywhere: cert-manager issuing every internal TLS leaf, External Secrets, and the openbao-snapshot CronJob at 04:00 UTC, all three reaching OpenBao at openbao.security.svc.cluster.local:8200. Five numbered flows connect them: rehydrate at boot restoring the newest snapshot, the seal key unsealing the node, consumers authenticating with projected ServiceAccount tokens, the daily snapshot named for the seal that wrote it, and the mirror to GCS](/images/diagrams/openbao-lineage-1.svg)

| Component | Where |
|---|---|
| Seal key `alias/openbao-seal`, multi-region (replica in `eu-west-1`) | `opentofu/aws/openbao/lineage/` |
| Snapshot bucket `eu-west-3-ogenki-openbao-snapshot` and its key | same stack (imported from Crossplane) |
| CA chain, server TLS material, root token, recovery keys, the offline-signed intermediate | AWS Secrets Manager, hand-seeded — **five** entries, not four |

The CA chain is the one most easily left off that list, and it is the one read
*first*: both management stacks fetch it with `openbao-config.sh ca` before
rehydrate on every deploy — `global.openbao_ca_cmd` in
`opentofu/config.tm.hcl` on AWS, `global.openbao_ca_fetch` in the stack's own
`workflows.tm.hcl` on GCP — and the `VAULT_CACERT` every command on this page
uses is that fetch's output.

Both modes run the `raft` storage backend — `storage "raft"` in
`opentofu/aws/openbao/cluster/scripts/startup_script.sh` — because a snapshot
can neither be taken from nor restored into anything else.

{{< callout type="warning" >}}
**The `jwt/<cluster>` mount comes back too — carrying the destroyed cluster's
issuer.** A restored snapshot brings back every mount, including the per-cluster
JWT auth mount, and its `oidc_discovery_url` still names the OIDC issuer of the
cluster that no longer exists. Two things then go wrong at once: the cluster's
`configure` stack cannot create a mount that is already there
(`path is already in use at jwt/<cluster>/`), and if it could, the stale issuer
would fail every workload login against a mount reporting perfectly healthy.

`scripts/openbao-adopt-jwt-mount.sh` runs before that apply on both clouds — it
imports the restored mount and its roles into state so the apply *updates* the
issuer instead of failing to create it. Observed doing exactly that on a
2026-09-06 rebuild:

```
bound_issuer = ".../id/A0F8FD418B41D2BABB156BCFBF4BF5E2"   # the destroyed cluster
            -> ".../id/2E20D33A73D10E44983F863D574FBE8D"   # this one
```
{{< /callout >}}

On every deploy, the management stack's workflow runs
`./scripts/openbao-config.sh rehydrate`: a fresh node is initialised with
throwaway shares that are **never stored**, the newest snapshot is restored
into it, and the root token and recovery keys already in Secrets Manager
belong to the restored state. If the bucket is empty — the first deploy of a
lineage — it is a plain init and the new keys are stored. Before the cluster
stack is destroyed, its workflow takes one last snapshot, so nothing written
since the daily CronJob is lost.

The lineage and management stacks are **never destroyed by the default
`destroy`**: their `destroy` scripts no-op unless `TM_LINEAGE_DESTROY=true`.
`gcp-0` has the same shape under `opentofu/gcp/openbao/lineage/` (its seal key
was already a hand-created prerequisite).

## Operator login

On `aws-0`, human operators authenticate with `userpass`, not the root
token. The root token is **not** retired: it stays valid for the lineage and is
what the **management stack** authenticates with, from an operator's or CI's
context — its `vault` provider reads it straight out of Secrets Manager.
`rehydrate` does **not** use it: it authenticates with the throwaway root token
that its own `bao operator init` returns, and after the restore with one minted
from the lineage's recovery keys. It never reads the stored root token at all,
which is what lets a rehydrate work on a node whose token store is about to be
replaced wholesale. Retiring it needs an OIDC login for humans, which is a
follow-up. `gcp-0` has the same login from the shared
`openbao-store-of-record` module; its password is in Secret Manager as
`openbao-priv-gcp-admin-credentials`. The backend and user are provisioned by Terraform
(`opentofu/aws/openbao/management/auth.tf`), not created by hand:

```bash
export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200
export VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem   # written by `openbao-config.sh ca`
bao login -method=userpass username=admin
```

Use `VAULT_CACERT`, never `VAULT_SKIP_VERIFY` — a security reference that
tells readers to skip TLS verification undercuts itself, and the real CA
chain is one command away. The password is generated by the management stack
and published to Secrets Manager:

```bash
aws secretsmanager get-secret-value \
  --secret-id openbao/cloud-native-ref/users/admin \
  --query SecretString --output text | jq
```

The `admin` login carries both the `admin` and `pki-admin` policies. It has
no `token_bound_cidrs`, unlike the tenant AppRole below — the only route to
the API is the internal NLB, so the network is already constrained, and a
CIDR bind on the one break-glass credential buys nothing against the risk of
locking yourself out of the secrets store.

## JWT: machine authentication

Workloads authenticate with a **projected ServiceAccount token**, validated by
OpenBao's JWT method against the cluster's public OIDC issuer. Nothing
long-lived is minted or stored. One mount per cluster:

| Mount | Created by | Roles (audience `openbao`) |
|---|---|---|
| `jwt/aws-0` | `opentofu/aws/eks/configure/openbao.tf` | `cert-manager`, `external-secrets`, `openbao-snapshot` |
| `jwt/gcp-0` | `opentofu/gcp/gke/configure/openbao.tf` | same |

The mount lives in the *configure* stack because the EKS issuer URL carries a
per-cluster ID that changes on every rebuild, and the management stack runs
before `eks/init`. The policies the roles bind stay in the management stack.
Each role is bound to one ServiceAccount by full subject
(`system:serviceaccount:security:cert-manager`) and tokens live 10 minutes,
because JWKS validation never consults the API server: a token Kubernetes
revoked stays valid until it expires.

The policy behind each role is scoped to exactly the paths it needs — the
`snapshot` policy grants the Raft snapshot endpoint and the one key that
records when the snapshot was taken, nothing else:

```hcl
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}

# The freshness marker (mounts.tf, `lineage/`). kv-v2 puts data under /data/.
path "lineage/data/check_timestamp" {
  capabilities = ["create", "update"]
}
```

The former AppRole backend, its `snapshot-agent` and `cert-manager` roles and
their Secrets Manager entries are gone. The `app` tenant namespace keeps its
own AppRole as the worked tenancy example: it has no minted `SecretID` and so
no Secrets Manager entry at all, because nothing consumes it yet and an unused
live credential is worse than none
(`opentofu/aws/openbao/management/auth.tf`) — mint one by hand with
`bao write -f -namespace=app auth/approle/role/app/secret-id` only when
something needs it.

## Cluster initialisation

Initialisation is not a day-2 operation — it happens once per *lineage*,
on the first deploy, and is automated rather than run by hand. Every deploy
after that rehydrates instead (see
[The lineage](#the-lineage-and-rehydrate-at-boot)):
`terramate script run deploy` calls `scripts/openbao-config.sh` (`init` subcommand — see
[Commands]({{< relref "/docs/reference/commands.md" >}}) for the full script
table), which runs `bao operator init -recovery-shares=1 -recovery-threshold=1` and
writes the result to **two separate** Secrets Manager entries:

| Entry | Contains |
|---|---|
| `openbao/cloud-native-ref/tokens/root` | The initial root token |
| `openbao/cloud-native-ref/tokens/recovery` | The recovery key(s) |

Two details here are load-bearing:

- **The recovery keys are persisted at all**, not just echoed to stdout and
  discarded. Without them, `bao operator generate-root` is impossible — a
  lost or revoked root token would leave the cluster unrecoverable, and the
  restore path below could never authenticate.
- **They live in a different secret than the root token.** Storing both
  together makes the pair only as strong as whichever secret leaks first.

`-recovery-shares=1 -recovery-threshold=1` fits an automated flow — one
share, one holder. For anything longer-lived than a demo cluster, raise both
and distribute the shares to separate holders instead of one Secrets Manager
entry.

Sanity checks once the cluster is up:

```bash
bao status                       # Initialized: true, Sealed: false
bao operator raft list-peers     # ha mode only — lists every Raft voter
```

## Backup and restore

Raft's own snapshot mechanism, automated end to end — nothing here is a
manual `bao operator raft snapshot save` run by a human on a schedule.

**Backup.** A CronJob in the `security` namespace (manifests under
`security/base/openbao-snapshot/`) logs in through `jwt/<cluster>` as
`openbao-snapshot` to save a Raft snapshot and ship it to S3. Before the
snapshot it writes `lineage/check_timestamp`, the marker a restore uses to
report the age of what it installed. A Storage Transfer job mirrors the bucket
into GCS daily at 05:00 UTC, an hour after the snapshot run;
`google_storage_transfer_job.s3_mirror` in
`opentofu/gcp/openbao/lineage/transfer.tf` carries
`count = var.aws_mirror_role_arn == "" ? 0 : 1`, so an empty
`aws_mirror_role_arn` in that stack's `variables.tfvars` means no mirror job at
all and a GCS side populated only by hand — worth checking before relying on it,
as the
[failover guide]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}})
shows. Its EKS Pod Identity role deliberately has
**no** `secretsmanager` permission: a daily backup pod able to read the
material that regenerates a root token would be a privilege escalation, not
a convenience. Trigger one manually with:

```bash
kubectl create job --namespace security --from=cronjob/openbao-snapshot manual-openbao-snapshot-$(date +%s)
```

**Restore.** `scripts/openbao-snapshot.sh` (`restore` subcommand) fetches
the newest snapshot from the bucket, authenticates — a supplied `VAULT_TOKEN`
wins, otherwise it mints a temporary root token from the recovery key —
restores, then reads the lineage's **stored** root token from
`ROOT_TOKEN_SECRET_ID` — a Raft restore replaces the token store, so the
snapshot's own root token is the valid one again by construction — and checks
`lineage/check_timestamp`. It falls back to minting one only when that variable
is unset, and that fallback cannot succeed on an auto-unsealed node (405).

That check is an **alarm, not a gate**. The marker lives inside the snapshot,
so it can only be read once the restore has already been applied: it reports
the age of what was installed and exits non-zero under `--freshness fail`. It
cannot prevent a stale restore. Run the command as an **operator**, never as
the CronJob — it needs `RECOVERY_KEYS_SECRET_ID` and AWS credentials that can
read that secret, which the snapshot job's Pod Identity role is deliberately
denied.

The block below is self-contained — every variable the script needs is
exported here, not assumed left over from the Operator Login section above:

```bash
export VAULT_ADDR="https://bao.priv.aws.ogenki.io:8200"
export VAULT_CACERT=opentofu/aws/openbao/management/.tls/ca.pem
export VAULT_TOKEN=...   # the ROOT token. `admin` cannot restore: neither
                         # admin.hcl nor pki-admin.hcl grants sys/storage/raft/*
export RECOVERY_KEYS_SECRET_ID="openbao/cloud-native-ref/tokens/recovery"
# REQUIRED. Without it the post-restore step falls through to
# `bao operator generate-root -init`, which returns 405 on an auto-unsealed
# node -- every node in this design -- and the run dies under `set -e` with the
# Raft restore ALREADY APPLIED. `rehydrate` works only because
# scripts/openbao-config.sh passes this for you.
export ROOT_TOKEN_SECRET_ID="openbao/cloud-native-ref/tokens/root"
./scripts/openbao-snapshot.sh restore -a "${VAULT_ADDR}" \
  -b eu-west-3-ogenki-openbao-snapshot -s /tmp/bao.snap -d 8
```

### Restoring a specific snapshot, not the newest

`restore` takes the newest object unless `OPENBAO_SNAPSHOT_KEY` names another.
That default is right for the case this platform runs nightly — destroyed and
rebuilt from its own newest backup — and it cannot express the other one:
*today's value is wrong, give me yesterday's*. The bucket is versioned and keeps
120 days.

{{< callout type="warning" >}}
**Only about the first 30 days are directly restorable.**
`opentofu/aws/openbao/lineage/s3.tf` transitions objects to **GLACIER** at 30
days, and `aws s3 cp` on one fails `InvalidObjectState` — it has to be restored
out of Glacier first, which takes hours. The 120 days is retention, not reach.
Add `StorageClass` to the listing below before choosing an old object, and note
that the `-d 8` in the example also fails anything older than 8 days under the
default `--freshness fail`.
{{< /callout >}}

```bash
# What is there, oldest first
aws s3api list-objects-v2 --bucket eu-west-3-ogenki-openbao-snapshot \
  --query 'sort_by(Contents,&LastModified)[].[Key,LastModified,StorageClass]' --output text

export OPENBAO_SNAPSHOT_KEY="2026-09-05T092947Z-awskms.snap"
./scripts/openbao-snapshot.sh restore -a "${VAULT_ADDR}" \
  -b eu-west-3-ogenki-openbao-snapshot -s /tmp/bao.snap -d 8
```

The name is checked against the bucket listing before anything is downloaded, so
a typo fails by printing what *is* there rather than part-way through a
destructive restore. **Every write after the chosen object is discarded**, and
the script says so in the log rather than letting that be a surprise. The seal
gate still applies: naming an object does not exempt it.

{{< callout type="warning" >}}
**A restore is not verified until you have read your own data back.** The weekly
drill asserts the PKI issuer and the GCS mirror, and it *cannot* check anything
else: it deliberately holds no credentials, so a compromised runner cannot
authenticate to the restored node. That is the right call for CI and it means
the drill can never tell you your application secrets came back. After any
restore you care about, read one:

```bash
VAULT_NAMESPACE=app bao kv get -mount=secret <a-key-you-know>
```
{{< /callout >}}

### Recovery point objective

Snapshots run **daily at 04:00 UTC**, plus one immediately before every teardown.
Nothing captures a write between those points.

So the worst case is a credential written just after a snapshot and lost before
the next one: **up to ~24 hours of writes**. For the PKI that is close to
irrelevant — certificates are reissued on demand and cert-manager renews them
anyway. For anything whose value cannot be regenerated, it is the number that
matters, and it is the one to revisit before OpenBao becomes the store of record
for application credentials. Shortening it is a schedule change in
`security/base/openbao-snapshot/`; the cost is bucket growth against the 120-day
lifecycle rule, not risk.

Prerequisites worth stating plainly:

- **Both modes are Raft**, so snapshots work in `dev` too.
- **The script only automates a recovery threshold of 1.** A higher threshold
  makes it exit and tell you to run `bao operator generate-root` by hand.
- **The restore path is exercised on every deploy** (rehydrate). It also runs
  weekly, from `.github/workflows/openbao-restore-drill.yml`, which restores the
  newest snapshot into a throwaway node with nothing but the seal key and asserts
  the PKI issuer chains to the offline root. Its inputs are in place:
  `openbao-root-ca.pem` is committed under `.github/`, and the three repository
  variables it reads (`AWS_DRILL_ROLE_ARN`, `GCP_DRILL_WIF_PROVIDER`,
  `GCP_DRILL_SERVICE_ACCOUNT`) are set. It ran green on 2026-09-06, restoring the
  snapshot the previous evening's teardown had taken and verifying the issuer
  against the committed offline root with `openssl verify`. A second job asserts
  the seal unwraps on `AWS_WEB_IDENTITY_TOKEN_FILE` alone, having first checked no
  static credential is present — separate because static credentials outrank web
  identity in the AWS SDK's chain, so a combined job would pass either way.
- **Cross-cloud**: [OpenBao cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).

## On GCP (gcp-0)

`gcp-0` runs the same three-stack shape — `opentofu/gcp/openbao/lineage/`,
`opentofu/gcp/openbao/cluster/` and `opentofu/gcp/openbao/management/` —
against `https://bao.priv.gcp.ogenki.io:8200`, with GCP Secret Manager in
Secrets Manager's role: `openbao-priv-gcp-server-cert`,
`openbao-priv-gcp-root-token`, `openbao-priv-gcp-recovery-keys`,
`openbao-priv-gcp-intermediate-ca` and `openbao-priv-gcp-ca-chain` (dash
names — a GCP secret ID cannot contain `/`). The deltas from everything
above:

- **Root namespace only.** The Stage 2 mounts, policies, `userpass`
  break-glass and ZITADEL OIDC login come from
  `opentofu/shared/modules/openbao-store-of-record` (ADR-0037); the
  break-glass password is published to `openbao-priv-gcp-admin-credentials`.
  There is no `app` namespace and so no tenant AppRole.
- **Snapshots ship to GCS.** `security/gcp-0/openbao-snapshot/` patches the
  shared CronJob with `CLOUD=gcp`; `scripts/openbao-snapshot.sh` branches to
  `gcloud storage` / `gs://` on that switch. The cluster is single-node Raft,
  rehydrated from `ogenki-435905-ogenki-openbao-snapshot` like AWS; with
  `seal_provider = "awskms"` it is the standby for the AWS lineage — see
  [OpenBao cross-cloud failover]({{< relref "/docs/guides/openbao-cross-cloud-failover.md" >}}).
- **`scripts/openbao-config.sh` takes `--cloud gcp`** (plus `--project`), and
  its `ca` subcommand reads `openbao-priv-gcp-ca-chain` as raw PEM rather
  than AWS's JSON-shaped `certificates/priv.aws.ogenki.io/ca-chain`.
