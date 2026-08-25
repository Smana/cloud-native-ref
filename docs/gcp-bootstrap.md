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

## Public ingress: apply the federation stack, or cert-manager and external-dns fail opaquely

Different in kind from the three prerequisites above — this one IS managed by OpenTofu, in
`opentofu/shared/aws-gcp-federation` — but it belongs here because skipping it produces the same
symptom those items warn about: a deploy that succeeds and a cluster that then fails for a reason
nothing on GCP names.

`gcp-0`'s `letsencrypt-prod` ClusterIssuer and its `external-dns-public` HelmRelease both assume
an AWS IAM role over `AssumeRoleWithWebIdentity` — no access key, ever. See
`website/content/docs/decisions/0019-cross-cloud-dns-federation.md` for the full design. That
role, and the OIDC provider trusting GKE's issuer, live in `opentofu/shared/aws-gcp-federation`,
which is **not** part of the GCP stack tree (`opentofu/gcp/**`) and is not gated by
`TM_GCP_ENABLED`. Apply it explicitly:

```bash
cd opentofu/shared/aws-gcp-federation
tofu init
tofu apply -var-file=variables.tfvars
```

If it is missing when `gcp-0` reconciles, cert-manager and external-dns-public both fail against
AWS with an `AccessDenied` or `InvalidIdentityToken` that names neither the missing stack nor the
role — the Certificate just sits `False`, forever, with no pointer back here.

**Ordering note, not a bug to fix**: this stack deliberately has no Terramate `after` edge to or
from the GCP stacks (an AWS stack must not depend on a GCP one, and the reverse would be just as
wrong — see its `stack.tm.hcl`). On a fresh multi-stack `terramate script run deploy`, `gcp-0` can
therefore come up before this stack is applied. Nothing breaks permanently — cert-manager retries
and the ClusterIssuer's Let's Encrypt account registration is independent of it — but the first
few minutes of a brand-new deploy can show `AccessDenied` in both controllers before the role
exists. If you see that right after a fresh apply, apply this stack (if you have not already) and
give Flux a couple of reconcile intervals; do not treat it as a stuck deploy.

**Renaming or moving `gcp-0` breaks this stack, not the other way round.** The OIDC provider
trusts an issuer URL built from the project, location and cluster name
(`https://container.googleapis.com/v1/projects/<project>/locations/<location>/clusters/gcp-0`).
Change any of those and the provider has to be recreated — re-apply
`opentofu/shared/aws-gcp-federation` after any such rename.

**Deliberately left applied across teardowns.** Unlike the GCP stacks, this one is not destroyed
by a routine `gcp-0` teardown — its `destroy` script is guarded behind
`TM_FEDERATION_DESTROY=true`, the same pattern `opentofu/shared/tailscale` uses. An IAM role and
an OIDC provider cost nothing idle, and leaving them applied means a rebuilt `gcp-0` gets public
ingress working immediately rather than needing this stack re-applied every cycle.

## Credentials your shell needs

Distinct from the three prerequisites above: those are things that must EXIST in
GCP, these are things that must be in the environment you run `terramate` from.
Both cost a wasted round trip when missing, because the failure surfaces
mid-deploy rather than up front.

```bash
gcloud auth login
gcloud auth application-default login    # OpenTofu uses ADC, not the CLI credential
export TF_VAR_tailscale_api_key=<tskey-api-...>
```

- **`TF_VAR_tailscale_api_key`** — `opentofu/gcp/network` manages the tailnet's
  split-DNS entry and the subnet router's auth key. The variable has no default,
  so a missing value stops the apply at the prompt.
- **AWS credentials** — still needed, but only for `opentofu/shared/*`, whose
  state remains in S3 because the tailnet belongs to neither cloud. Since
  ADR-0018 the GCP stacks read GCS and need no AWS session of their own. Before
  that change a GCP-only deploy failed at `tofu init` with
  `No valid credential sources found` on an expired AWS SSO token, which is the
  coupling that ADR removed.

## What is NOT a prerequisite

The offline root CA and the GCP intermediate. Those come from the signing
ceremony in the [OpenBao design](superpowers/specs/2026-08-24-gcp-openbao-design.md)
and already live in Secret Manager (`openbao-priv-gcp-ca-chain`,
`openbao-priv-gcp-intermediate-ca`). The root's private key must never be in GCP.
