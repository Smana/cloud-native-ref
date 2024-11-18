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

* Your OpenBao instance is operational. Refer to [this documentation](../../cluster/).
* Familiarize yourself with OpenBao's [AppRole](https://www.vaultproject.io/docs/auth/approle) concept.
* Configure the AppRole for the automated snapshot cronjob.

## 🕥 Scheduled Backups

A cronjob is used in the EKS cluster to periodically store backups in an S3 bucket. The required AWS resources are managed using Crossplane:

* An S3 bucket for storage.
* A lifecycle rule with a retention policy.
* A KMS key for data encryption.
* IAM permissions for the pod to access the backup files.

ℹ️ **Kubernetes resources** for this workflow are detailed [here](../../../../security/base/openbao-snapshot/).

We use an AppRole named `snapshot-agent` with the necessary permissions for snapshot operations.

### Backup Process

1. Set the secrets for the Kubernetes pod:

```console
VAULT_ADDR="https://bao.priv.cloud.ogenki.io:8200"
BUCKET_NAME="eu-west-3-ogenki-openbao-snapshot"
APPROLE_ROLE_ID=$(bao read --field=role_id auth/approle/role/snapshot-agent/role-id)
APPROLE_SECRET_ID=$(bao write --field=secret_id -f auth/approle/role/snapshot-agent/secret-id)
```

2. Store these secrets in AWS Secrets Manager and sync them to a Kubernetes secret using the External Secret Operator:

```console
jq -nr --arg roleId "${APPROLE_ROLE_ID}" \
--arg secretId "${APPROLE_SECRET_ID}" \
--arg vaultAddr "${VAULT_ADDR}" \
--arg bucketName "${BUCKET_NAME}" \
'{"APPROLE_ROLE_ID":$roleId,"APPROLE_SECRET_ID":$secretId,"VAULT_ADDR":$vaultAddr,"BUCKET_NAME":$bucketName}' > /tmp/secret.json
```

Verify the JSON file's contents

```console
cat /tmp/secret.json
```

Create the AWS Secrets Manager secret

```console
aws secretsmanager create-secret --name 'security/openbao/openbao-snapshot' --description 'Used to backup and restore an OpenBao instance' --secret-string file:///tmp/secret.json
```


3. When all the Kubernetes resources will be created using Flux, trigger the cronjob to perform a backup:

```console
kubectl create job --namespace security --from=cronjob/openbao-snapshot manual-openbao-snapshot-$(date +%s)
```

Verify the backup in the S3 bucket

```console
kubectl logs -n security manual-openbao-snapshot-$(date +%s)-<id>
```

## 🕵️ Restore and Check

⚠️ **Not Implemented Yet:**
I plan to develop a CI workflow to automatically restore from the previously saved backup and verify the data within the Vault instance.

Below is the draft script for this process:

* The script uses the same KMS key to unseal the new instance and generates a temporary root token.

```bash
#!/bin/bash
set -e
# This script restores a snapshot from S3

function generate_root_token()
{
    read VAULT_NONCE VAULT_OTP < <(bao operator generate-root -init --format json | jq -cr '.nonce, .otp' | tr '\n' ' ')
    VAULT_ENCODED_TOKEN=$(echo $(aws secretsmanager get-secret-value --secret-id <secret_id> | jq -r '.SecretString' | jq -r '.recovery_key') | bao operator generate-root -nonce=${VAULT_NONCE} --format json - | jq -cr '.encoded_root_token')
    local VAULT_TOKEN=$(bao operator generate-root -decode ${VAULT_ENCODED_TOKEN} -otp ${VAULT_OTP})
    echo ${VAULT_TOKEN}
}

export VAULT_TOKEN=$(generate_root_token)

echo "Fetching latest backup from s3 bucket ${BUCKET_NAME}"
SNAP=$(aws s3 ls ${BUCKET_NAME} | sort | tail -n 1 | awk '{print $4}')
aws s3 cp s3://${BUCKET_NAME}/${SNAP} /tmp/openbao.snap

echo "Restoring snapshot ${SNAP}"
bao operator raft snapshot restore -force /tmp/openbao.snap

export VAULT_TOKEN=$(generate_root_token)

trap "bao token revoke ${VAULT_TOKEN}" EXIT

echo "Check that the timestamp from the path secret/check_timestamp is less than 8 days"
CURR_TS=$(date "+%s")
VAULT_TS=$(bao kv get --field=value secret/check_timestamp)

if [[ $(echo $((${CURR_TS}-${VAULT_TS}))) -gt 691200 ]]; then
    echo "ERROR: The restored snapshot is more than 8 days"
    exit 1
fi

bao kv put secret/check_timestamp value=$(date "+%s") &>/dev/null
```
