# Vault Management

This repository facilitates the setup of an existing Vault cluster using the Vault provider.

1. **Machine authentication is the JWT method, not AppRole.** Each cluster's own
   `configure` stack creates its mount (`jwt/aws-0`, `jwt/gcp-0`) and roles — this stack
   owns only the policies those roles bind. Read
   [JWT: machine authentication](https://cnref.ogenki.io/docs/platform/security/openbao/#jwt-machine-authentication).

2. **Configure cert-manager**: In order to easily provision certificates in Kubernetes you should consider reading [cert-manager: issuing from the PKI](https://cnref.ogenki.io/docs/platform/security/pki-and-secrets/#cert-manager-issuing-from-the-pki)

3. **Backup and Restore**: Implement a backup strategy. Follow this guide: [Backup and restore](https://cnref.ogenki.io/docs/platform/security/openbao/#backup-and-restore).

## ✅ Requirements

1. **Cluster Creation:** Start by following the cluster creation instructions available [here](../cluster/README.md).

2. **Required certificates in AWS Secrets Manager**, from the offline signing ceremony:
   - `certificates/priv.aws.ogenki.io/intermediate-ca` — key `bundle`, the intermediate's
     certificate followed by its private key. This becomes the mount's issuer.
   - `certificates/priv.aws.ogenki.io/ca-chain` — key `ca`, certificates only
     (intermediate then root). This is what clients trust and what
     `openbao-config.sh ca` writes to `.tls/ca.pem`.

## ⛔ This stack is not destroyed by the default `destroy`

Everything here — the PKI mount, the auth mounts, the policies, the `app` namespace,
the `lineage/` marker mount — is *lineage* state that the Raft snapshot carries.
Destroying it at teardown would delete it from the live OpenBao moments before the
cluster stack takes its pre-destroy snapshot, so the snapshot would bring back an empty
store. The `destroy` script therefore no-ops unless `TM_LINEAGE_DESTROY=true`.

Its OpenTofu state stays valid across rebuilds because a rehydrated OpenBao holds the
same resources at the same paths. The `deploy` script runs
`scripts/openbao-config.sh rehydrate` before `tofu apply`: on the first deploy of a
lineage that is a plain `init`, and on every deploy after it restores the newest
snapshot into a freshly initialised node. See
[The lineage, and rehydrate at boot](https://cnref.ogenki.io/docs/platform/security/openbao/#the-lineage-and-rehydrate-at-boot).

## 🚀 Getting Started

1. **Vault Authentication:**
   - Authenticate to the Vault instance using the lineage's root token:

     ```console
     export VAULT_TOKEN=<token>
     export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200
     export VAULT_CACERT=.tls/ca.pem   # written by step 4 below, not VAULT_SKIP_VERIFY
     ```

   - ℹ️ **Note:** The root token is **not** retired. It stays valid for the lineage and
     is what this stack and `openbao-config.sh rehydrate` authenticate with, from an
     operator's or CI's context. For interactive work use the userpass login this stack
     creates instead — `tofu output operator_login_command` prints it, and the generated
     password is in the Secrets Manager entry named by
     `tofu output admin_credentials_secret_name`. It carries both the `admin` and
     `pki-admin` policies.

     Retiring the root token entirely still needs an identity provider (Zitadel is
     already running in the cluster) plus the `aws` auth method so this stack can
     authenticate as an IAM role rather than carrying a token.

2. **PKI setup is handled by OpenTofu, from a pre-signed intermediate.**
   - There is no manual `bao secrets enable pki` step any more. `pki.tf` creates the
     `pki_private_issuer` mount in the **root** namespace and imports the intermediate
     the offline root signed — certificate *and* key — as the mount's issuer, which is
     the shape GCP has used since 2026-08-25.
   - The intermediate bundle is read from
     `certificates/priv.aws.ogenki.io/intermediate-ca` (`{"bundle": "<cert>\n<key>"}`);
     the certificates-only chain for clients is
     `certificates/priv.aws.ogenki.io/ca-chain` (`{"ca": "<intermediate>\n<root>"}`).

   > ✅ The root CA private key is **not** on any networked system. The mount used to
   > import a bundle containing the root key and have OpenBao generate and self-sign its
   > own intermediate inside it (`vault_pki_secret_backend_root_sign_intermediate`); that
   > is gone, and the `certificates/priv.aws.ogenki.io/root-ca` secret that held the root
   > key has been deleted from Secrets Manager. Both clouds now chain to one offline root
   > — see
   > [PKI & Secrets](https://cnref.ogenki.io/docs/platform/security/pki-and-secrets/#building-the-chain).

3. **Prepare `variables.tfvars` File:**
   - Example configuration:

     ```hcl
     domain_name      = "priv.aws.ogenki.io"
     pki_country      = "France"
     pki_organization = "Ogenki"
     pki_domains = [
       "cluster.local",
       "priv.aws.ogenki.io"
     ]

     tags = {
       project = "cloud-native-ref"
       owner   = "Smana"
     }
     ```

4. **Write the CA chain for TLS verification:**
   - The Vault provider verifies the OpenBao server certificate rather than running with
     `skip_tls_verify`. A provider block cannot depend on a resource, so the CA has to be
     on disk before `tofu init`:

     ```console
     ../../../../scripts/openbao-config.sh ca \
       --root-ca-secret-name certificates/priv.aws.ogenki.io/ca-chain \
       --ca-output-file .tls/ca.pem
     ```

     `terramate script run deploy` does this for you. If the CA is not available yet on a
     first bootstrap, pass `-var openbao_skip_tls_verify=true` for that one run.

5. **Execute Opentofu Commands:**
   - Initialize and apply the Opentofu configuration:

     ```console
     tofu init
     tofu apply -var-file variables.tfvars
     ```

6. **Test by Generating a Certificate:**
   - Generate a certificate and verify it:

     ```console
     bao write -format=json pki_private_issuer/issue/pki_private_issuer common_name="foobar.priv.aws.ogenki.io" ttl="720h" > data.json
     jq -r '.data.ca_chain[]' data.json > bao_ca_chain.pem
     jq -r '.data.certificate' data.json > foobar-cert.pem
     openssl verify -CAfile bao_ca_chain.pem foobar-cert.pem
     ```

     The output should confirm `foobar-cert.pem: OK`.

     And clean these test files

     ```console
     rm data.json bao_ca_chain.pem foobar-cert.pem
     ```
