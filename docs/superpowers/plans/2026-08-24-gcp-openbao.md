# OpenBao on GCP Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the GKE cluster a private certificate authority — OpenBao at `bao.priv.gcp.ogenki.io:8200`, issuing for `*.priv.gcp.ogenki.io` from an intermediate signed by an offline root.

**Architecture:** Two OpenTofu stacks under `opentofu/gcp/openbao/`, mirroring the AWS split. `cluster/` builds a single-node zonal MIG behind an internal passthrough Network LB, auto-unsealed by Cloud KMS. `management/` runs the `vault` provider against the live endpoint and configures the PKI only. The root CA never touches a networked system; only the intermediate reaches GCP Secret Manager, imported directly as the issuer.

**Tech Stack:** OpenTofu, Terramate, `google` provider, `vault` provider, GCP Secret Manager, Cloud KMS, Cloud DNS, External Secrets, cert-manager.

**Spec:** [`docs/superpowers/specs/2026-08-24-gcp-openbao-design.md`](../specs/2026-08-24-gcp-openbao-design.md)

## Global Constraints

- **Domain:** `priv.gcp.ogenki.io`. Endpoint `bao.priv.gcp.ogenki.io:8200`.
- **Region/zone:** `europe-west4` / `europe-west4-a` — zonal, matching the GKE cluster.
- **CA key types:** root and intermediate `EC secp384r1`; OpenBao's server leaf `EC prime256v1` (P-256).
- **Server leaf SAN:** DNS name only. **No IP SAN.**
- **Key file permissions:** `chmod 600` — `openssl` writes world-readable by default.
- **Secret Manager IDs** permit only letters, digits, `-`, `_`. No slashes, no dots.
- **State backend:** S3 bucket `demo-smana-remote-backend`, region `eu-west-3` (the *bucket's* region, unrelated to the GCP region).
- **Terramate gate:** every script guards on `TM_GCP_ENABLED=true` and no-ops with `[skip]` otherwise.
- **No secret may be templated into instance metadata.** TLS material is fetched at boot from Secret Manager.
- **Never commit CA private keys.** The root key never leaves offline storage; the intermediate key exists only in Secret Manager.

### Verification model for this plan

This is infrastructure, so "write a failing test first" means **run the verification command and watch it fail for the right reason**, then implement, then watch it pass. The gates are:

| Layer | Command |
|---|---|
| OpenTofu | `tofu validate`, `trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .`, `tofu plan -var-file=variables.tfvars` |
| Shell | `shellcheck <script>` |
| Kubernetes manifests | `./scripts/validate-manifests.sh` → `Invalid: 0, Skipped: 0` |
| Docs | `./scripts/validate-links.sh` |

`tofu plan` against an undeployed stack is the closest analogue to a failing unit test: it proves the resource graph is right before anything is created.

---

### Task 1: IAM custom role for Secret Manager access

External Secrets needs to read GCP Secret Manager, which needs a `GCPWorkloadIdentity` claim. The IAM condition in `gke/init` allowlists only `xplane_dns_editor`, so such a claim is refused at the provider. This adds the second grantable role. Independent of everything else in this plan and safe to merge alone.

**Files:**
- Modify: `opentofu/gcp/gke/init/iam.tf`

**Interfaces:**
- Consumes: nothing.
- Produces: a custom role whose deterministic name is `projects/<project>/roles/xplane_secret_reader`, referenced by Task 8's claim.

- [ ] **Step 1: Confirm the gap is real — the claim would currently be refused**

Run:
```bash
cd opentofu/gcp/gke/init
grep -A4 'crossplane_grantable_roles' iam.tf
```
Expected: the list contains only `google_project_iam_custom_role.crossplane_dns.name`. That is the failing state — a Secret Manager claim has no allowlisted role.

- [ ] **Step 2: Add the custom role**

In `opentofu/gcp/gke/init/iam.tf`, after the `crossplane_dns` resource:

```hcl
# The Secret Manager role External Secrets is permitted to receive.
#
# Pre-created for the same reason as crossplane_dns: `hasOnly` matches exact
# role names, so a role the composition names at render time can never be
# allowlisted. Deterministic name, therefore allowlistable.
#
# `versions.access` only. NOT secretmanager.secrets.create/delete — External
# Secrets READS; anything that writes or destroys a secret is outside its job
# and outside the platform constitution's "no deletion permissions for stateful
# services" rule.
resource "google_project_iam_custom_role" "crossplane_secret_reader" {
  project     = var.project_id
  role_id     = "xplane_secret_reader"
  title       = "Crossplane Secret Manager reader"
  description = "Read secret payloads for External Secrets. No create, no delete; see opentofu/gcp/gke/init/iam.tf."

  permissions = [
    "secretmanager.versions.access",
    "secretmanager.versions.list",
    "secretmanager.secrets.get",
    "secretmanager.secrets.list",
  ]
}
```

- [ ] **Step 3: Add it to the allowlist**

Change the `crossplane_grantable_roles` local to:

```hcl
  crossplane_grantable_roles = [
    google_project_iam_custom_role.crossplane_dns.name,
    google_project_iam_custom_role.crossplane_secret_reader.name,
  ]
```

- [ ] **Step 4: Verify formatting, validity and the security gate**

Run:
```bash
cd opentofu/gcp/gke/init
tofu fmt -check iam.tf && tofu validate && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```
Expected: all three exit 0.

- [ ] **Step 5: Verify the condition now names two roles**

Run:
```bash
cd opentofu/gcp/gke/init
tofu console -var-file=variables.tfvars <<< 'local.crossplane_grant_condition'
```
Expected: output contains both `xplane_dns_editor` and `xplane_secret_reader`.
If `tofu console` needs credentials and none are present, substitute:
`grep -c 'google_project_iam_custom_role\.' iam.tf` → expect at least `4` (two definitions, two references).

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/gke/init/iam.tf
git commit -m "feat(gcp): allowlist a Secret Manager reader role for External Secrets"
```

---

### Task 2: `--cloud gcp` flag on `openbao-config.sh`

The script is AWS-only. Its cloud coupling is three seams; this replaces them with dispatching helpers so both clouds share one entry point.

**Files:**
- Modify: `scripts/openbao-config.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: `openbao-config.sh --cloud gcp --project <id> init|ca`, used by Tasks 5 and 7.

- [ ] **Step 1: Confirm the script rejects GCP today**

Run:
```bash
./scripts/openbao-config.sh ca --cloud gcp --project ogenki-435905 \
  --root-ca-secret-name openbao-priv-gcp-ca-chain --ca-output-file /tmp/ca.pem
```
Expected: FAIL — `--cloud` is an unknown option. That is the gap.

- [ ] **Step 2: Add the flag and its validation to `parse_args`**

Add near the other defaults (around line 26):
```bash
CLOUD="aws"
PROJECT=""
```

Add to the `case` in `parse_args`:
```bash
            --cloud)                      CLOUD="$2"; shift 2 ;;
            --project)                    PROJECT="$2"; shift 2 ;;
```

Add validation after parsing:
```bash
    case "$CLOUD" in
        aws) ;;
        gcp)
            if [ -z "$PROJECT" ]; then
                echo "Error: --project is required with --cloud gcp" >&2
                exit 1
            fi
            # Fail here rather than at the API call: passing an AWS-only flag to
            # GCP is a mistake about which cloud you are on, and the API error
            # would not say so.
            if [ -n "$PROFILE" ]; then
                echo "Error: --profile is AWS-only and cannot be used with --cloud gcp" >&2
                exit 1
            fi
            ;;
        *)
            echo "Error: --cloud must be 'aws' or 'gcp' (got '$CLOUD')" >&2
            exit 1
            ;;
    esac
```

- [ ] **Step 3: Replace the two cloud seams with dispatching helpers**

Add these functions, replacing the body of `create_or_update_secret` and the inline read in the `ca` path:

```bash
# Write a secret value, creating the secret if it does not exist.
# Usage: secret_write <name> <value>
secret_write() {
    local name=$1 value=$2
    if [ "$CLOUD" = "gcp" ]; then
        if gcloud secrets describe "$name" --project "$PROJECT" >/dev/null 2>&1; then
            printf '%s' "$value" | gcloud secrets versions add "$name" \
                --project "$PROJECT" --data-file=- >/dev/null
        else
            printf '%s' "$value" | gcloud secrets create "$name" \
                --project "$PROJECT" --replication-policy=automatic --data-file=- >/dev/null
        fi
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        if $aws_cmd secretsmanager describe-secret --secret-id "$name" >/dev/null 2>&1; then
            $aws_cmd secretsmanager update-secret --secret-id "$name" --secret-string "$value" >/dev/null
        else
            $aws_cmd secretsmanager create-secret --name "$name" --secret-string "$value" >/dev/null
        fi
    fi
}

# Read the current value of a secret to stdout.
# Usage: secret_read <name>
secret_read() {
    local name=$1
    if [ "$CLOUD" = "gcp" ]; then
        gcloud secrets versions access latest --secret "$name" --project "$PROJECT"
    else
        local aws_cmd; aws_cmd=$(get_aws_cmd)
        $aws_cmd secretsmanager get-secret-value --secret-id "$name" \
            --query SecretString --output text
    fi
}
```

Update the three call sites to use `secret_write "$NAME" "$VALUE"` and `secret_read "$NAME"`, dropping the `AWS_CMD` argument.

- [ ] **Step 4: Update `usage()` and `check_prerequisites`**

Add to `usage()`:
```bash
    echo "  --cloud <aws|gcp>                         Secret backend (default: aws)"
    echo "  --project <Project ID>                    GCP project (required for --cloud gcp)"
```

In `check_prerequisites`, require `gcloud` when `CLOUD=gcp` and `aws` otherwise.

- [ ] **Step 5: Verify with shellcheck**

Run: `shellcheck scripts/openbao-config.sh`
Expected: exit 0, no new warnings.

- [ ] **Step 6: Verify the flag validation actually fires**

Run:
```bash
./scripts/openbao-config.sh ca --cloud gcp --root-ca-secret-name x --ca-output-file /tmp/x
```
Expected: FAIL with `--project is required with --cloud gcp`.

```bash
./scripts/openbao-config.sh ca --cloud azure --project p --root-ca-secret-name x --ca-output-file /tmp/x
```
Expected: FAIL with `--cloud must be 'aws' or 'gcp'`.

- [ ] **Step 7: Commit**

```bash
git add scripts/openbao-config.sh
git commit -m "feat(openbao): add --cloud gcp to openbao-config.sh"
```

---

### Task 3: Generate the PKI material and load Secret Manager

The offline ceremony. This produces no code — it produces secrets and a written procedure. Do it before the cluster stack, because `cluster/` reads the server certificate at boot.

**Files:**
- Create: `docs/runbooks/gcp-openbao-pki-ceremony.md`

**Interfaces:**
- Consumes: nothing.
- Produces: Secret Manager secrets `openbao-priv-gcp-intermediate-ca`, `openbao-priv-gcp-server-cert`, `openbao-priv-gcp-ca-chain` — consumed by Tasks 5, 7 and 8.

- [ ] **Step 1: Confirm no PKI secrets exist yet**

Run: `gcloud secrets list --project ogenki-435905 --format='value(name)' | grep openbao || echo NONE`
Expected: `NONE`. That is the starting state.

- [ ] **Step 2: Generate the offline root**

On a machine you are willing to call offline for the duration, in a directory you will destroy afterwards:

```bash
umask 077
openssl ecparam -genkey -name secp384r1 -out root-ca-key.pem
openssl req -x509 -new -nodes -key root-ca-key.pem -sha384 -days 3653 \
  -subj "/CN=Ogenki Root CA/O=Ogenki/C=FR" -out root-ca.pem
chmod 600 root-ca-key.pem
```

- [ ] **Step 3: Generate and sign the GCP intermediate**

```bash
cat > intermediate-ca.cnf <<'EOF'
[v3_req]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
EOF

openssl ecparam -genkey -name secp384r1 -out intermediate-ca-key.pem
openssl req -new -key intermediate-ca-key.pem \
  -subj "/CN=Ogenki GCP Intermediate CA/O=Ogenki/C=FR" -out intermediate-ca.csr
openssl x509 -req -in intermediate-ca.csr -CA root-ca.pem -CAkey root-ca-key.pem \
  -CAcreateserial -out intermediate-ca.pem -days 1827 -sha384 \
  -extfile intermediate-ca.cnf -extensions v3_req
chmod 600 intermediate-ca-key.pem
```

- [ ] **Step 4: Generate OpenBao's server leaf — P-256, DNS SAN only**

```bash
cat > server.cnf <<'EOF'
[v3_req]
basicConstraints = CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:bao.priv.gcp.ogenki.io
EOF

openssl ecparam -genkey -name prime256v1 -out server-key.pem
openssl req -new -key server-key.pem -subj "/CN=bao.priv.gcp.ogenki.io" -out server.csr
openssl x509 -req -in server.csr -CA intermediate-ca.pem -CAkey intermediate-ca-key.pem \
  -CAcreateserial -out server.pem -days 825 -sha256 \
  -extfile server.cnf -extensions v3_req
chmod 600 server-key.pem
```

- [ ] **Step 5: Verify the chain before uploading anything**

```bash
cat intermediate-ca.pem root-ca.pem > ca-chain.pem
openssl verify -CAfile root-ca.pem -untrusted intermediate-ca.pem server.pem
openssl x509 -in server.pem -noout -text | grep -A1 'Subject Alternative Name'
```
Expected: `server.pem: OK`, and the SAN line reads exactly `DNS:bao.priv.gcp.ogenki.io` with **no IP Address entry**. If an IP appears, regenerate — this is the constraint the spec calls out.

- [ ] **Step 6: Upload to Secret Manager**

```bash
P=ogenki-435905

jq -Rs '{bundle: .}' < <(cat intermediate-ca.pem intermediate-ca-key.pem) \
  | gcloud secrets create openbao-priv-gcp-intermediate-ca \
      --project "$P" --replication-policy=automatic --data-file=-

jq -n --rawfile cert server.pem --rawfile key server-key.pem --rawfile ca ca-chain.pem \
  '{cert: $cert, key: $key, ca: $ca}' \
  | gcloud secrets create openbao-priv-gcp-server-cert \
      --project "$P" --replication-policy=automatic --data-file=-

gcloud secrets create openbao-priv-gcp-ca-chain \
  --project "$P" --replication-policy=automatic --data-file=ca-chain.pem
```

The JSON shapes are deliberate: `{bundle}` matches what `vault_pki_secret_backend_config_ca` reads in Task 7, and `{cert,key,ca}` matches what the boot script's `jq -r '.cert'` reads in Task 5.

- [ ] **Step 7: Move the root key offline and destroy the working directory**

Copy `root-ca-key.pem` and `root-ca.pem` to whatever you have chosen as offline storage. Then:

```bash
shred -u root-ca-key.pem intermediate-ca-key.pem server-key.pem 2>/dev/null || rm -f root-ca-key.pem intermediate-ca-key.pem server-key.pem
```

**The root key must not exist on this machine or in any cloud afterwards.** Verify:
```bash
gcloud secrets list --project ogenki-435905 --format='value(name)' | grep -i root
```
Expected: only `openbao-priv-gcp-ca-chain` (certificates, no key). No secret holding the root private key.

- [ ] **Step 8: Write the runbook**

Write `docs/runbooks/gcp-openbao-pki-ceremony.md` containing Steps 2–7 verbatim, plus: where the root is stored, who can reach it, and the fact that re-running Step 4 alone is how the server certificate is re-issued if the hostname changes — which is the failure that stranded the AWS chain on 2026-08-23.

- [ ] **Step 9: Commit**

```bash
git add docs/runbooks/gcp-openbao-pki-ceremony.md
git commit -m "docs(gcp): OpenBao PKI ceremony runbook for the offline root"
```

---

### Task 4: Cluster stack scaffolding — backend, KMS, service account, IAM

**Files:**
- Create: `opentofu/gcp/openbao/cluster/backend.tf`, `providers.tf`, `versions.tf`, `variables.tf`, `variables.tfvars`, `data.tf`, `kms.tf`, `iam.tf`, `locals.tf`, `stack.tm.hcl`, `workflows.tm.hcl`, `.trivyignore.yaml`, `trivy.yaml`

**Interfaces:**
- Consumes: Task 3's Secret Manager secrets.
- Produces: `google_service_account.openbao.email`, `google_kms_crypto_key.openbao.id`, and `data.terraform_remote_state.network` outputs — all consumed by Tasks 5 and 6.

- [ ] **Step 1: Confirm the stack does not exist**

Run: `ls opentofu/gcp/openbao/cluster/ 2>&1`
Expected: `No such file or directory`.

- [ ] **Step 2: Create the backend, copying the S3 rationale**

`opentofu/gcp/openbao/cluster/backend.tf`:
```hcl
# State lives in S3, not GCS, even though this stack manages GCP resources.
# See opentofu/gcp/network/backend.tf for the full rationale.
#
# NOTE the hardcoded region. It is the S3 BUCKET's region and has nothing to do
# with var.region, which in this stack is a GCP region (europe-west4).
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/gcp/openbao/cluster/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
```

- [ ] **Step 3: Read the network stack's outputs**

`opentofu/gcp/openbao/cluster/data.tf`:
```hcl
data "google_project" "this" {
  project_id = var.project_id
}

data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "demo-smana-remote-backend"
    key    = "cloud-native-ref/gcp/network/opentofu.tfstate"
    # Literal, NOT var.region: this is the S3 bucket's region, while var.region
    # in this stack is a GCP region (europe-west4).
    region = "eu-west-3"
  }
}
```

`locals.tf`:
```hcl
locals {
  network             = data.terraform_remote_state.network.outputs
  subnetwork_self_link = local.network.nodes_subnetwork_self_link
  private_dns_zone    = local.network.private_dns_zone_name
  private_domain_name = local.network.private_domain_name
  fqdn                = "bao.${local.network.private_domain_name}"
}
```

- [ ] **Step 4: Create the Cloud KMS key for auto-unseal**

`kms.tf`:
```hcl
# Auto-unseal. The instance service account gets encrypter/decrypter on this key
# and nothing else — it never needs to manage the key, only use it.
#
# prevent_destroy is deliberate: destroying the key makes every sealed OpenBao
# permanently unrecoverable. Cloud KMS keys cannot truly be deleted anyway
# (versions are scheduled for destruction), so a teardown leaves the key ring
# behind by design. It costs nothing when idle.
resource "google_kms_key_ring" "openbao" {
  name     = "openbao-${var.env}"
  project  = var.project_id
  location = var.region
}

resource "google_kms_crypto_key" "openbao" {
  name     = "openbao-unseal"
  key_ring = google_kms_key_ring.openbao.id
  purpose  = "ENCRYPT_DECRYPT"

  lifecycle {
    prevent_destroy = true
  }
}
```

- [ ] **Step 5: Create the service account and its scoped bindings**

`iam.tf`:
```hcl
resource "google_service_account" "openbao" {
  account_id   = "openbao-${var.env}"
  display_name = "OpenBao node"
  project      = var.project_id
}

# Unseal only. Not admin on the key.
resource "google_kms_crypto_key_iam_member" "openbao_unseal" {
  crypto_key_id = google_kms_crypto_key.openbao.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${google_service_account.openbao.email}"
}

# Read the server certificate at boot. Scoped to that ONE secret — not
# project-wide secretAccessor, which would let the node read Flux's GitHub App
# credentials and every other secret in the project.
resource "google_secret_manager_secret_iam_member" "openbao_server_cert" {
  project   = var.project_id
  secret_id = var.server_cert_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.openbao.email}"
}
```

- [ ] **Step 6: Create variables with the spec's values as defaults**

`variables.tf` — `project_id`, `region` (default `europe-west4`), `zone` (default `europe-west4-a`), `env` (default `dev`), `machine_type` (default `e2-small`), `openbao_version`, `data_disk_size_gb` (default 10), `server_cert_secret_name` (default `openbao-priv-gcp-server-cert`), `openbao_data_path` (default `/opt/openbao/data`).

`variables.tfvars` sets `project_id = "ogenki-435905"` and leaves the rest on defaults, with a comment saying why each non-default exists.

- [ ] **Step 7: Create the Terramate wiring**

`stack.tm.hcl` mirroring `opentofu/gcp/network/stack.tm.hcl`, with `after` pointing at the network stack. `workflows.tm.hcl` with `deploy`, `preview`, `destroy`, `init`, `drift detect|reconcile` and `opentofu render` scripts, each guarded by `TM_GCP_ENABLED`.

**The `destroy` script must use the tolerant pattern**, not a bare `tofu destroy` — see `opentofu/gcp/gke/configure/workflows.tm.hcl` for why a strict destroy in a `--reverse` run strands billable resources.

Create `.trivyignore.yaml` with `misconfigurations: []` and `trivy.yaml` with `scan.skip-dirs: [.terraform]`, copying the comments from `opentofu/gcp/gke/init/`.

- [ ] **Step 8: Verify the stack initialises and plans**

Run:
```bash
cd opentofu/gcp/openbao/cluster
tofu init -backend=false && tofu validate && tofu fmt -check
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```
Expected: all exit 0.

- [ ] **Step 9: Commit**

```bash
git add opentofu/gcp/openbao/cluster/
git commit -m "feat(gcp): OpenBao cluster stack scaffolding, KMS and IAM"
```

---

### Task 5: Cluster compute — instance template, MIG, boot script

**Files:**
- Create: `opentofu/gcp/openbao/cluster/compute.tf`, `scripts/startup-script.sh`, `scripts/setup-local-disks.sh`

**Interfaces:**
- Consumes: Task 4's `google_service_account.openbao.email`, `google_kms_crypto_key.openbao.id`, `local.subnetwork_self_link`, `local.fqdn`.
- Produces: `google_compute_instance_group_manager.openbao.instance_group` — consumed by Task 6's backend service.

- [ ] **Step 1: Port the disk setup script**

Copy `opentofu/aws/openbao/cluster/scripts/setup-local-disks.sh` to the new stack, replacing NVMe device discovery with GCP's stable symlink `/dev/disk/by-id/google-openbao-data`. Keep the idempotency check — the script runs on every boot, not only the first.

- [ ] **Step 2: Port the startup script**

`scripts/startup-script.sh`, templated with exactly these variables — the list
must match what the config block below references, or `templatefile` fails at
plan time:

`openbao_version`, `openbao_data_path`, `project_id`, `region`,
`kms_key_ring`, `kms_crypto_key`, `server_cert_secret_name`, `fqdn`.

Pass the key ring and key by NAME (`google_kms_key_ring.openbao.name`,
`google_kms_crypto_key.openbao.name`), not by id.

Carry over verbatim from the AWS script:
- The pinned GPG fingerprint check `66D15FDD87287219C8E15478D200CD702853E6D0` and the reasoning comment — without it the key is fetched and trusted on sight.
- The header warning that **nothing secret may be templated into this file**; GCP instance metadata is readable from the metadata server by anything on the box.

Replace the AWS-specific parts:
```bash
# Instance identity from the GCP metadata server (IMDS equivalent).
PRIVATE_IP=$(curl -fsS -H "Metadata-Flavor: Google" \
  http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/ip)

install -d -m 0750 -o root -g openbao /opt/openbao/tls

TLS_SECRET=$(gcloud secrets versions access latest \
  --secret "${server_cert_secret_name}" --project "${project_id}")

umask 077
printf '%s' "$TLS_SECRET" | jq -r '.cert' > /opt/openbao/tls/tls.crt
printf '%s' "$TLS_SECRET" | jq -r '.key'  > /opt/openbao/tls/tls.key
printf '%s' "$TLS_SECRET" | jq -r '.ca'   > /opt/openbao/tls/ca.pem
unset TLS_SECRET

chown root:openbao /opt/openbao/tls/tls.key
chmod 0640 /opt/openbao/tls/tls.key
chmod 0644 /opt/openbao/tls/tls.crt /opt/openbao/tls/ca.pem
```

And the config, with `gcpckms` replacing `awskms`:
```bash
cat << EOF > /etc/openbao/openbao.hcl
cluster_addr = "https://$PRIVATE_IP:8201"
api_addr     = "https://${fqdn}:8200"
ui           = true

listener "tcp" {
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
  tls_cert_file   = "/opt/openbao/tls/tls.crt"
  tls_key_file    = "/opt/openbao/tls/tls.key"
}

storage "file" {
  path = "${openbao_data_path}"
}

seal "gcpckms" {
  project    = "${project_id}"
  region     = "${region}"
  key_ring   = "${kms_key_ring}"
  crypto_key = "${kms_crypto_key}"
}
EOF
```

Note `gcpckms` takes key ring and key **names**, not the fully-qualified id — passing the id is a common error that fails at unseal, not at boot.

- [ ] **Step 3: Create the instance template and MIG**

`compute.tf`, with `metadata_startup_script = templatefile(...)`, the service account attached with scope `cloud-platform`, a 10 GB `pd-balanced` data disk named `openbao-data`, `shielded_instance_config` enabled, and a MIG with `target_size = 1`.

- [ ] **Step 4: Verify shell and OpenTofu**

Run:
```bash
shellcheck -e SC2154 opentofu/gcp/openbao/cluster/scripts/*.sh
cd opentofu/gcp/openbao/cluster && tofu validate && tofu fmt -check
trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
```
Expected: all exit 0. `SC2154` is excluded because the scripts reference variables that `templatefile` substitutes.

- [ ] **Step 5: Commit**

```bash
git add opentofu/gcp/openbao/cluster/
git commit -m "feat(gcp): OpenBao instance template, MIG and boot script"
```

---

### Task 6: Internal load balancer, firewall and DNS

**Files:**
- Create: `opentofu/gcp/openbao/cluster/load_balancer.tf`, `firewall.tf`, `dns.tf`, `outputs.tf`

**Interfaces:**
- Consumes: Task 5's `instance_group`, Task 4's `local.private_dns_zone`.
- Produces: outputs `endpoint` (`https://bao.priv.gcp.ogenki.io:8200`) and `service_account_email`, consumed by Task 7.

- [ ] **Step 1: Create the internal passthrough Network LB**

`load_balancer.tf` — a regional `google_compute_health_check` (TCP 8200; **not** HTTPS, because the health check would need to trust the private CA), a `google_compute_region_backend_service` with `load_balancing_scheme = "INTERNAL"` and protocol TCP, and a `google_compute_forwarding_rule` on port 8200 whose `ip_address` is a
reserved `google_compute_address.openbao` — declare it here with
`address_type = "INTERNAL"` and the node subnetwork, because Task 6 Step 3's DNS
record refers to `google_compute_address.openbao.address` by that exact name.

- [ ] **Step 2: Create firewall rules**

`firewall.tf` — allow TCP 8200 from the node subnet and the tailnet advertised routes (`local.network.advertised_routes`), and allow the Google health-check ranges `130.211.0.0/22` and `35.191.0.0/16` on 8200. Add the IAP range `35.235.240.0/20` on TCP 22 behind a `var.enable_iap_ssh` flag defaulting to `false`, with a comment that the tailnet already reaches the subnet and an always-on admin path is a standing exposure.

- [ ] **Step 3: Create the DNS record**

`dns.tf`:
```hcl
resource "google_dns_record_set" "openbao" {
  project      = var.project_id
  managed_zone = local.private_dns_zone
  name         = "${local.fqdn}."
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.openbao.address]
}
```

- [ ] **Step 4: Verify, then deploy for real**

Run:
```bash
cd opentofu/gcp/openbao/cluster
tofu validate && tofu fmt -check && trivy config --exit-code=1 --ignorefile=./.trivyignore.yaml .
TM_GCP_ENABLED=true terramate script run --disable-check-git-remote deploy
```
Expected: apply completes. **Read the output, not the exit code** — Terramate has reported exit 0 over a failed run repeatedly in this repository.

- [ ] **Step 5: Verify the node came up and can be initialised**

```bash
export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200
gcloud secrets versions access latest --secret openbao-priv-gcp-ca-chain \
  --project ogenki-435905 > /tmp/gcp-ca.pem
export VAULT_CACERT=/tmp/gcp-ca.pem
bao status
```
Expected: `Initialized false`, `Sealed true`. If TLS fails to verify, the server leaf or chain is wrong — go back to Task 3 Step 5.

```bash
./scripts/openbao-config.sh init --cloud gcp --project ogenki-435905 \
  --url https://bao.priv.gcp.ogenki.io:8200 \
  --root-token-secret-name openbao-priv-gcp-root-token \
  --recovery-keys-secret-name openbao-priv-gcp-recovery-keys
bao status
```
Expected: `Initialized true`, `Sealed false` — sealed false **without** an unseal command proves `gcpckms`.

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/openbao/cluster/
git commit -m "feat(gcp): OpenBao internal load balancer, firewall and DNS"
```

---

### Task 7: Management stack — PKI

**Files:**
- Create: `opentofu/gcp/openbao/management/{backend,providers,versions,variables,data,pki,roles,auth,policies,outputs}.tf`, `variables.tfvars`, `stack.tm.hcl`, `workflows.tm.hcl`

**Interfaces:**
- Consumes: Task 6's endpoint, Task 3's `openbao-priv-gcp-intermediate-ca`.
- Produces: Secret Manager secret `openbao-priv-gcp-approle-cert-manager` holding `{role_id, secret_id}` — consumed by Task 8.

- [ ] **Step 1: Verify the untested assumption FIRST**

The spec flags one assumption the whole chain rests on: that `config_ca` alone leaves the mount able to issue, without the CSR/sign/set-signed sequence. Test it by hand before writing any HCL:

```bash
export VAULT_ADDR=https://bao.priv.gcp.ogenki.io:8200 VAULT_CACERT=/tmp/gcp-ca.pem
export VAULT_TOKEN=$(gcloud secrets versions access latest \
  --secret openbao-priv-gcp-root-token --project ogenki-435905 | jq -r '.root_token')

bao secrets enable -path=pki_test pki
gcloud secrets versions access latest --secret openbao-priv-gcp-intermediate-ca \
  --project ogenki-435905 | jq -r '.bundle' | bao write pki_test/config/ca pem_bundle=-
bao write pki_test/roles/test allowed_domains=priv.gcp.ogenki.io allow_subdomains=true max_ttl=72h
bao write pki_test/issue/test common_name=probe.priv.gcp.ogenki.io ttl=1h
```
Expected: the last command returns a certificate. **If it fails, stop and revisit the design** — the four removed resources may be required after all. Clean up: `bao secrets disable pki_test`.

- [ ] **Step 2: Create the vault provider wiring**

`providers.tf` reading the root token from GCP Secret Manager via `data.google_secret_manager_secret_version`, mirroring how the AWS management stack reads it from Secrets Manager.

- [ ] **Step 3: Create the PKI mount and import the intermediate**

`pki.tf`:
```hcl
resource "vault_mount" "pki" {
  path                      = var.pki_mount_path
  type                      = "pki"
  description               = var.pki_common_name
  default_lease_ttl_seconds = var.pki_max_lease_ttl
  max_lease_ttl_seconds     = var.pki_max_lease_ttl
}

# The openssl-made intermediate IS the issuer. Unlike the AWS stack there is no
# vault_pki_secret_backend_key / intermediate_cert_request / root_sign_intermediate
# / intermediate_set_signed sequence: that exists only to generate an
# OpenBao-internal intermediate under an imported ROOT, and this design never
# imports the root. Verified by hand before this was written — see the plan.
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.google_secret_manager_secret_version.intermediate_ca.secret_data).bundle
}
```

- [ ] **Step 4: Create the cert-manager role, policy and AppRole**

Port `roles.tf`, `policies.tf` and the `cert_manager` AppRole from `opentofu/aws/openbao/management/`, changing `allowed_domains` to `priv.gcp.ogenki.io`. Do **not** port the snapshot AppRole, the `app` namespace, the kv-v2 mount or the userpass backend.

Write the AppRole credentials to Secret Manager:
```hcl
resource "google_secret_manager_secret" "approle_cert_manager" {
  project   = var.project_id
  secret_id = "openbao-priv-gcp-approle-cert-manager"
  replication { auto {} }
}

resource "google_secret_manager_secret_version" "approle_cert_manager" {
  secret = google_secret_manager_secret.approle_cert_manager.id
  secret_data = jsonencode({
    role_id   = vault_approle_auth_backend_role.cert_manager.role_id
    secret_id = vault_approle_auth_backend_role_secret_id.cert_manager.secret_id
  })
}
```

- [ ] **Step 5: Deploy and verify issuance through the real mount**

```bash
cd opentofu/gcp/openbao/management
TM_GCP_ENABLED=true terramate script run --disable-check-git-remote deploy
bao write pki_private_issuer/issue/ogenki common_name=probe.priv.gcp.ogenki.io ttl=1h
```
Expected: a certificate is returned. Verify it chains to the offline root:
```bash
bao write -field=certificate pki_private_issuer/issue/ogenki \
  common_name=probe.priv.gcp.ogenki.io ttl=1h > /tmp/probe.pem
openssl verify -CAfile /tmp/gcp-ca.pem /tmp/probe.pem
```
Expected: `/tmp/probe.pem: OK`.

- [ ] **Step 6: Commit**

```bash
git add opentofu/gcp/openbao/management/
git commit -m "feat(gcp): OpenBao management stack — PKI from an offline root"
```

---

### Task 8: GKE wiring — External Secrets and cert-manager

**Files:**
- Create: `security/gcp-mycluster-0/openbao/{gcpworkloadidentity,secretstore,externalsecrets,clusterissuer}.yaml`, `kustomization.yaml`
- Create: `clusters/gcp-mycluster-0/security/security.yaml`

**Interfaces:**
- Consumes: Task 1's `xplane_secret_reader`, Task 7's AppRole secret, Task 3's CA chain.
- Produces: a working `ClusterIssuer` named `openbao`.

- [ ] **Step 1: Confirm the cluster has no issuer yet**

Run: `kubectl get clusterissuer 2>&1`
Expected: `No resources found` or the CRD is absent. That is the failing state.

- [ ] **Step 2: Create the GCPWorkloadIdentity claim for External Secrets**

```yaml
apiVersion: cloud.ogenki.io/v1alpha1
kind: GCPWorkloadIdentity
metadata:
  name: xplane-external-secrets
  namespace: security
spec:
  serviceAccount:
    name: external-secrets
  roles:
    - "projects/ogenki-435905/roles/xplane_secret_reader"
```

Note there is no `namespace` under `serviceAccount` — the composition derives it from the claim, which is why the claim must live in the same namespace as the ServiceAccount.

- [ ] **Step 3: Create the ClusterSecretStore, ExternalSecrets and ClusterIssuer**

A `ClusterSecretStore` with `provider.gcpsm` pointing at project `ogenki-435905`; two `ExternalSecret`s pulling `openbao-priv-gcp-approle-cert-manager` and `openbao-priv-gcp-ca-chain`; and a `ClusterIssuer` with `spec.vault.server: https://bao.priv.gcp.ogenki.io:8200`, `path: pki_private_issuer/sign/ogenki`, `caBundleSecretRef` and AppRole auth — modelled on `security/base/cert-manager/openbao-clusterissuer.yaml`.

- [ ] **Step 4: Validate the manifests before applying**

Run: `./scripts/validate-manifests.sh`
Expected: exit 0 and `Invalid: 0, Skipped: 0`.

- [ ] **Step 5: Verify end to end with a real certificate**

```bash
kubectl apply -f - <<'EOF'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: probe, namespace: security}
spec:
  secretName: probe-tls
  commonName: probe.priv.gcp.ogenki.io
  dnsNames: [probe.priv.gcp.ogenki.io]
  issuerRef: {name: openbao, kind: ClusterIssuer}
EOF
kubectl wait --for=condition=Ready certificate/probe -n security --timeout=120s
kubectl get secret probe-tls -n security -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl verify -CAfile /tmp/gcp-ca.pem /dev/stdin
```
Expected: `Ready=True`, and the chain verifies to the offline root. Then `kubectl delete certificate probe -n security`.

- [ ] **Step 6: Commit**

```bash
git add security/gcp-mycluster-0/ clusters/gcp-mycluster-0/security/
git commit -m "feat(gcp): wire cert-manager to OpenBao via External Secrets"
```

---

## Final verification

Run against the live cluster, then tear everything down.

- [ ] Success criteria 1–8 from the [spec](../specs/2026-08-24-gcp-openbao-design.md#success-criteria), each with its command output cited.
- [ ] `TM_GCP_ENABLED=true terramate script run deploy` a second time → 0-change plan on both stacks.
- [ ] Teardown, then `gcloud compute instances list`, `gcloud container clusters list` and `gcloud secrets list | grep -i root` all empty of this workstream's resources.

**The KMS key ring survives teardown by design** (`prevent_destroy`), because destroying it would make any sealed OpenBao unrecoverable. It costs nothing idle. Do not treat it as a teardown leak.
