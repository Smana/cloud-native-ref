---
title: OpenBao cross-cloud failover
weight: 60
description: Bring the GCP standby up from the mirrored snapshot under the AWS seal, repoint the surviving cluster, and fail back.
lastVerified: 2026-09-02
---

The active OpenBao runs on AWS and serves both clusters. Its durable form is
the *lineage* ([ADR-0032]({{< relref "/docs/decisions/0032-openbao-store-of-record-lineage.md" >}})):
the multi-region seal key `alias/openbao-seal`, four bootstrap secrets, and the
snapshot bucket `eu-west-3-ogenki-openbao-snapshot`, mirrored into
`ogenki-435905-ogenki-openbao-snapshot` by a Storage Transfer job at 05:00 UTC,
one hour after the snapshot CronJob's 04:00 UTC run.

## What this survives, and what it does not

| Failure | Covered |
|---|---|
| AWS `eu-west-3` regional outage; AWS compute or Secrets Manager unavailable | yes — the seal key has a replica in `eu-west-1` |
| The AWS account itself lost or closed | **no** — every snapshot is ciphertext under an AWS KMS key. A Shamir seal would cover this at the cost of a human at every restart; the trade is recorded in ADR-0032 |
| Snapshot older than you would like | RPO is the mirror cadence: 24 h as committed, 1 h in the production posture |

Consumers tolerate the gap: External Secrets keeps the last synced Secrets and
cert-manager renews 15 days before expiry. Only *new* secrets and certificates
wait, so this procedure is manual and measured in tens of minutes.

## Preconditions

- The GCP lineage stack has been applied and the federation stack knows its
  identities (`gcp_openbao_standby_sa_unique_id`, `gcp_transfer_agent_subject_id`
  in `opentofu/shared/aws-gcp-federation/variables.tfvars`).
- The four GCP bootstrap secrets exist: `openbao-priv-gcp-server-cert`,
  `openbao-priv-gcp-root-token`, `openbao-priv-gcp-recovery-keys`,
  `openbao-priv-gcp-intermediate-ca`. **For a fallback the root token and
  recovery keys must be the AWS lineage's**, because the restored token store is
  the AWS one: copy them from AWS Secrets Manager into those two GCP entries
  before step 2 (`scripts/secret-store.sh` has no cross-cloud copy; use the two
  CLIs).
- `gcloud auth application-default login` for `ogenki-435905`, a tailnet
  connection, and `TF_VAR_tailscale_api_key`.

## Failover, AWS → GCP

1. **Measure the loss.** The newest mirrored object is the data you will have:

   ```bash
   gcloud storage ls -l gs://ogenki-435905-ogenki-openbao-snapshot/ | sort -k2 | tail -1
   ```

2. **Deploy the standby with the AWS seal.** In
   `opentofu/gcp/openbao/cluster/variables.tfvars` set:

   ```hcl
   seal_provider       = "awskms"
   aws_seal_kms_key_id = "<opentofu/aws/openbao/lineage output seal_key_id>"
   aws_seal_region     = "eu-west-1"
   aws_seal_role_arn   = "<opentofu/shared/aws-gcp-federation output openbao_standby_seal_role_arn>"
   ```

   then, from `opentofu/`:

   ```bash
   TM_CLOUD=gcp terramate script run deploy
   ```

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

   Stop and start the instance (`gcloud compute instances stop/start`) and repeat
   `bao status`: it must come back unsealed on its own.

4. **Repoint the surviving cluster.** For `gcp-0` itself nothing changes: its
   `openbao` Service is the local form. For any other cluster still running,
   switch `security/<cluster>/openbao/kustomization.yaml` to
   `../../base/openbao-endpoint/remote` and set that cluster's `openbao_target_ip`
   to the GCP internal load balancer address (`google_compute_address.openbao`
   in `opentofu/gcp/openbao/cluster`). Commit; Flux reconciles; External Secrets
   and cert-manager pick up the new endpoint on their next interval.

## Failback, GCP → AWS

The mirror only runs one way. Copying GCS back over S3 is deliberate and
manual, one object at a time: a standby's snapshot holds the AWS lineage's data
*plus* whatever was written during the incident, and it must not silently become
the newest object in the AWS history.

1. Take a snapshot on the GCP node and copy exactly one object back:

   ```bash
   VAULT_TOKEN=<gcp root token> CLOUD=gcp ./scripts/openbao-snapshot.sh save \
     -a https://bao.priv.gcp.ogenki.io:8200 -b ogenki-435905-ogenki-openbao-snapshot -s /tmp/bao.snap
   gcloud storage cp gs://ogenki-435905-ogenki-openbao-snapshot/<newest>.snap /tmp/back.snap
   aws s3 cp /tmp/back.snap s3://eu-west-3-ogenki-openbao-snapshot/<newest>.snap
   ```

2. Redeploy AWS (`terramate script run deploy` from `opentofu/`); its rehydrate
   restores that object.
3. Restore `seal_provider = "gcpckms"` on the GCP cluster stack and redeploy it,
   or destroy it (`TM_CLOUD=gcp terramate script run --reverse destroy`, which
   snapshots first).
4. Revert the `openbao_target_ip` / overlay changes from step 4 above.

## Drill record

Every executed failover is recorded in
`docs/superpowers/specs/2026-09-02-openbao-store-of-record-verification.md`
(repository path) with the snapshot object, the measured RPO, and the time from
step 2 to step 3.
