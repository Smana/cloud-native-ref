# OpenBao as the store of record: a snapshot lineage, rehydrate-at-boot, and cross-cloud fallback

**Date**: 2026-09-02
**Status**: Approved design, awaiting plan
**Changes the target stated in**: [ADR-0025](../../../website/content/docs/decisions/0025-cloud-managed-secret-stores.md)
(the cost record stays; what changes is how the target is reached)

## Summary

OpenBao becomes the platform's store of record for secrets and the PKI, without
raising the idle cost of the reference platform. The mechanism is a **lineage**:
one persistent KMS seal key, four bootstrap secrets, and a snapshot bucket.
Everything else OpenBao holds is derived from the latest Raft snapshot and is
**rehydrated at boot**. A production deployment leaves the process on; the
reference platform turns it off between runs. Both run the same design.

One OpenBao is active, on the primary cloud (AWS, [ADR-0027](../../../website/content/docs/decisions/0027-primary-cloud-provider.md)).
Both clusters consume it. If AWS becomes unavailable, the GCP OpenBao stack comes
up sealed by the **same AWS KMS key** reached through OIDC federation, restores the
latest snapshot from a GCS mirror, and consumers repoint to it. The fallback
survives an AWS regional outage and the loss of AWS compute or Secrets Manager; it
does not survive the loss of the AWS account, which is a deliberate trade
(scenario A, below).

The work is staged. Stage 1 builds the foundation and removes every risk the
design carries, with the managed store still the store of record. Stage 2 is a
single repoint of the `ClusterSecretStore` plus a migration of about 36 secrets.

## What we found

Six facts about the current platform shaped this design. Each is verified against
the repository at the commit this document was written on.

1. **The cost constraint is already recorded.** ADR-0025 (2026-08-27) explains why
   the cloud's managed secret store is the store of record and OpenBao holds only
   the PKI: the store must be always-on and outlive the platform, and an always-on
   OpenBao is the cost the reference is engineered to avoid. Its Neutral section
   says OpenBao remains the target store of record. This design keeps the record
   and changes the mechanism by which the target is reached.
2. **OpenBao's unseal key is destroyed with the platform.** `opentofu/aws/openbao/cluster/kms.tf`
   creates the seal key inside the ephemeral cluster stack with a 10-day deletion
   window. Every rebuild mints a new key, so every snapshot taken under the
   previous key is unreadable by the next cluster. Harmless today because `dev`
   mode runs the `file` backend and never takes a snapshot; fatal for any design
   that restores one.
3. **The restore procedure is documented as a hypothesis.** `scripts/openbao-snapshot.sh restore`
   exists, and the OpenBao page says plainly that nothing tests it.
4. **The AWS root CA private key is inside the live PKI mount.** The GCP OpenBao
   design (2026-08-24) fixed this on GCP with an offline root and an openssl-signed
   intermediate, and left "AWS follows" out of scope. Tailnet clients therefore
   trust two anchors today.
5. **Every managed-store secret except the bootstrap tier is consumed after
   OpenBao is up.** The deploy order is `network` → `openbao/cluster` →
   `openbao/management` → `eks/init` → `eks/configure`
   (`after` in each `stack.tm.hcl`). Flux's GitHub App key is read by
   `eks/configure`, two stacks after OpenBao.
6. **Neither cluster's pods can reach the other cloud's OpenBao.** The Tailscale
   subnet routers advertise each VPC to tailnet *devices*; pods are not devices.
   The Tailscale operator (1.90.6, with a `ProxyGroup` already in use) supports
   cluster egress to an IP behind a subnet router, which closes the gap.

## Goals

- OpenBao is the store of record for platform secrets and the PKI on both clouds,
  and the reference platform's idle floor stays within about $2/month of today's
  $23.
- The restore path is exercised on every deploy of the reference platform and by
  a scheduled drill, not documented as a hypothesis.
- One offline root of trust. No CA private key on a networked system.
- No long-lived credential is minted for a workload to reach OpenBao: workloads
  authenticate with their cluster's ServiceAccount tokens.
- A written, executed fallback from AWS to GCP that survives an AWS regional
  outage, with a stated RPO and RTO.
- GCP-only deployments ([ADR-0024](../../../website/content/docs/decisions/0024-identity-provider-per-cloud.md))
  keep working with no AWS dependency.

## Non-goals

- Running the production posture (always-on, 3-node Raft) in this repository's
  own environment. It is documented and made a configuration change, not deployed.
- Dynamic database credentials, the transit engine, and tenant namespaces beyond
  the existing `app` example. The design makes them cheap to add later; it does
  not add them.
- Human authentication to OpenBao through ZITADEL (OIDC auth method). Follow-up.
- Surviving the loss of the AWS account or a deliberate exit from AWS. See
  "Decisions taken".
- Changing the Crossplane compositions in `Smana/crossplane-configuration`.

## Decisions taken during brainstorming

These were argued in the brainstorming session and are recorded here so the plan
does not reopen them.

**"Single source of truth" was challenged and reframed.** A single *store* is
unreachable by construction: OpenBao's own server certificate, root token, recovery
keys and seal cannot live in OpenBao. A single *access path* already exists (one
`ClusterSecretStore` per cluster). What OpenBao adds over a managed store is the
ability to *issue* short-lived credentials and a single portable policy and audit
model; for static blobs it adds nothing. The target is therefore: a minimal
bootstrap tier in the managed store, and OpenBao as store of record for everything
that is consumed after it is up, on identical paths on both clouds.

**Seal scenario A.** The standby is sealed by the same AWS KMS key as the active,
made multi-region, and reached from GCP through OIDC federation. Auto-unseal is
kept; nobody types a key at a restart. Rejected: a Shamir seal on the standby
(survives account loss, but every restart becomes a human action and Raft
auto-join breaks), and seal migration during failover (the docs require both old
and new seal services reachable, which an outage denies).

**Option 2, staged.** Adopt OpenBao as store of record in the reference platform
through rehydrate-at-boot, with the risk-removing foundation (Option 3) as the
first milestone and a gate before the repoint. Rejected: a written target the
reference does not run (leaves the restore hypothesis in place), and a big-bang
repoint.

**OpenBao changes class in ADR-0027's taxonomy**, from *per-cloud* to
*primary-cloud singleton*, with a property the other singletons do not have: its
relocation carries state.

## Target architecture

### Tiers

| Tier | Where it lives | Contents (per cloud) | Who reads it, when |
|---|---|---|---|
| Bootstrap | AWS Secrets Manager / GCP Secret Manager | OpenBao server TLS cert, key and chain | the instance at boot, before the API exists |
| Bootstrap | same | root token | the management stack, and the restore path, after boot |
| Bootstrap | same | recovery keys | the restore path, to mint a root token after a snapshot lands |
| Bootstrap | same | intermediate CA cert and key, signed by the offline root | the first seeding of a lineage only; afterwards the PKI mount comes back inside the snapshot |
| Store of record | OpenBao | every other platform secret, in a `platform/` kv-v2 mount; the PKI; auth methods and policies | External Secrets, cert-manager, the `eks/configure` stack, operators |

The seal key is the fifth bootstrap item, an AWS resource rather than a secret.

Flux's GitHub App key is the one judgment call. It lets Flux clone the repository
that defines everything else, and it is consumed by `eks/configure`, after
OpenBao. **Decision: it moves to OpenBao in Stage 2**, because "the bootstrap tier
is exactly what OpenBao needs to come back" is a rule worth keeping clean, and an
OpenBao that cannot serve it is an OpenBao under which nothing else works either.
The plan records this so it can be reversed with one line if operating experience
says otherwise.

### The lineage

A lineage is everything needed to bring back an identical OpenBao anywhere. It
lives in a **new persistent stack per cloud**, `opentofu/aws/openbao/lineage/` and
`opentofu/gcp/openbao/lineage/`, applied before the cluster stack and **never
destroyed by the default `destroy` script**. The destroy override reuses the
opt-in gate pattern from `opentofu/aws/llm-platform/workflows.tm.hcl`: it no-ops
unless `TM_LINEAGE_DESTROY=true`, and says so.

| Component | AWS lineage | GCP lineage |
|---|---|---|
| Seal key | multi-region KMS key, primary `eu-west-3`, one replica in a second region; alias `alias/openbao-seal`; key policy admits the standby role | unchanged: the Cloud KMS key ring and key are already hand-created prerequisites read by data source (`opentofu/gcp/openbao/cluster/kms.tf`), which is exactly the property AWS lacks |
| Snapshot bucket | `${region}-ogenki-openbao-snapshot` and its KMS key, **imported** from the Crossplane MRs in `security/aws-0/openbao-snapshot/` | the GCS bucket, imported from `security/gcp-0/openbao-snapshot/gcs-bucket.yaml` |
| Mirror | — | a Storage Transfer Service job pulling the S3 bucket into the GCS bucket on the snapshot cadence (see Snapshots) |
| Standby identity | — | the service account the standby VM runs as, created here so its unique ID is stable and can be trusted by the AWS side before the VM exists |
| Bootstrap secrets | referenced by name; created by hand as today | same |

Why the buckets move out of Crossplane: rehydrate needs the bucket to exist
*before* the cluster that would create it, and the GCS mirror must exist even when
`gcp-0` has never been deployed, otherwise the DR promise silently depends on the
second cloud having been built once. The Crossplane MRs carry no `Delete`
management policy, so removing the manifests orphans the buckets instead of
deleting them, and `import` blocks adopt them.

The **management stack becomes part of the lineage too**: its resources (PKI
mount, auth mounts, policies, the `app` namespace) are lineage state that the
snapshot carries. Destroying it at teardown would delete them from the live
OpenBao right before the pre-destroy snapshot, so it gets the same destroy gate.
Its OpenTofu state stays valid across rebuilds because a restored OpenBao holds
the same resources at the same paths.

### Rehydrate at boot

Today `opentofu/aws/openbao/management/workflows.tm.hcl` runs
`scripts/openbao-config.sh init` before `tofu apply`. Rehydrate is one more step
in that job:

```
cluster stack boots node(s): raft storage, awskms seal from the lineage key
management workflow:
  1. init
       no snapshot in the lineage bucket  → initialise, write root token and
                                            recovery keys to the managed store
                                            (first deploy of a lineage)
       a snapshot exists                  → initialise with throwaway shares and
                                            write NOTHING to the managed store
  2. restore the newest snapshot object — and refuse to init at all if the
     listing FAILED rather than came back empty, since a plain init overwrites
     the lineage's stored root token and recovery keys
       POST sys/storage/raft/snapshot; same seal, so the sealed-hash check passes
       the restore itself uses the THROWAWAY root token from step 1 — the only
               credential that exists on this node. The lineage's recovery keys
               are the right input only AFTERWARDS, once the snapshot's token
               store has replaced the throwaway one
       assert: lineage/check_timestamp exists; log its age (the operator restore
               path's staleness guard protects a populated cluster from an old
               backup — a rehydrate restores into an empty one, so age is
               information here, not a failure)
       assert: pki_private_issuer mount present, and its CA chains to the
               lineage's CA file — which is the offline root
  3. seed (first deploy of a lineage only): secret-store.sh seed --store openbao
  4. tofu apply — a no-op on a rehydrated lineage
```

Three rules make this safe:

- **A rehydrating boot never overwrites the lineage's recovery keys or root
  token.** The throwaway ones from step 1 are replaced by the snapshot's in step 2.
- **Rehydrate is idempotent.** A second `deploy` against an already-restored
  cluster detects a populated store and skips.
- **The snapshot's Raft configuration is not applied.** The raft library's
  `Restore` keeps the current peer set, so a single fresh node restores a snapshot
  taken from a five-node cluster and vice versa.

`dev` mode changes from `file` to **single-node Raft on the encrypted gp3 root
volume**, on both clouds, because `file` can neither take nor receive a snapshot.
`ha` mode is unchanged.

### Authentication: JWT method, one mount per cluster

AppRole is replaced by OpenBao's JWT auth method, which validates a Kubernetes
ServiceAccount token against the cluster's public OIDC issuer using JWKS. OpenBao
never needs to reach a cluster's API server, which is what makes it work for a
remote cluster.

| Mount | `oidc_discovery_url` | Roles (bound to SA name and namespace, audience `openbao`) |
|---|---|---|
| `auth/jwt/aws-0` | the EKS cluster's issuer | `external-secrets`, `cert-manager`, `openbao-snapshot` |
| `auth/jwt/gcp-0` | `https://container.googleapis.com/v1/projects/<project>/locations/<zone>/clusters/gcp-0` | same three |

**Who configures the mount matters.** An EKS cluster's OIDC issuer URL carries a
per-cluster ID that changes on every rebuild, and the management stack runs
*before* `eks/init`. So each cluster's JWT mount and roles are created by that
cluster's own `configure` stack (`eks/configure`, `gke/configure`) through the
vault provider, authenticated with the lineage root token like the management
stack. Those stacks already exist to bind a fresh cluster to the platform and run
after the issuer is known. The management stack keeps ownership of the
**policies** the roles reference. A snapshot may therefore carry a mount whose
issuer belongs to a destroyed cluster; the next `configure` apply overwrites it,
and nothing can authenticate against a dead issuer in the meantime. GKE's issuer
is deterministic from project, zone and name, but the same placement is used for
symmetry.

Consumers:

- External Secrets: `auth.jwt.kubernetesServiceAccountToken.serviceAccountRef` <!-- pragma: allowlist secret -->
  (TokenRequest API, short-lived token — a field name, not a value).
- cert-manager `ClusterIssuer`: `auth.kubernetes` with `mountPath` pointing at the
  JWT mount and `serviceAccountRef.audiences: [openbao]`. cert-manager posts
  `{jwt, role}`, which is the JWT method's login payload. **Verify on a live
  cluster** (risk list).
- Snapshot CronJob: `bao write auth/jwt/<cluster>/login role=openbao-snapshot
  jwt=@<projected token>` replaces the AppRole login in `openbao-snapshot.sh`.

What disappears: the `approle` auth backend and its three roles, the two AppRole
credential entries in each managed store, the `cert_manager_approle_id` Flux
variable and the Secret `eks/configure` writes for it, and both
`openbao-approle-externalsecret.yaml` overlays. Policies are unchanged.

### PKI

One **offline root**, the one already created for GCP by the 2026-08-24 design.
Every OpenBao lineage holds one intermediate signed by it. The active lineage's
`pki_private_issuer` role `ogenki` allows both `priv.aws.ogenki.io` and
`priv.gcp.ogenki.io` (plus `svc.cluster.local`), so one mount issues for both
clusters and the snapshot carries the issuer key — failover needs no re-trust.

AWS migration: `opentofu/aws/openbao/management/pki.tf` changes from "import the
root bundle and self-sign an intermediate inside the mount" to "import a
pre-signed intermediate", the shape GCP already uses. The
`certificates/priv.aws.ogenki.io/root-ca` secret, which contains the root private
key, is deleted from Secrets Manager once the new intermediate issues. Tailnet
clients replace the AWS anchor with the offline root using the existing procedure
on the PKI & Secrets page.

The GCP-only lineage keeps its own intermediate signed by the same root, so
GCP-only mode is unchanged.

### Reachability and naming

Every consumer on every cluster addresses OpenBao by **one in-cluster name**,
`https://openbao.security.svc.cluster.local:8200`, and verifies it against the
offline root. Failover is then a change of what that name resolves to, per
cluster, not a manifest edit on two clusters.

| Cluster role | The `openbao` Service in `security` |
|---|---|
| Co-located with the active OpenBao | `ExternalName` → `bao.priv.aws.ogenki.io` (plain DNS, no proxy) |
| Remote | `ExternalName` annotated `tailscale.com/tailnet-ip: <NLB private IP>` and `tailscale.com/proxy-group: egress-proxies`; traffic crosses the tailnet to the remote cloud's subnet router |

The active OpenBao's internal NLB gets **fixed private IPs** through
`subnet_mapping.private_ipv4_address`, so the target survives a rebuild of the
cluster stack. The tailnet ACL admits `tag:k8s` to the VPC CIDR on 8200. Which
*form* a cluster uses is a committed overlay choice — Flux substitutes strings
and cannot select a manifest — and the *address* is a per-cluster Flux
variable, `openbao_target_ip`.

Both server certificates (active and standby, bootstrap tier) carry every SAN
they can be reached by: `bao.priv.aws.ogenki.io`, `bao.priv.gcp.ogenki.io`,
`openbao.security.svc.cluster.local`, `openbao.security.svc`.

CiliumNetworkPolicies for External Secrets, cert-manager and the snapshot job
allow egress to the resolved NLB address; on a remote cluster, to the egress
ProxyGroup pods. The `.claude/rules/cilium-network-policies.md` traps apply.

### Snapshots

| Property | Reference | Production |
|---|---|---|
| Cadence | daily (unchanged) plus a **pre-destroy snapshot** | hourly |
| Destinations | the lineage's S3 bucket; a Storage Transfer Service job in the GCP lineage pulls it into the GCS bucket on the same cadence | same |
| Retention | the existing bucket lifecycle rules | same |
| Alerts | `OpenBaoSnapshotStale`, `OpenBaoSnapshotJobFailed` (existing); mirror freshness is asserted by the weekly drill | same, plus a Cloud Monitoring alert on the transfer job (not built here) |

**The pre-destroy snapshot is taken by the cluster stack's `destroy` script from
the operator's context**, authenticated with the lineage root token. It cannot be
the CronJob: `destroy` runs in reverse order, so the EKS cluster and the job are
already gone when the OpenBao stack's turn comes. The management stack's gated
`destroy` runs before it and does nothing, which is what keeps the PKI mount and
policies inside that final snapshot.

**The mirror is a Storage Transfer Service job, not a second upload.** It is
configured once in the GCP lineage stack and authenticates to S3 with
*federated identity*: an AWS role `openbao-snapshot-mirror`, in
`opentofu/shared/aws-gcp-federation/`, trusts the project's Storage Transfer
service agent through the same `accounts.google.com` OIDC provider the standby
seal uses. The service agent's identity is deterministic per project, so the trust
never has to follow a rebuilt cluster — the reason a CronJob-side upload with a
Workload Identity Pool trusting the EKS issuer was rejected: that issuer changes
on every rebuild and would need re-federating after `eks/init` each time. The
role holds `s3:GetObject`, `s3:ListBucket` and `s3:GetBucketLocation` on the
snapshot bucket and `kms:Decrypt` on the bucket's key — read-only, and nothing
that can write, delete or encrypt.

Failback direction (GCS → S3) is a **manual step in the runbook**, not an
automatic mirror: a standby's snapshot holds the AWS lineage's data plus
whatever was written during the incident, and it must not silently become the
"newest" object mirrored back over the AWS history. The operator copies exactly
one object, deliberately, before redeploying AWS.

The snapshot is barrier-encrypted. Without the seal key it is ciphertext, which is
why the bucket policy can be ordinary and why the seal key is the asset to protect.

**What the freshness marker is, and the stronger guard that was rejected.** The
marker (`lineage/check_timestamp`, written by `save()` before every snapshot) is
an *alarm*, not a gate: it can only be read back after the restore has already
been applied, so it reports the age of what was installed and gives calling
automation a non-zero exit. A Task 1 review argued for replacing it with the
snapshot object's own timestamp, which is readable *before* the destructive
restore and therefore could actually prevent a stale one — a fair point, and the
object name already carries a sortable UTC stamp.

It is not adopted, for one reason the object name cannot cover: read back from
*inside* the restored OpenBao, the marker proves the restore actually applied
end to end. Object metadata only describes the file, and `LastModified` is
rewritten by the GCS mirror, so it does not survive the cross-cloud path at all.
Adding a pre-restore age check from the object *name* on top of the marker is a
genuine improvement and is left as follow-up; it is not on Stage 1's critical
path, and the marker's write is non-fatal precisely so it can never cost a
backup.

### Cross-cloud fallback

**Seal from GCP.** The GCP cluster stack gains `seal_provider = awskms | gcpckms`
(default `gcpckms`, for GCP-only mode). With `awskms`, the VM's startup script
installs a systemd timer that fetches a GCE instance identity token from the
metadata server every 50 minutes into `/run/openbao/aws-web-identity-token`; the
service unit sets `AWS_ROLE_ARN`, `AWS_WEB_IDENTITY_TOKEN_FILE` and `AWS_REGION`
(the replica region), and the seal stanza names the multi-region key. The awskms
seal resolves credentials through the SDK default chain, so nothing else is
configured on the OpenBao side.

**AWS side**, in `opentofu/shared/aws-gcp-federation/`: an IAM OIDC provider for
`https://accounts.google.com`, and a role `openbao-standby-seal` whose trust policy
binds `accounts.google.com:sub` to the standby VM service account's unique ID and
the audience to a fixed string. Its only permissions are the seal-key
operations OpenBao's `awskms` seal actually performs — `kms:Encrypt`,
`kms:Decrypt`, `kms:DescribeKey`, `kms:GenerateDataKey*` and `kms:ReEncrypt*`,
the same set `opentofu/aws/openbao/cluster/iam.tf` already grants the AWS node
for the same key, and nothing beyond it. The lineage's key policy
admits that role by its deterministic ARN, so the two stacks need no ordering.
This is distinct from the existing federation, which trusts the *GKE* issuer for
Kubernetes ServiceAccounts; a Compute Engine VM presents a Google-issued identity
token instead.

**Runbook, AWS → GCP.** Manual, by an operator:

1. Confirm the active OpenBao is unreachable and read the age of the newest
   object in the GCS mirror. That age is the data loss.
2. `TM_CLOUD=gcp` deploy: the GCP lineage (already applied), then the GCP OpenBao
   cluster stack with `seal_provider = awskms`, then the management stack, whose
   rehydrate step restores from `gs://` instead of `s3://`.
3. Verify: `bao status` unsealed with no operator input; `check_timestamp`
   matches the mirror's age; a certificate issues and chains to the offline root.
4. Flip `openbao_target` on every surviving cluster. External Secrets and
   cert-manager reconcile on their next interval.

**Failback** is the same sequence in reverse, seeded by a fresh snapshot the GCP
CronJob has mirrored to S3.

| Objective | Value | Why it is enough |
|---|---|---|
| RPO | the mirror cadence: 24 h reference, 1 h production | secrets change rarely; anything issued after the last snapshot is a certificate a client already holds |
| RTO | tens of minutes, manual | External Secrets keeps the last synced Secrets and cert-manager renews 15 days before expiry, so consumers ride out an OpenBao outage; only *new* secrets and certificates wait |

### The drill

A scheduled GitHub Actions workflow, weekly, assumes the CI role through OIDC and:

1. starts `bao server` in a container with Raft on a tmpfs and the `awskms` seal
   on the lineage key;
2. initialises with throwaway shares and restores the newest S3 object;
3. asserts the restore succeeded — the node reports unsealed and active, which
   proves the lineage seal unwrapped the snapshot — and that the PKI issuer's
   unauthenticated `ca_chain` endpoint answers with a chain ending at the
   committed offline root certificate. It does **not** read `check_timestamp`:
   that needs a token, and the only way CI could mint one is the recovery keys,
   which must not be within a runner's reach. The marker is asserted by the
   operator-run rehydrate instead;
4. asserts the newest object in the GCS mirror has the same name and size as the
   newest in S3;
5. fails the workflow otherwise.

The reference platform additionally exercises the same path on every deploy. The
cross-cloud path is executed once during Stage 1 by the runbook above, against a
GCP standby, and recorded in the verification document; it is repeated whenever
the seal, federation or restore script changes.

### Postures and cost

| Posture | Process runs | Store of record | Idle floor, clusters destroyed |
|---|---|---|---|
| Reference, today | while the platform runs | Secrets Manager, ~40 secrets | $23/month |
| Reference, this design | while the platform runs; rehydrated at boot | the lineage | ~$24/month: one KMS replica key |
| Production | always on, `mode = ha`, on-demand, EBS Raft path, peer-removal lifecycle hook, hourly snapshots | the lineage | ~$100/month; the standby is cold and costs nothing until used |

Production numbers are list-price estimates in the spirit of the costs page and
must be re-measured the same way before they are published there. The three
`ha`-mode changes needed for a deployment meant to stay up are already listed in
`opentofu/aws/openbao/cluster/README.md`; this design makes them a variable, not a
fork.

## Stages

### Stage 1 — foundation (Option 3)

Nothing repoints yet. The managed store remains the store of record. When Stage 1
is done, every risk the design carries has been retired on a live cluster.

1. **Lineage stacks** on both clouds: AWS seal key (multi-region) with alias and
   policy; snapshot buckets and the AWS bucket key imported from Crossplane; the
   GCP standby service account; destroy gate; the Crossplane MRs removed.
2. **Cluster stacks**: `dev` mode on single-node Raft over encrypted gp3; AWS seal
   key read from the lineage by alias; fixed NLB private IPs; GCP `seal_provider`
   with the identity-token timer, running as the lineage's service account.
3. **Management and configure workflows**: rehydrate step with the recovery-key
   guard and idempotence; destroy gate on the management stack; pre-destroy
   snapshot in the cluster stack's destroy, run from the operator's context.
4. **JWT auth**: policies in the management stack; per-cluster mounts and roles
   in `eks/configure` and `gke/configure`; External Secrets, cert-manager and the
   snapshot job switched; AppRole, its secrets, the Flux variable and the two
   overlays removed.
5. **PKI**: AWS intermediate signed by the offline root; role allows both
   domains; root secret deleted from Secrets Manager; re-trust documented.
6. **Snapshot mirror**: Storage Transfer Service job in the GCP lineage; the
   `accounts.google.com` OIDC provider and `openbao-snapshot-mirror` role in the
   federation stack.
7. **Neutral in-cluster name** and the egress `ProxyGroup` path, with
   `openbao_target`; SANs added to both server certificates.
8. **Fallback**: the `openbao-standby-seal` role on the provider from step 6; the
   runbook; **one executed AWS → GCP drill** recorded in the verification
   document.
9. **CI restore drill** workflow.
10. **Records**: ADR-0032 and the amendments listed below; the OpenBao, PKI &
    Secrets and costs pages; CLAUDE.md.

Exit criteria: destroy and redeploy the AWS platform, and OpenBao serves the same
PKI issuer and `app` namespace contents with no seeding step; `secret-store.sh
check` lists no AppRole entry; every certificate on both clusters chains to the
offline root; the CI drill is green; the GCP standby has unsealed against the AWS
key with no operator input; `validate-manifests.sh` reports `Invalid: 0,
Skipped: 0`.

### Stage 2 — repoint and migrate (the rest of Option 2)

Gate: Stage 1 exit criteria met and reviewed, including the executed drill.

1. `platform/` kv-v2 mount in the root namespace. Path grammar
   `platform/<component>/<name>`, mapping one-to-one onto the dash names
   ADR-0023 introduced (`harbor-admin-password` → `platform/harbor/admin-password`).
2. `scripts/secret-store.sh` gains `--store openbao` for `check`, `lint`, `seed`
   and a `migrate` that copies from the managed store into the mount, never
   overwriting and never deleting the source.
3. `ClusterSecretStore` on both clusters → the `vault` provider with JWT auth;
   every `ExternalSecret` `key` updated; the seeding step added to the deploy
   order after the management stack.
4. `eks/configure` reads the GitHub App key through the vault provider.
5. Records: ADR-0023 note (kv paths are portable by construction; the dash grammar
   survives only in the bootstrap tier), platform constitution §3.2 wording,
   costs page, ADR-0025 amendment finalised.
6. After a grace period, the migrated managed-store entries are removed by hand,
   with the command recorded in the PR.

Exit criteria: `secret-store.sh check --store aws` lists exactly the bootstrap
tier; a from-scratch deploy of each cloud reaches every Flux Kustomization
`Ready=True` with no manual seeding beyond the bootstrap tier; the drill asserts a
non-empty `platform/` mount.

## Records and documentation

- **New ADR-0032** — *OpenBao is the store of record, durable as a snapshot
  lineage, active on the primary cloud with restore-based fallback.* Rejected
  alternatives, each with the reason: managed stores as store of record (the
  status quo, ADR-0025); per-cloud OpenBaos each authoritative (secrets seeded
  twice, drift, no single policy model); one OpenBao with no fallback (a
  GCP-only platform cannot authenticate to anything); Shamir seal on the standby;
  AWS Private CA and GCP CAS (about $400/month per CA on AWS, and not portable);
  cert-manager's CA issuer (keys the intermediate in a Kubernetes Secret and
  removes what the repository demonstrates); SOPS (ADR-0025 option 3).
- **ADR-0025 amendment callout** in the style of ADR-0022: the constraint now
  bounds whether the *process* is on between runs, not where the store of record
  is; the "Neutral" claim becomes true rather than aspirational.
- **ADR-0027 table**: OpenBao moves from *per-cloud* to *primary-cloud
  singleton*, with a note that its relocation carries state.
- **ADR-0023 note** (Stage 2).
- Pages: OpenBao, PKI & Secrets, costs, the AWS and GCP foundations tables (new
  lineage stacks), private access (egress). `.doc-claims.yaml` gains claims for
  the seal alias, the neutral Service name and the snapshot cadence.
- `CLAUDE.md` "OpenBao" and "Namespace layout" sections, and the constitution's
  §3.2 "sourced from AWS Secrets Manager".

## Security considerations

- The seal key is the asset. Its policy admits the cluster stack's instance role,
  the CI drill role and `openbao-standby-seal`, nothing else. Snapshots without it
  are ciphertext.
- The root token remains valid for the lineage and is used only by the management
  stack from an operator or CI context. Retiring it in favour of OIDC for humans
  is a follow-up; until then the docs stop claiming it is retired.
- Recovery shares stay `1/1` for the reference and the docs keep saying to raise
  them for production; the restore script's threshold limitation is unchanged.
- JWT roles bind ServiceAccount name, namespace and audience. Because JWKS
  validation does not consult the API server, a revoked ServiceAccount token stays
  valid until it expires; token TTLs are kept short (10 minutes) for that reason.
- The GCE identity-token timer is a moving part. If it stops, a running unsealed
  node keeps serving; only a restart would fail to unseal, and `bao status` plus
  the existing `OpenBaoDown` alert surface it.
- Removing the AWS root secret from Secrets Manager is the point of the PKI
  change; the plan includes the deletion command and a check that the new
  intermediate issues first.

## Risks and items to verify on a live cluster

| # | Claim the design rests on | How it is verified | If false |
|---|---|---|---|
| 1 | Same-seal restore into a freshly initialised single-node Raft passes the sealed-hash check without `-force` | Stage 1 step 3, first rehydrate | use `sys/storage/raft/snapshot-force`; safe here because the seal is the same |
| 2 | cert-manager's `auth.kubernetes` works against a JWT mount | Stage 1 step 4 | fall back to the `kubernetes` auth method on the co-located cluster and JWT on remote ones |
| 3 | The awskms seal accepts `AWS_WEB_IDENTITY_TOKEN_FILE` credentials from a GCE identity token | Stage 1 step 8 drill | a small refresher writes static session credentials from `assume-role-with-web-identity` to the env file instead |
| 4 | The management stack's OpenTofu state is a no-op against a rehydrated lineage | Stage 1 exit criteria | targeted `import`/`state rm` for the resources whose IDs differ, documented |
| 5 | Fixed NLB private IPs survive a cluster-stack rebuild | Stage 1 step 2 | a MagicDNS name on a tailnet-joined node in front of the NLB |
| 6 | The Tailscale operator egress `ProxyGroup` at 1.90.6 handles TCP 8200 to an IP behind a subnet router with the ACL as written | Stage 1 step 7 | site-to-site subnet routers |
| 7 | `hashicorp/raft` `Restore` keeps the current peer set | first rehydrate | **Accepted for the single-node reference posture, not mitigated.** A one-node cluster restoring a snapshot keeps a peer set of exactly itself, so there is nothing stale to remove and no task implements one. In `mode = "ha"` a snapshot taken from a five-node cluster restored into a fresh five would need `bao operator raft remove-peer` for the old node IDs, and `vault_raft_autopilot`'s dead-server cleanup (`autopilot.tf`, `ha` only) is what handles it in steady state. Revisit with the production posture; do not assume the `ha` path is covered by Stage 1. |
| 8 | CI has, or can be given, an AWS OIDC role with `kms` and `s3:GetObject` on the lineage | Stage 1 step 9 | the drill runs from the operator's machine on a schedule instead |
| 9 | Storage Transfer Service reads a KMS-encrypted S3 bucket through federated identity with only the role's `kms:Decrypt` grant | Stage 1 step 6 | the `gcp-0` CronJob pushes with the ADR-0019 role in reverse, or the snapshot object uses the bucket's default SSE-S3 instead of the CMK |
| 10 | The `eks/configure` stack can reach OpenBao to write the JWT mount with the tooling it already has (it runs from the operator's machine, on the tailnet) | Stage 1 step 4 | write the mount from the management stack with a placeholder issuer and patch it from `eks/configure` with `bao write` in the workflow |

The implementation plan covers **Stage 1 only**. Stage 2 gets its own plan once
the Stage 1 exit criteria, including the executed cross-cloud drill, are met.

## Success criteria

Falsifiable, for `/verify-spec` after each stage merges.

1. `terramate script run destroy` followed by `deploy` on AWS brings back an
   OpenBao whose `pki_private_issuer/issuer/default` is byte-identical to the one
   before the destroy, with no seeding step run.
2. `aws kms describe-key --key-id alias/openbao-seal` reports `MultiRegion: true`
   and a replica exists; the alias ARN survives the destroy in (1).
3. `bao auth list` shows `jwt/aws-0/` and, on a two-cloud run, `jwt/gcp-0/`, and
   no `approle/`; `aws secretsmanager list-secrets` shows no `approles/` entry.
4. `openssl s_client` against both private Gateways presents chains ending at the
   offline root; `aws secretsmanager describe-secret --secret-id
   certificates/priv.aws.ogenki.io/root-ca` returns `ResourceNotFoundException`.
5. The newest object in the GCS mirror is at most one cadence older than the
   newest in S3.
6. A GCP standby deployed with `seal_provider = awskms` reports `Sealed: false`
   after a stop/start with no operator input, and `check_timestamp` after its
   restore matches the mirror's newest object.
7. The CI drill workflow has at least one green run against a snapshot taken by
   the CronJob, not by hand.
8. The costs page, re-measured, shows the idle floor within $2 of the previous
   measurement.
9. (Stage 2) `secret-store.sh check --store aws` lists exactly four keys per
   cloud; every `ExternalSecret` reads from the `vault` provider; a from-scratch
   deploy reaches all Kustomizations `Ready=True`.

## Out of scope, restated

Dynamic database credentials, transit, tenant namespaces, OIDC for humans, the
production posture running in this repository's own environment, surviving the
loss of the AWS account, and any change to the Crossplane compositions.
