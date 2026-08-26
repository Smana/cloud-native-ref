---
title: Prerequisites
weight: 10
description: Accounts, access, and tools needed before the first deploy.
lastVerified: 2026-08-20
---

Everything below is cloud-agnostic — the same list applies whichever cloud
lane you deploy next.

## Accounts and access

- **AWS account** with admin-level permissions (VPC, EKS, IAM, S3, Route53,
  Secrets Manager, KMS) and credentials configured locally (`~/.aws/credentials`
  or environment variables).
- **A registered domain** you can delegate to Route53 — OpenTofu creates a
  private hosted zone under it for internal service DNS.
- **GitHub account** — Flux needs a way to pull this repository: a personal
  access token or a GitHub App.
- **Tailscale account and API key** — provisions the subnet router that gives
  you private access to the cluster.
- **A GitHub App, and its credentials in AWS Secrets Manager** — Flux
  authenticates to pull this repository as a GitHub App, and
  `opentofu/aws/eks/configure` reads its credentials from Secrets Manager at
  apply time (`var.github_app_secret_name`, default `github/flux-app`); if
  the secret does not exist, Stage 3 of the AWS deploy fails. Create the App
  per the
  [Flux GitHub App docs](https://fluxcd.io/flux/components/source/gitrepositories/#github),
  then publish its credentials:

  ```bash
  jq -n --arg key "$(cat your-githubapp.private-key.pem)" \
    '{githubAppID: "<app_id>", githubAppInstallationID: "<installation_id>", githubAppPrivateKey: $key}' \
    > flux-ghapp.json

  aws secretsmanager create-secret \
    --name github/flux-app \
    --description "FluxCD Github App" \
    --region eu-west-3 \
    --secret-string file://flux-ghapp.json
  ```

## State backend — create this bucket first

**Nothing in this repository can `plan` until this bucket exists.** It is the one
prerequisite OpenTofu cannot create for you: every stack stores its state in it,
so a stack that created it would have nowhere to record that it had. That
chicken-and-egg is why this step is manual, and why it is easy to forget — the
failure on a fresh clone is a backend error from the first `tofu init`, not a
message telling you to read this page.

State is **per cloud**: AWS stacks use an S3 bucket, GCP stacks use a GCS bucket
in a project that holds nothing else. See
[ADR-0018](../decisions/0018-per-cloud-opentofu-state.md).

The principle is that state lives outside the blast radius of what it manages.
An earlier layout kept GCP state in a GCS bucket inside the very project whose
resources it tracked, so deleting that project would have destroyed the record
of it. The first fix moved GCP state into the shared AWS bucket — which solved
the blast-radius problem, but by arguing against the wrong thing: the fault was
the *workload* project, not GCS. A dedicated state project fixes it without
coupling the clouds.

What that buys: running or destroying GCP needs GCP credentials only, and an AWS
outage cannot block a GCP teardown. The cost is one prerequisite bucket per
cloud instead of one in total.

The block below creates the **AWS** bucket only. If you are deploying GCP, its
state bucket, KMS key ring and Tailscale OAuth client are three separate
hand-created prerequisites — the full sequence is in `docs/gcp-bootstrap.md` in
the repository (bootstrap docs are not published to this site). Doing the AWS
steps alone leaves a GCP apply with nowhere to write its state.

```bash
BUCKET=demo-smana-remote-backend   # must match the backend blocks; see below
REGION=eu-west-3

aws s3api create-bucket \
  --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION"

# Versioning is the ONLY recovery path if state is corrupted or wrongly
# overwritten. Turn it on before the first apply, not after.
aws s3api put-bucket-versioning \
  --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

aws s3api put-bucket-encryption \
  --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"aws:kms","KMSMasterKeyID":"alias/aws/s3"}}]}'

aws s3api put-public-access-block \
  --bucket "$BUCKET" \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

State objects contain credentials and private keys in plaintext, so the
encryption and public-access settings above are not optional hardening — treat
the bucket as a secret store.

No DynamoDB table is needed. The backends set `use_lockfile = true`, which uses
native S3 locking via a `.tflock` object; the older DynamoDB locking table that
Terraform guides describe is obsolete here.

**If you use a different bucket name**, you must edit it in every stack, because
an OpenTofu `backend` block cannot take a variable. Find them all with:

```bash
grep -rn 'bucket ' --include=backend.tf opentofu/
```

Cross-stack readers hardcode it a second time — `terraform_remote_state` data
sources in `opentofu/gcp/gke/init/data.tf`, `opentofu/gcp/gke/configure/data.tf`
and `opentofu/aws/llm-platform/data.tf`. Changing the backends and missing those
leaves the readers pointing at a bucket that no longer receives writes: stale
reads, no error.

## Tools

This repository pins every CLI version it depends on in `mise.toml` — install
[mise](https://mise.jdx.dev/), then run:

```bash
mise install
```

That single command installs OpenTofu, Terramate, the Flux CLI, Helm,
Kustomize, and Trivy (the config scanner every `preview`/`deploy`/`drift
detect` script runs) at the exact versions this repository is built against.
`mise.toml` is the source of truth for those versions — check it directly
rather than trusting a number written in prose, here or anywhere else.

A few tools mise does **not** manage — install these separately:

- the AWS CLI, authenticated
- `kubectl`
- the OpenBao CLI (`bao`) — see [openbao.org](https://openbao.org/)
- `jq`
- the Tailscale client, to check `tailscale status` once Stage 1 is up

With accounts in place and tools installed, continue to
[AWS]({{< relref "/docs/get-started/aws/_index.md" >}}) — the only cloud
lane that is implemented today.
