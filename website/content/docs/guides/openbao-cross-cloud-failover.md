---
title: OpenBao cross-cloud failover
weight: 60
description: Bring the GCP standby up from the mirrored snapshot under the AWS seal, repoint the surviving cluster, and fail back.
lastVerified: 2026-09-02
---

The active OpenBao runs on AWS and serves both clusters. Its durable form is
the *lineage* ([ADR-0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}})):
the multi-region seal key `alias/openbao-seal`, five bootstrap secrets, and the
snapshot bucket `eu-west-3-ogenki-openbao-snapshot`, to be mirrored into
`ogenki-435905-ogenki-openbao-snapshot` by a Storage Transfer job at 05:00 UTC,
one hour after the snapshot CronJob's 04:00 UTC run.

{{< callout type="warning" >}}
**That mirror job does not exist yet, so nothing arrives in the GCS bucket on
its own.** `google_storage_transfer_job.s3_mirror` in
`opentofu/gcp/openbao/lineage/transfer.tf` carries
`count = var.aws_mirror_role_arn == "" ? 0 : 1`, and that stack's
`variables.tfvars` leaves `aws_mirror_role_arn` empty until **Task 16 Step 2**
of the Stage 1 plan
(`docs/superpowers/plans/2026-09-02-openbao-store-of-record-stage1.md`, a
repository path — plans are not published). Until that task has run, step 1
below finds the GCS bucket empty or stale, and the real RPO is "whenever
someone last copied an object across by hand", not 24 h. Copy the newest S3
object over before continuing:

```bash
key=$(aws s3api list-objects-v2 --bucket eu-west-3-ogenki-openbao-snapshot \
  --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
aws s3 cp "s3://eu-west-3-ogenki-openbao-snapshot/${key}" /tmp/mirror.snap
gcloud storage cp /tmp/mirror.snap "gs://ogenki-435905-ogenki-openbao-snapshot/${key}"
```

That hand copy is itself impossible once AWS is unreachable — which is why the
preconditions below are peacetime work.
{{< /callout >}}

## What this survives, and what it does not

| Failure | Covered |
|---|---|
| AWS `eu-west-3` regional outage; AWS compute or Secrets Manager unavailable | yes — the seal key has a replica in `eu-west-1` |
| The AWS account itself lost or closed | **no** — every snapshot is ciphertext under an AWS KMS key. A Shamir seal would cover this at the cost of a human at every restart; the trade is recorded in ADR-0032 |
| Snapshot older than you would like | RPO is the mirror cadence: 24 h once the transfer job exists, 1 h in the production posture |

Consumers tolerate the gap: External Secrets keeps the last synced Secrets and
cert-manager renews 15 days before expiry. Only *new* secrets and certificates
wait, so this procedure is manual and measured in tens of minutes.

## Preconditions

**Every item here is peacetime work.** Read this section now, not during an
incident. Three of these need a reachable `eu-west-3` and so cannot be done at
all once AWS is unavailable, which is precisely the failure this procedure
exists for: the **federation stack** in the first item (its state is in
`demo-smana-remote-backend`, `eu-west-3`), the **root-token and recovery-keys
copy** in the fourth, and the **hand mirror copy** in the callout above.

- The GCP lineage stack has been applied and the federation stack knows its
  identities (`gcp_openbao_standby_sa_unique_id`, `gcp_transfer_agent_subject_id`
  in `opentofu/shared/aws-gcp-federation/variables.tfvars`).

- **Five** GCP bootstrap secrets exist, not four. The CA chain is the fifth, and
  it is the *first* one read on every GCP deploy:

  | Secret | Read by |
  |---|---|
  | `openbao-priv-gcp-ca-chain` | `global.openbao_ca_fetch` in `opentofu/gcp/openbao/management/workflows.tm.hcl`, **before** rehydrate, on every deploy |
  | `openbao-priv-gcp-server-cert` | the node's boot script, for the TLS listener |
  | `openbao-priv-gcp-root-token` | the `vault` provider in `opentofu/gcp/openbao/management/providers.tf` and `opentofu/gcp/gke/configure/providers.tf` |
  | `openbao-priv-gcp-recovery-keys` | `generate_root_token` in `scripts/openbao-snapshot.sh`, after the restore |
  | `openbao-priv-gcp-intermediate-ca` | the PKI mount's issuer import |

  The `VAULT_CACERT` used throughout this guide is that CA-chain fetch's own
  output — written to `.tls/ca.pem` under
  `opentofu/gcp/openbao/management/` at deploy time, and gitignored, so it is
  not in a fresh clone.

- **`openbao-priv-gcp-server-cert` must already carry all four SANs.** `gcp-0`'s
  `ClusterIssuer` connects by `openbao.security.svc.cluster.local` in *both*
  postures — GCP-only and standby — see
  `security/gcp-0/openbao/openbao-clusterissuer.yaml`. The leaf issued by the
  2026-08-25 GCP ceremony carries only `bao.priv.gcp.ogenki.io`, so until
  **Task 14b** of the Stage 1 plan has re-issued it with
  `bao.priv.gcp.ogenki.io`, `bao.priv.aws.ogenki.io`,
  `openbao.security.svc.cluster.local` and `openbao.security.svc`, cert-manager
  on `gcp-0` fails with `x509: certificate is valid for
  bao.priv.gcp.ogenki.io, not openbao.security.svc.cluster.local` — and step 4's
  "nothing changes for `gcp-0`" does not hold. Check before you need it:

  ```bash
  gcloud secrets versions access latest --secret openbao-priv-gcp-server-cert \
    --project ogenki-435905 | jq -r .cert | openssl x509 -noout -ext subjectAltName
  ```

- **Pre-stage the AWS lineage's root token and recovery keys into the two GCP
  entries now, while AWS is healthy.** For a fallback they must be the *AWS*
  lineage's, because the restored store is the AWS one:

  ```bash
  aws secretsmanager get-secret-value --region eu-west-3 \
    --secret-id openbao/cloud-native-ref/tokens/root --query SecretString --output text \
    | gcloud secrets versions add openbao-priv-gcp-root-token --project ogenki-435905 --data-file=-
  aws secretsmanager get-secret-value --region eu-west-3 \
    --secret-id openbao/cloud-native-ref/tokens/recovery --query SecretString --output text \
    | gcloud secrets versions add openbao-priv-gcp-recovery-keys --project ogenki-435905 --data-file=-
  ```

  Re-run it whenever the AWS lineage's root token or recovery keys change.
  `scripts/secret-store.sh` has no cross-cloud copy; the two CLIs above are it.

  {{< callout type="warning" >}}
**This copy cannot be deferred to the incident.** The coverage table above lists
"AWS compute or Secrets Manager unavailable" as a **covered** failure mode — so
on the day you need this, the `aws secretsmanager get-secret-value` half may be
exactly what is down.

What it costs to skip: the GCP entries still hold the *GCP* lineage's
credentials, and both failures land **after** the destructive restore.
`rehydrate`'s pre-flight only proves the recovery-keys secret is *readable*
(`secret_read` in `scripts/openbao-config.sh`), never that it belongs to the
right lineage. So the run initialises with throwaway shares, restores the AWS
snapshot — replacing the token store *and* the recovery shares with the AWS
lineage's — and only then calls `generate_root_token`, which feeds the wrong
recovery key to `bao operator generate-root` and fails. What is left is the
state `rehydrate` warns about in so many words: a node holding throwaway keys
that were never stored, which nothing can authenticate to. Recovery is
`TM_OPENBAO_SKIP_SNAPSHOT=true TM_CLOUD=gcp terramate -C
opentofu/gcp/openbao/cluster script run destroy`, then start over — with the
copy done first. A stale root token fails one step later instead, in the
management stack's `tofu apply`.
  {{< /callout >}}

- `gcloud auth application-default login` for `ogenki-435905`, a tailnet
  connection, and `TF_VAR_tailscale_api_key`.

## Failover, AWS → GCP

1. **Measure the loss.** The newest mirrored object is the data you will have:

   ```bash
   gcloud storage ls -l gs://ogenki-435905-ogenki-openbao-snapshot/ | sort -k2 | tail -1
   ```

   Object names are `<UTC timestamp>-<seal>.snap` — for example
   `2026-09-02T041500Z-awskms.snap`. The trailing segment is **the seal that
   encrypted the object**, read from the writing node's own
   `/v1/sys/seal-status`, and it is the whole reason this failover works: only a
   node running that seal can unwrap it. In this bucket you should see
   `-awskms` on every mirrored object and `-gcpckms` on whatever `gcp-0` wrote
   for itself before the failover. An object with **no** seal segment is a
   legacy one written before the scheme; nothing will select it, and
   `container-images/openbao-snapshot/README.md` carries the one-command retag.

2. **Deploy the standby with the AWS seal.** In
   `opentofu/gcp/openbao/cluster/variables.tfvars` set:

   ```hcl
   seal_provider       = "awskms"
   aws_seal_kms_key_id = "<opentofu/aws/openbao/lineage output seal_key_id>"
   aws_seal_region     = "eu-west-1"
   aws_seal_role_arn   = "<opentofu/shared/aws-gcp-federation output openbao_standby_seal_role_arn>"
   ```

   then run the two GCP OpenBao stacks **by directory**, in this order:

   ```bash
   TM_CLOUD=gcp terramate -C opentofu/gcp/openbao/cluster    script run deploy
   TM_CLOUD=gcp terramate -C opentofu/gcp/openbao/management script run deploy
   ```

   {{< callout type="warning" >}}
**Not `TM_CLOUD=gcp terramate script run deploy` from `opentofu/`.** That
command cannot complete during the outage it would be run in.
`terramate list --run-order` puts `shared/aws-gcp-federation` third and
`shared/tailscale` fourth, ahead of `gcp/openbao/cluster`. Both keep their state
in `bucket = "demo-smana-remote-backend"`, `region = "eu-west-3"` (their
`backend.tf` files), and `scripts/tm-provisioner.sh` exempts the shared lane
from the cloud gate outright — `[ "$lane" = "shared" ] && return 0` — so they
run under any `TM_CLOUD`. `eu-west-3` is the region the coverage table above
calls *covered*: `tofu init` fails there and the run stops several stacks before
it ever reaches OpenBao.

The two commands above are the same two stacks the root deploy would eventually
have reached, minus every stack that needs AWS. `TM_CLOUD=gcp` is still
required: `tm-provisioner.sh` defaults to `aws` and would print `[skip]`
without it. Both stacks keep their state in GCS
(`ogenki-cloud-native-ref-tfstate`), so nothing on this path touches an AWS
region.
   {{< /callout >}}

   The management stack's rehydrate step restores from the GCS bucket. Its
   output is what tells you it worked, in this order: `Restoring snapshot
   <object>`, then `The restored snapshot was taken N day(s) ago.` — the
   `lineage/check_timestamp` marker, read back from *inside* the restored store,
   which is why it is an alarm rather than a gate: it can only be read after the
   restore has been applied. Then `PKI issuer present: subject=...` and
   `Rehydrate complete;`.

3. **Verify.**

   ```bash
   export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200 VAULT_CACERT=opentofu/gcp/openbao/management/.tls/ca.pem
   bao status                     # Initialized true, Sealed false, no operator input
   curl -s --cacert "$VAULT_CACERT" "$VAULT_ADDR/v1/pki_private_issuer/ca/pem" | openssl x509 -noout -subject
   ```

   **Expected: a subject whose CN is `Ogenki AWS Intermediate CA`** (OpenSSL 3
   prints `subject=CN = Ogenki AWS Intermediate CA, O = Ogenki, C = FR`; older
   builds print it without the spaces). That one command is the only thing
   separating "the AWS lineage restored here" from "the GCP node's own
   pre-existing PKI answered" — both leave a healthy `bao status`. If the CN is
   **GCP's own intermediate instead of the AWS one, the restore did not take**:
   the node is serving its own mount, and every secret and certificate you are
   about to depend on is the wrong one. Stop and re-read the rehydrate output
   rather than continuing to step 4.

   Then restart the instance and repeat `bao status`: it must come back unsealed
   on its own, with no operator input. The node is managed by
   `google_compute_instance_group_manager.openbao` with
   `base_instance_name = "openbao-dev"`, so its real name carries a
   MIG-generated random suffix and is not knowable in advance — look it up, and
   supply the zone:

   ```bash
   zone=europe-west4-a
   name=$(gcloud compute instances list --project ogenki-435905 \
     --filter="name~'^openbao-dev-' AND zone:${zone}" --format='value(name)')
   echo "$name"
   gcloud compute instances stop  "$name" --zone "$zone" --project ogenki-435905
   gcloud compute instances start "$name" --zone "$zone" --project ogenki-435905
   bao status
   ```

   The MIG will not race you while it is stopped: `compute.tf` sets **no**
   `auto_healing_policies`, deliberately — the comment there records the
   2026-08-25 incident that decided it. Auto-healing would `RECREATE` the
   instance and wipe the `auto_delete = true` data disk holding the Raft store.

4. **Repoint the surviving cluster.** For `gcp-0` itself nothing changes: its
   `openbao` Service is the local form —
   `security/gcp-0/openbao/kustomization.yaml` lists
   `../../base/openbao-endpoint/local` — and its `ClusterIssuer` already
   connects by the neutral in-cluster name, *provided* the server certificate
   from the preconditions above carries that SAN.

   For any other cluster still running, switch
   `security/<cluster>/openbao/kustomization.yaml` to
   `../../base/openbao-endpoint/remote` and set that cluster's
   `openbao_target_ip`. Read the address from the GCP cluster stack rather than
   guessing it — `google_compute_address.openbao` allocates it dynamically:

   ```bash
   (cd opentofu/gcp/openbao/cluster && tofu output -raw internal_ip)
   ```

   **`openbao_target_ip` is a per-cluster variable set in that cluster's own
   `configure` stack**, not a repo-wide value. Each cluster has its own source
   of truth, and both exist:

   | Cluster | Declared in | Emitted into |
   |---|---|---|
   | `aws-0` | `opentofu/aws/eks/configure/variables.tf` | `eks-aws-0-vars`, in `opentofu/aws/eks/configure/kubernetes.tf` |
   | `gcp-0` | `opentofu/gcp/gke/configure/variables.tf` | `gke-gcp-0-vars`, in `opentofu/gcp/gke/configure/kubernetes.tf` |

   So the step is executable in **both** directions — AWS-consuming-GCP
   included, which is the primary one for this design. Two things are worth
   knowing before editing anything mid-incident:

   - **The key existing is not the same as it being set.** Both variables
     default to `""` in the normal posture, and Flux substitutes an *undefined*
     variable to the empty string too — so a value left at that default and a
     missing key render identically: `tailscale.com/tailnet-ip: ""` in
     `security/base/openbao-endpoint/remote/service.yaml`, schema-valid,
     silently wrong, a Service annotated with nothing. Put the address in that
     stack's `variables.tfvars`, apply, then check the ConfigMap actually
     carries it (`kubectl -n flux-system get cm eks-aws-0-vars -o yaml`).
   - **The missing-key half is gated.**
     `scripts/flux-schema/check-substitution.py` fails the build when a
     Kustomization applies a `${var}` its own cluster's ConfigMap does not
     define, so `./scripts/validate-manifests.sh` catches that regression in CI
     rather than at 3am. It cannot catch an empty value; only the check above
     can.

   Commit; Flux reconciles; External Secrets and cert-manager pick up the new
   endpoint on their next interval.

## Failback, GCP → AWS

The mirror only runs one way. Copying GCS back over S3 is deliberate and
manual, one object at a time: a standby's snapshot holds the AWS lineage's data
*plus* whatever was written during the incident, and it must not silently become
the newest object in the AWS history.

1. **Take a final snapshot on the GCP node, then copy exactly one object back.**
   The failover's restore replaced the token store with the AWS lineage's, so
   the valid root token here is the **AWS** one — the value pre-staged into the
   GCP entry by the preconditions:

   ```bash
   export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200
   export VAULT_CACERT=opentofu/gcp/openbao/management/.tls/ca.pem
   VAULT_TOKEN=$(gcloud secrets versions access latest \
     --secret openbao-priv-gcp-root-token --project ogenki-435905 | jq -r .token)

   VAULT_TOKEN="$VAULT_TOKEN" VAULT_CACERT="$VAULT_CACERT" CLOUD=gcp \
     ./scripts/openbao-snapshot.sh save \
     -a "$VAULT_ADDR" -b ogenki-435905-ogenki-openbao-snapshot -s /tmp/bao.snap
   ```

   `VAULT_CACERT` is not optional — the script's own usage says "Set it; do not
   skip verify", and this chain is in no system trust store by default.

   The object just written is now the newest. Select it the way the tooling
   does — `latest_snapshot()` in `scripts/openbao-config.sh` sorts GCS objects
   **by name** — and copy that one object, by name, into S3:

   ```bash
   newest=$(gcloud storage ls gs://ogenki-435905-ogenki-openbao-snapshot/ \
     | sed 's#.*/##' | grep '\.snap$' | sort | tail -n1)
   echo "$newest"     # confirm this is the snapshot you just took
   gcloud storage cp "gs://ogenki-435905-ogenki-openbao-snapshot/${newest}" /tmp/back.snap
   aws s3 cp /tmp/back.snap "s3://eu-west-3-ogenki-openbao-snapshot/${newest}"
   ```

2. Redeploy AWS (`terramate script run deploy` from `opentofu/`); its rehydrate
   restores that object. The root deploy is the right command *here*, unlike
   step 2 of the failover, because failback only begins once `eu-west-3` is
   reachable again — so the shared stacks' S3 backend resolves.

3. **Retire the standby — do not flip its seal.** The GCP node is holding
   AWS-sealed data, and restoring `seal_provider = "gcpckms"` on that stack is
   the single change that dead-ends it. Flipping the variable edits the instance
   template; the MIG's `PROACTIVE` / `REPLACE` update policy
   (`opentofu/gcp/openbao/cluster/compute.tf`) replaces the running instance;
   the replacement boots with an empty Raft store; `rehydrate` goes looking for
   the newest object in `gs://ogenki-435905-ogenki-openbao-snapshot/` — and
   **every object in that bucket is AWS-sealed by now**: the mirrored ones by
   construction, and the standby's own because it ran under
   `seal_provider = "awskms"`. A `gcpckms` node cannot unwrap any of them.

   **How that surfaces, and it is no longer a stranding.** `rehydrate` reads
   this node's seal from `/v1/sys/seal-status`, compares it with the newest
   object's name segment, and **refuses before `bao operator init`** — the
   irreversible step — naming both seals. The deploy stops with a legible error
   and an untouched store, rather than the node coming back sealed with nothing
   to diagnose it by. It is still the wrong move: you are left with a replaced
   instance, an empty Raft store, and step 4's decision to make anyway.

   Destroy the standby instead, by directory, and skip its pre-destroy
   snapshot:

   ```bash
   TM_OPENBAO_SKIP_SNAPSHOT=true TM_CLOUD=gcp \
     terramate -C opentofu/gcp/openbao/cluster script run destroy
   ```

   **`TM_OPENBAO_SKIP_SNAPSHOT=true` is the point of this step, not a
   shortcut.** The default pre-destroy snapshot would write one more
   **AWS-sealed** object, as the newest in the GCP bucket — so the next
   GCP-only deploy would rehydrate straight back into the dead end above.
   Nothing is lost by skipping it: step 1 already carried this node's data into
   the AWS lineage, which is where it now belongs.

   By directory, too, and for a second reason: `TM_CLOUD=gcp terramate script
   run --reverse destroy` from `opentofu/` sweeps the **whole GCP lane** —
   `gcp/gke/configure`, `gcp/gke/init` and `gcp/network` are all in
   `terramate list --run-order` — tearing down the cluster you just failed over
   to and are still running on.

4. **Before `gcp-0` runs GCP-only again, decide which writes to discard.**
   Every object in the GCP snapshot bucket is AWS-sealed by now — the mirrored
   ones by construction, the standby's own because it ran under
   `seal_provider = "awskms"`. What has changed is that the bucket is no longer
   ambiguous: objects are named `<UTC timestamp>-<seal>.snap`, so a fresh
   `gcpckms` node reads its own seal, sees the mismatch and **refuses before
   `bao operator init`**:

   ```text
   ERROR: SEAL MISMATCH -- refusing to initialise or restore. Nothing has changed yet.
   ERROR:   this node's seal : gcpckms
   ERROR:   newest object    : 2026-09-02T041500Z-awskms.snap
   ERROR:                      sealed 'awskms'
   ```

   **Nothing needs moving aside and nothing needs re-stamping.** That refusal
   mutates neither the bucket nor the node, so this step is no longer bucket
   surgery performed mid-incident. What is left is the one judgement the tooling
   will not make for you.

   Read the bucket. The seal segment is in the name, so the listing is the whole
   answer:

   ```bash
   gcloud storage ls gs://ogenki-435905-ogenki-openbao-snapshot/ | sed 's#.*/##' | sort
   ```

   The newest object a `gcpckms` node can unwrap is the last `-gcpckms.snap`,
   from before the failover, and restoring it discards every write after it.
   **Those discarded writes belong to the AWS lineage, not this one** — the
   standby was serving the restored AWS store — and step 1 above already carried
   them into `eu-west-3-ogenki-openbao-snapshot`, which is where they belong.
   That is what makes the skip correct here rather than a loss: `gcp-0` is going
   back to being authoritative for itself, and its own last GCP-sealed snapshot
   is exactly the store it should hold. Confirm that object is the one you
   expect, then accept the skip on the stack that runs `rehydrate`:

   ```bash
   OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true TM_CLOUD=gcp \
     terramate -C opentofu/gcp/openbao/management script run deploy
   ```

   It logs which object it skipped past and which it restored. Set it for that
   one invocation only — it is not a default precisely because skipping a newer
   snapshot discards data.

   If the listing shows **no** `-gcpckms.snap` object at all — a young GCP
   lineage, or one whose snapshots passed the bucket's 120-day expiry
   (`lifecycle_rule` in `opentofu/gcp/openbao/lineage/main.tf`) — the flag
   cannot help, and `rehydrate` refuses rather than falling through to a plain
   init, which would overwrite this lineage's stored root token and recovery
   keys. That case is a deliberate fresh GCP lineage, not a restore.

5. Revert the `openbao_target_ip` / overlay changes from step 4 of the failover.

## Drill record

Every executed failover is recorded with the snapshot object, the measured RPO,
and the time from step 2 to step 3 — in
`2026-09-02-openbao-store-of-record-verification.md` under
`docs/superpowers/specs/` (a repository path — verification notes are not
published). **No failover has been executed yet, so that note does not exist:**
it is written by the first one, and `/verify-spec` creates it post-merge.
