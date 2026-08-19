# 💾 Backup and Restore

Implementing a robust backup and restore procedure is crucial when deploying Vault in a production environment. [Hashicorp's documentation](https://developer.hashicorp.com/vault/tutorials/standard-procedures/sop-restore) provides a comprehensive guide for these processes.

As we're using the Raft Integrated Storage, basically here is the process:

1. **Backup:**
   - Create a snapshot with this command:

     ```bash
     bao operator raft snapshot save <snapshot_file>
     ```

   - Then, securely transfer the snapshot to an Amazon S3 bucket for safe storage.

2. **Restore:**
   - Retrieve the required snapshot from the S3 bucket.
   - Restore Vault to the state captured in the snapshot:

     ```bash
     bao operator raft snapshot restore -force <snapshot_file>
     ```

We aim to automate this process for regular backups and efficient restoration, ensuring data integrity.

Here's my approach to setting up regular backups:

## ✅ Requirements

Before implementing this strategy, ensure:

- Your OpenBao instance is operational. Refer to [this documentation](../../cluster/).
- Familiarize yourself with OpenBao's [AppRole](https://www.vaultproject.io/docs/auth/approle) concept.
- Configure the AppRole for the automated snapshot cronjob.

## 🕥 Scheduled Backups

A cronjob is used in the EKS cluster to periodically store backups in an S3 bucket. The required AWS resources are managed using Crossplane:

- An S3 bucket for storage.
- A lifecycle rule with a retention policy.
- A KMS key for data encryption.
- IAM permissions for the pod to access the backup files.

ℹ️ **Kubernetes resources** for this workflow are detailed [here](../../../../security/base/openbao-snapshot/).

We use an AppRole named `snapshot-agent` with the necessary permissions for snapshot operations.

### Backup Process

1. **Nothing to do by hand.** The `snapshot-agent` AppRole, its secret ID, and the
   `security/openbao/openbao-snapshot` Secrets Manager entry are all created by the
   management stack (`secrets.tf`). External Secrets syncs that entry into the `security`
   namespace, where the CronJob reads it via `envFrom`.

   This used to be a manual `bao write .../secret-id` followed by a hand-built
   `aws secretsmanager create-secret`. A credential created outside the stack that manages
   every other credential drifts by construction — and this is the one the
   disaster-recovery job depends on. The payload shape is unchanged:

   ```json
   {
     "APPROLE_ROLE_ID": "...",
     "APPROLE_SECRET_ID": "...",
     "VAULT_ADDR": "https://bao.priv.cloud.ogenki.io:8200",
     "BUCKET_NAME": "eu-west-3-ogenki-openbao-snapshot",
     "RECOVERY_KEYS_SECRET_ID": "openbao/cloud-native-ref/tokens/recovery"
   }
   ```

   `RECOVERY_KEYS_SECRET_ID` names the secret holding the recovery keys; it is consumed
   only by the `restore` path. The CronJob's EKS Pod Identity role deliberately has **no**
   `secretsmanager` permission — a daily backup pod able to read the material that
   regenerates a root token is a privilege escalation, not a convenience. Run restores as
   an operator, with operator credentials.

2. When all the Kubernetes resources will be created using Flux, trigger the cronjob to perform a backup:

```console
kubectl create job --namespace security --from=cronjob/openbao-snapshot manual-openbao-snapshot-$(date +%s)
```

Verify the backup in the S3 bucket

```console
kubectl logs -n security manual-openbao-snapshot-$(date +%s)-<id>
```


## 🕵️ Restore

The implementation is [`scripts/openbao-snapshot.sh`](../../../../scripts/openbao-snapshot.sh)
(`restore` subcommand). It fetches the newest snapshot from S3, mints a temporary root
token from the recovery key, restores, and checks that `secret/check_timestamp` is recent
enough that you have not just restored a stale backup over a good cluster.

### Run it as an operator, not as the CronJob

`restore` needs `RECOVERY_KEYS_SECRET_ID` set, and needs AWS credentials that can read that
secret. The snapshot job's EKS Pod Identity role cannot — deliberately. Export the same
variables the job gets, plus your own AWS credentials:

```console
export APPROLE_ROLE_ID=... APPROLE_SECRET_ID=...
export RECOVERY_KEYS_SECRET_ID="openbao/cloud-native-ref/tokens/recovery"
./scripts/openbao-snapshot.sh restore -a "https://bao.priv.cloud.ogenki.io:8200" \
  -b eu-west-3-ogenki-openbao-snapshot -s /tmp/bao.snap -d 8
```

### Prerequisites this path used to be missing

- **The recovery keys must exist.** `openbao-config.sh init` now stores them in their own
  Secrets Manager entry, separate from the root token. Before that it kept only the root
  token and discarded the recovery keys, which made `bao operator generate-root`
  impossible: this restore path could never have authenticated, and a lost root token
  would have left the cluster unrecoverable.
- **The script only automates a recovery threshold of 1.** With a higher threshold it
  exits and tells you to run `bao operator generate-root` by hand with the required number
  of shares.
- **Raft storage is required.** `bao operator raft snapshot save|restore` and
  `sys/storage/raft/configuration` are Raft-only endpoints. In `dev` mode the cluster runs
  the `file` backend and neither the backup nor the restore can work — see
  `cluster/README.md`.

### Verify it, don't assume it

⚠️ **Still not automated.** There is no CI workflow that restores the latest snapshot into
a throwaway cluster and asserts the contents. Until there is, the restore procedure is a
hypothesis. The `OpenBaoSnapshotStale` and `OpenBaoSnapshotJobFailed` alerts
(`observability/base/victoria-metrics-k8s-stack/vmrules/openbao.yaml`) at least tell you
when the *backup* half stops working.
