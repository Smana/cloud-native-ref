# Vault Management

This repository facilitates the setup of an existing Vault cluster using the Vault provider.

1. **Configuring an Approle**: Learn what is an approle and how to set them up by reading [this](docs/approle.md).

2. **Configure cert-manager**: In order to easily provision certificates in Kubernetes you should consider reading [this documentation](./docs/cert-manager.md)

3. **Backup and Restore**: Implement a backup strategy. Follow this guide: [Backup and Restore](./docs/backup_restore.md).


## ✅ Requirements

1. **Cluster Creation:** Start by following the cluster creation instructions available [here](../cluster/README.md).

2. **Required Files:** Ensure you have these files, generated in the previous step:
   - `intermediate-ca.pem`
   - `root-ca.pem`
   - `root-ca-key.pem`
     > ⚠️ **Important:** The `root-ca-key.pem` file is highly sensitive. Securely store it and delete it immediately after use.

## 🚀 Getting Started

1. **Vault Authentication:**
   - Authenticate to the Vault instance using the root token:

     ```console
     export VAULT_TOKEN=<token>
     export VAULT_SKIP_VERIFY=true
     export VAULT_ADDR=https://vault.priv.cloud.ogenki.io:8200
     ```

   - ℹ️ **Note:** This guide does not include setting up an authentication system. It's recommended to use an identity provider instead of the root token for routine operations. Ensure the root token is securely stored.

2. **Enable PKI and Set TTL:**
   - Activate the PKI (Public Key Infrastructure) secrets engine and set the maximum Time To Live (TTL) to 10 years:

     ```bash
     vault secrets enable pki
     vault secrets tune -max-lease-ttl=315360000 pki
     ```

3. **Build and Import the Full Chain Bundle:**
   - Create the bundle and import it into Vault:

     ```console
     cd terraform/vault/management
     cat .tls/intermediate-ca.pem .tls/root-ca.pem .tls/intermediate-ca-key.pem > .tls/bundle.pem
     vault write pki/config/ca pem_bundle=@.tls/bundle.pem
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

5. **Execute Terraform Commands:**
   - Initialize and apply the Terraform configuration:

     ```console
     tofu init
     tofu apply -var-file variables.tfvars
     ```

6. **Test by Generating a Certificate:**
   - Generate a certificate and verify it:

     ```console
     vault write -format=json pki_private_issuer/issue/pki_private_issuer common_name="foobar.priv.cloud.ogenki.io" ttl="720h" > data.json
     jq -r '.data.ca_chain[]' data.json > vault_ca_chain.pem
     jq -r '.data.certificate' data.json > foobar-cert.pem
     openssl verify -CAfile vault_ca_chain.pem foobar-cert.pem
     ```

     The output should confirm `foobar-cert.pem: OK`.

     And clean these test files
     ```console
     rm data.json vault_ca_chain.pem foobar-cert.pem
     ```

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_vault"></a> [vault](#requirement\_vault) | ~> 4.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_vault"></a> [vault](#provider\_vault) | ~> 4.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [vault_approle_auth_backend_role.cert_manager](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/approle_auth_backend_role) | resource |
| [vault_approle_auth_backend_role.snapshot](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/approle_auth_backend_role) | resource |
| [vault_auth_backend.approle](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/auth_backend) | resource |
| [vault_mount.secret](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/mount) | resource |
| [vault_mount.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/mount) | resource |
| [vault_pki_secret_backend_intermediate_cert_request.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_intermediate_cert_request) | resource |
| [vault_pki_secret_backend_intermediate_set_signed.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_intermediate_set_signed) | resource |
| [vault_pki_secret_backend_issuer.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_issuer) | resource |
| [vault_pki_secret_backend_key.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_key) | resource |
| [vault_pki_secret_backend_role.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_role) | resource |
| [vault_pki_secret_backend_root_sign_intermediate.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_root_sign_intermediate) | resource |
| [vault_policy.admin](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/policy) | resource |
| [vault_policy.cert_manager](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/policy) | resource |
| [vault_policy.snapshot](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/policy) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allowed_cidr_blocks"></a> [allowed\_cidr\_blocks](#input\_allowed\_cidr\_blocks) | List of CIDR blocks allowed to reach Vault's API | `list(string)` | <pre>[<br>  "10.0.0.0/16"<br>]</pre> | no |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | The domain name for which the certificate should be issued | `string` | n/a | yes |
| <a name="input_pki_common_name"></a> [pki\_common\_name](#input\_pki\_common\_name) | Common name to identify the Vault issuer | `string` | `"Private PKI - Vault Issuer"` | no |
| <a name="input_pki_country"></a> [pki\_country](#input\_pki\_country) | The country name used for generating certificates | `string` | n/a | yes |
| <a name="input_pki_domains"></a> [pki\_domains](#input\_pki\_domains) | List of domain names that can be used within the certificates | `list(string)` | <pre>[<br>  "cluster.local"<br>]</pre> | no |
| <a name="input_pki_key_bits"></a> [pki\_key\_bits](#input\_pki\_key\_bits) | The number of bits of generated keys | `number` | `256` | no |
| <a name="input_pki_key_type"></a> [pki\_key\_type](#input\_pki\_key\_type) | The generated key type | `string` | `"ec"` | no |
| <a name="input_pki_max_lease_ttl"></a> [pki\_max\_lease\_ttl](#input\_pki\_max\_lease\_ttl) | Maximum TTL (in seconds) that can be requested for certificates (default 3 years) | `number` | `94670856` | no |
| <a name="input_pki_mount_path"></a> [pki\_mount\_path](#input\_pki\_mount\_path) | Vault Issuer PKI mount path | `string` | `"pki_private_issuer"` | no |
| <a name="input_pki_organization"></a> [pki\_organization](#input\_pki\_organization) | The organization name used for generating certificates | `string` | n/a | yes |
| <a name="input_vault_domain_name"></a> [vault\_domain\_name](#input\_vault\_domain\_name) | Vault domain name (default: vault.<domain\_name>) | `string` | `""` | no |

## Outputs

No outputs.
<!-- END_TF_DOCS -->
