# GCP bootstrap prerequisites

Three things must exist before `terramate script run deploy` can build GCP, and
none of them is managed by OpenTofu. Each is deliberate — they are all
chicken-and-egg or destructive-to-recreate — but three of them scattered across
three files is how a repository quietly stops being reproducible. They are
collected here.

Run these once per GCP project.

## 1. OpenTofu state bucket (ADR-0018)

These steps set up the GCS backend introduced by ADR-0018
(`website/content/docs/decisions/0018-per-cloud-opentofu-state.md`, PR
#1831); until that merges, the GCP stacks read the shared S3 bucket named in
each stack's `backend.tf` instead. Once it lands: state lives in GCS, in a
project that holds nothing else, so that deleting or suspending the workload
project cannot take the state describing it too.

```bash
gcloud projects create ogenki-tfstate --organization=<org-id>
gcloud billing projects link ogenki-tfstate --billing-account=<account-id>
gcloud services enable storage.googleapis.com --project=ogenki-tfstate
gcloud storage buckets create gs://ogenki-cloud-native-ref-tfstate \
  --project=ogenki-tfstate --location=europe-west4 \
  --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update gs://ogenki-cloud-native-ref-tfstate --versioning
```

Versioning is the recovery path for a truncated state file and is painful to add
after the fact.

## 2. Cloud KMS key ring for OpenBao auto-unseal

Read as a data source by `opentofu/gcp/openbao/cluster/kms.tf`, never managed,
because **GCP cannot delete either a key ring or a crypto key.** A `tofu destroy`
of a managed one returns success while destroying only key VERSIONS, and a
rebuild then fails with `ALREADY_EXISTS`.

```bash
gcloud services enable cloudkms.googleapis.com --project=ogenki-435905
gcloud kms keyrings create openbao-dev --location=europe-west4 --project=ogenki-435905
gcloud kms keys create openbao-unseal --location=europe-west4 \
  --keyring=openbao-dev --purpose=encryption --project=ogenki-435905
```

It survives teardown by design and costs nothing idle. Do not treat it as a leak.

## 3. Tailscale OAuth client for the Kubernetes operator

Separate from the AWS cluster's client, so compromising one cluster's operator
does not force rotating the other's.

Create an OAuth client in the Tailscale admin console (Settings → OAuth clients)
with scopes `devices:core` and `auth_keys` (write), tagged `tag:k8s-operator`,
then:

```bash
printf '{"client_id":"%s","client_secret":"%s"}' "$CLIENT_ID" "$CLIENT_SECRET" \
  | gcloud secrets create tailscale-k8s-operator-oauth \
      --project=ogenki-435905 --replication-policy=automatic --data-file=-
```

The JSON keys are consumed verbatim by `dataFrom.extract` into the chart's
required `operator-oauth` Secret — do not rename them.

**Revoke this client on teardown** if the project is being decommissioned; it is
the one prerequisite that is a live credential rather than an empty container.

## What is NOT a prerequisite

The offline root CA and the GCP intermediate. Those come from the signing
ceremony in the [OpenBao design](superpowers/specs/2026-08-24-gcp-openbao-design.md)
and already live in Secret Manager (`openbao-priv-gcp-ca-chain`,
`openbao-priv-gcp-intermediate-ca`). The root's private key must never be in GCP.
