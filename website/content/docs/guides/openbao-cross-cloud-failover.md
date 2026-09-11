---
title: OpenBao cross-cloud failover
weight: 60
description: Bring the GCP standby up from the mirrored snapshot under the AWS seal, repoint the surviving cluster, and fail back.
lastVerified: 2026-09-02
---

The active OpenBao runs on AWS and serves both clusters. Its durable form is
the *lineage* ([ADR-0033]({{< relref "/docs/decisions/0033-openbao-store-of-record-lineage.md" >}})):
the multi-region seal key `alias/openbao-seal`, five bootstrap secrets, and the
snapshot bucket `eu-west-3-ogenki-openbao-snapshot`, to be mirrored into
`ogenki-435905-ogenki-openbao-snapshot` by a Storage Transfer job at 05:00 UTC,
one hour after the snapshot CronJob's 04:00 UTC run.

{{< callout type="info" >}}
**Check that the mirror is actually running before you rely on it.**
`google_storage_transfer_job.s3_mirror` in
`opentofu/gcp/openbao/lineage/transfer.tf` carries
`count = var.aws_mirror_role_arn == "" ? 0 : 1`, so an empty
`aws_mirror_role_arn` in that stack's `variables.tfvars` silently means *no
mirror job at all* — the GCS bucket then sits empty or stale and the real RPO is
"whenever someone last copied an object across by hand", not 24 h. The value is
set, and the mirror was last verified on 2026-09-05 with the same object on both
sides at 74785 bytes. Confirm it for yourself in one command:

```bash
diff <(aws s3 ls s3://eu-west-3-ogenki-openbao-snapshot/ | awk '{print $3, $4}') \
     <(gcloud storage ls -l gs://ogenki-435905-ogenki-openbao-snapshot/ \
         | awk '/\.snap$/ {n=split($3,p,"/"); print $1, p[n]}')
```

If the mirror has not run, copy the newest object across by hand before
continuing — and note that this hand copy is itself impossible once AWS is
unreachable, which is why the preconditions below are peacetime work:

```bash
key=$(aws s3api list-objects-v2 --bucket eu-west-3-ogenki-openbao-snapshot \
  --query 'sort_by(Contents, &LastModified)[-1].Key' --output text)
aws s3 cp "s3://eu-west-3-ogenki-openbao-snapshot/${key}" /tmp/mirror.snap
gcloud storage cp /tmp/mirror.snap "gs://ogenki-435905-ogenki-openbao-snapshot/${key}"
```
{{< /callout >}}

![The cross-cloud fallback and the weekly drill. A snapshot restores only under the seal that encrypted it, so the GCP standby uses the AWS key over federation and holds no AWS credential. On the AWS side: the multi-region seal key with its eu-west-1 replica, the S3 snapshot bucket whose every object is AWS-sealed by construction, and the openbao-standby-seal IAM role trusting accounts.google.com scoped by key alias and condition. On the GCP side: the GCS mirror bucket holding the same objects with the same names and sizes, populated daily by Storage Transfer, and a GCE node running seal_provider awskms whose systemd timer writes a GCE identity token to disk, with AWS_ROLE_ARN and AWS_WEB_IDENTITY_TOKEN_FILE as its only two variables and no static credential. An arrow between them shows sts:AssumeRoleWithWebIdentity leading to decryption with the AWS key. Below, the weekly restore drill runs two independent GitHub Actions jobs on Mondays at 06:00 UTC: restore the newest snapshot into a throwaway node holding nothing but the seal key, verify the chain with openssl against the committed offline root certificate, assert the mirror has a same-size twin in GCS, and separately unseal using only the two web-identity variables having first asserted no static credential is present](/images/diagrams/openbao-lineage-2.svg)

## What this survives, and what it does not

| Failure | Covered |
|---|---|
| AWS `eu-west-3` regional outage; AWS compute or Secrets Manager unavailable | yes — the seal key has a replica in `eu-west-1` |
| The AWS account itself lost or closed | **no** — every snapshot is ciphertext under an AWS KMS key. A Shamir seal would cover this at the cost of a human at every restart; the trade is recorded in ADR-0033 |
| Snapshot older than you would like | RPO is the mirror cadence: 24 h once the transfer job exists, 1 h in the production posture |

Consumers tolerate the gap: External Secrets keeps the last synced Secrets and
cert-manager renews 15 days before expiry. Only *new* secrets and certificates
wait, so this procedure is manual and measured in tens of minutes.

## Preconditions

**All of this is peacetime work — read it now, not during an incident.** Three
items need a reachable `eu-west-3`, so they cannot be done once AWS is down,
which is exactly the failure this procedure is for.

| # | Must be true | Check |
|---|---|---|
| 1 | GCP lineage + federation applied, and the federation knows GCP's identities | `gcp_openbao_standby_sa_unique_id` and `gcp_transfer_agent_subject_id` set in `opentofu/shared/aws-gcp-federation/variables.tfvars` |
| 2 | **Five** GCP bootstrap secrets exist, not four | the CA chain is the fifth, and the first one read on every deploy |
| 3 | The server certificate carries **all four** SANs | command below |
| 4 | The AWS root token and recovery keys are staged into GCP | commands below |
| 5 | `gcloud auth application-default login`, a tailnet connection, `TF_VAR_tailscale_api_key` | |

**Item 3** — `gcp-0`'s ClusterIssuer connects by
`openbao.security.svc.cluster.local` in both postures, so a certificate carrying
only `bao.priv.gcp.ogenki.io` fails with `x509: certificate is valid for
bao.priv.gcp.ogenki.io, not openbao.security.svc.cluster.local`:

```bash
gcloud secrets versions access latest --secret openbao-priv-gcp-server-cert \
  --project ogenki-435905 | jq -r .cert | openssl x509 -noout -ext subjectAltName
```

**Item 4** — the restored store is the *AWS* one, so the GCP entries must hold
the *AWS* lineage's credentials. There is no cross-cloud copy tool; these two
commands are it, and they must be re-run whenever the AWS lineage's root token
or recovery keys change:

```bash
aws secretsmanager get-secret-value --region eu-west-3 \
  --secret-id openbao/cloud-native-ref/tokens/root --query SecretString --output text \
  | gcloud secrets versions add openbao-priv-gcp-root-token --project ogenki-435905 --data-file=-
aws secretsmanager get-secret-value --region eu-west-3 \
  --secret-id openbao/cloud-native-ref/tokens/recovery --query SecretString --output text \
  | gcloud secrets versions add openbao-priv-gcp-recovery-keys --project ogenki-435905 --data-file=-
```

{{< callout type="warning" >}}
**Item 4 cannot be deferred to the incident** — it reads AWS Secrets Manager,
which may be exactly what is down.

Skipping it fails *after* the destructive restore, not before: `rehydrate`
checks only that the recovery-keys secret is **readable**, never that it belongs
to the right lineage. So the node initialises, restores the AWS snapshot, and
only then fails to mint a root token — leaving a node holding throwaway keys
that were never stored, which nothing can authenticate to. Recovery is to
destroy and start over, with the copy done first:
`TM_OPENBAO_SKIP_SNAPSHOT=true TM_CLOUD=gcp terramate -C opentofu/gcp/openbao/cluster script run destroy`
{{< /callout >}}

{{< callout type="info" >}}
**Adapting this for your own project?** Two requirements are not obvious, and
both fail in ways that name neither cause. AWS matches a Google token on the
**authorized party** (`azp`), so `client_id_list` needs the standby service
account's *unique ID* — not just the audience — or STS answers
`InvalidIdentityToken` with every trust-policy condition matching. And the
standby's own service account needs read on the mirror bucket: it is easy to
grant only to the CI drill's identity, which keeps the bucket looking reachable
while the identity that matters during an outage has never touched it.
{{< /callout >}}

## Failover, AWS → GCP

1. **Measure the loss.** The newest mirrored object is the data you will have:

   ```bash
   gcloud storage ls -l gs://ogenki-435905-ogenki-openbao-snapshot/ | sort -k2 | tail -1
   ```

   Names are `<UTC timestamp>-<seal>.snap`. The trailing segment is the seal
   that encrypted the object, and only a node running that seal can unwrap it —
   which is why the standby uses the AWS key. Expect `-awskms` on every mirrored
   object. One with no seal segment predates the scheme and will not be
   selected; `container-images/openbao-snapshot/README.md` has the retag.

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
**By directory, not `terramate script run deploy` from `opentofu/`.** The root
deploy reaches the `shared/*` stacks first, and their state lives in
`eu-west-3` — the region the outage is in. `tofu init` fails there and the run
stops before it ever reaches OpenBao. `TM_CLOUD=gcp` is still required, or the
provisioner defaults to `aws` and prints `[skip]`.
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

The switch has four limits:

- It is honoured only when no top-level object carries the node's own seal, and
  every top-level snapshot's name carries a `-<seal>` segment. A snapshot whose
  name has no seal segment (a legacy `<timestamp>.snap` or a hand-named one) is
  refused, because its seal is unknown.
- Snapshots moved aside under a prefix are **not examined**. Never move one
  under a prefix in this bucket to get past the refusal, because that only
  hides it from the check. Retag it to `<timestamp>-<seal>.snap`, or move it to
  another bucket.
- It is never honoured together with `OPENBAO_SNAPSHOT_KEY`.
- It **replaces** the stored root token and recovery keys.

Every later boot restores the newest `-gcpckms` object. When a mirrored AWS
object is newer, set `OPENBAO_SNAPSHOT_SKIP_FOREIGN_SEAL=true`, as the refusal
message says.

## Drill record

Every executed failover is recorded with the snapshot object, the measured RPO,
and the time from step 2 to step 3 — in
`2026-09-02-openbao-store-of-record-verification.md` under
`docs/superpowers/specs/` (a repository path — verification notes are not
published). **No failover has been executed yet, so that note does not exist:**
it is written by the first one, and `/verify-spec` creates it post-merge.
