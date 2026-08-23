# Vault Management

This repository facilitates the setup of an existing Vault cluster using the Vault provider.

1. **Configuring an Approle**: Learn what is an approle and how to set them up by reading [AppRole: machine authentication](https://cnref.ogenki.io/docs/platform/security/openbao/#approle-machine-authentication).

2. **Configure cert-manager**: In order to easily provision certificates in Kubernetes you should consider reading [cert-manager: issuing from the PKI](https://cnref.ogenki.io/docs/platform/security/pki-and-secrets/#cert-manager-issuing-from-the-pki)

3. **Backup and Restore**: Implement a backup strategy. Follow this guide: [Backup and restore](https://cnref.ogenki.io/docs/platform/security/openbao/#backup-and-restore).

## ✅ Requirements

1. **Cluster Creation:** Start by following the cluster creation instructions available [here](../cluster/README.md).

2. **Required Certificates from AWS SecretsManager:** The certificates generated in the previous step must be stored in AWS Secrets Manager.
   - We need 2 keys named `ca` and `bundle` (:information_source: a bundle is the ca-chain along with the key)

## 🚀 Getting Started

1. **Vault Authentication:**
   - Authenticate to the Vault instance using the root token:

     ```console
     export VAULT_TOKEN=<token>
     export VAULT_SKIP_VERIFY=true
     export VAULT_ADDR=https://bao.priv.aws.ogenki.io:8200
     ```

   - ℹ️ **Note:** The root token is for bootstrap only. For routine operations use the
     userpass login this stack creates — `tofu output operator_login_command` prints it,
     and the generated password is in the Secrets Manager entry named by
     `tofu output admin_credentials_secret_name`. It carries both the `admin` and
     `pki-admin` policies.

     Retiring the root token entirely still needs an identity provider (Zitadel is
     already running in the cluster) plus the `aws` auth method so this stack can
     authenticate as an IAM role rather than carrying a token.

2. **PKI setup is handled by OpenTofu.**
   - There is no manual `bao secrets enable pki` step any more. `pki.tf` creates the
     `pki_private_issuer` mount in the **root** namespace, imports the CA bundle,
     generates a key, and signs and installs the intermediate.
   - The previous instructions enabled a *second* `pki` mount holding the same bundle,
     root CA private key included. Nothing consumed it, and it had no
     `vault_pki_secret_backend_role`, so it could not issue anything either — a
     duplicate online copy of the root CA key with no reader. Both it and the
     `openbao-config.sh pki` command that created it have been removed.

   > ⚠️ The root CA private key is still present in the `pki_private_issuer` mount,
   > because `vault_pki_secret_backend_root_sign_intermediate` signs the intermediate CSR
   > inside OpenBao. Keeping the root offline would mean the CSR leaves OpenBao, gets
   > signed elsewhere, and comes back — a manual step incompatible with
   > `terramate script run deploy`. Accepted for this reference platform; do not carry it
   > into a deployment where the root CA matters.

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
       --root-ca-secret-name certificates/priv.aws.ogenki.io/root-ca \
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
