# Vault Management

This repository facilitates the setup of an existing Vault cluster using the Vault provider.

1. **Configuring an Approle**: Learn what is an approle and how to set them up by reading [this](docs/approle.md).

2. **Configure cert-manager**: In order to easily provision certificates in Kubernetes you should consider reading [this documentation](./docs/cert-manager.md)

3. **Backup and Restore**: Implement a backup strategy. Follow this guide: [Backup and Restore](./docs/backup_restore.md).


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
     export VAULT_ADDR=https://bao.priv.cloud.ogenki.io:8200
     ```

   - ℹ️ **Note:** This guide does not include setting up an authentication system. It's recommended to use an identity provider instead of the root token for routine operations. Ensure the root token is securely stored.

2. **Enable PKI and Set TTL:**
   - Activate the PKI (Public Key Infrastructure) secrets engine and set the maximum Time To Live (TTL) to 10 years:

     ```bash
     bao secrets enable pki
     bao secrets tune -max-lease-ttl=315360000 pki
     ```

3. **Build and Import the Full Chain Bundle:**
   - Create the bundle and import it into Vault:

     ```console
     cd terraform/openbao/management
     cat .tls/intermediate-ca.pem .tls/root-ca.pem .tls/intermediate-ca-key.pem > .tls/bundle.pem
     bao write pki/config/ca pem_bundle=@.tls/bundle.pem
     ```

4. **Prepare `variables.tfvars` File:**
   - Example configuration:

     ```hcl
     domain_name      = "priv.cloud.ogenki.io"
     pki_country      = "France"
     pki_organization = "Ogenki"
     pki_domains = [
       "cluster.local",
       "priv.cloud.ogenki.io"
     ]

     tags = {
       project = "cloud-native-ref"
       owner   = "Smana"
     }
     ```

5. **Execute OpentofuCommands:**
   - Initialize and apply the Opentofu configuration:

     ```console
     tofu init
     tofu apply -var-file variables.tfvars
     ```

6. **Test by Generating a Certificate:**
   - Generate a certificate and verify it:

     ```console
     bao write -format=json pki_private_issuer/issue/pki_private_issuer common_name="foobar.priv.cloud.ogenki.io" ttl="720h" > data.json
     jq -r '.data.ca_chain[]' data.json > bao_ca_chain.pem
     jq -r '.data.certificate' data.json > foobar-cert.pem
     openssl verify -CAfile bao_ca_chain.pem foobar-cert.pem
     ```

     The output should confirm `foobar-cert.pem: OK`.

     And clean these test files
     ```console
     rm data.json bao_ca_chain.pem foobar-cert.pem
     ```

