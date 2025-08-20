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

<!-- BEGIN_TF_DOCS -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 6.0 |
| <a name="requirement_vault"></a> [vault](#requirement\_vault) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | 6.7.0 |
| <a name="provider_vault"></a> [vault](#provider\_vault) | 5.1.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [aws_secretsmanager_secret.cert_manager_approle_credentials](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret) | resource |
| [aws_secretsmanager_secret_version.cert_manager_approle_credentials](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version) | resource |
| [vault_approle_auth_backend_role.cert_manager](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/approle_auth_backend_role) | resource |
| [vault_approle_auth_backend_role.snapshot](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/approle_auth_backend_role) | resource |
| [vault_approle_auth_backend_role_secret_id.cert_manager](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/approle_auth_backend_role_secret_id) | resource |
| [vault_auth_backend.approle_admin](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/auth_backend) | resource |
| [vault_auth_backend.approle_pki](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/auth_backend) | resource |
| [vault_mount.app_secret](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/mount) | resource |
| [vault_mount.pki](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/mount) | resource |
| [vault_namespace.admin](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/namespace) | resource |
| [vault_namespace.app](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/namespace) | resource |
| [vault_namespace.pki](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/namespace) | resource |
| [vault_pki_secret_backend_config_ca.pki](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_config_ca) | resource |
| [vault_pki_secret_backend_intermediate_cert_request.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_intermediate_cert_request) | resource |
| [vault_pki_secret_backend_intermediate_set_signed.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_intermediate_set_signed) | resource |
| [vault_pki_secret_backend_issuer.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_issuer) | resource |
| [vault_pki_secret_backend_key.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_key) | resource |
| [vault_pki_secret_backend_role.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_role) | resource |
| [vault_pki_secret_backend_root_sign_intermediate.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_root_sign_intermediate) | resource |
| [vault_policy.admin](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/policy) | resource |
| [vault_policy.cert_manager](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/policy) | resource |
| [vault_policy.snapshot](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/policy) | resource |
| [aws_secretsmanager_secret.root_ca](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret) | data source |
| [aws_secretsmanager_secret_version.openbao_root_token_secret](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |
| [aws_secretsmanager_secret_version.root_ca](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/secretsmanager_secret_version) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_allowed_cidr_blocks"></a> [allowed\_cidr\_blocks](#input\_allowed\_cidr\_blocks) | List of CIDR blocks allowed to reach Vault's API | `list(string)` | <pre>[<br>  "10.0.0.0/16"<br>]</pre> | no |
| <a name="input_cert_manager_approle_secret_name"></a> [cert\_manager\_approle\_secret\_name](#input\_cert\_manager\_approle\_secret\_name) | The name of the AWS Secrets Manager secret containing the cert-manager AppRole credentials | `string` | n/a | yes |
| <a name="input_domain_name"></a> [domain\_name](#input\_domain\_name) | The domain name for which the certificate should be issued | `string` | n/a | yes |
| <a name="input_openbao_domain_name"></a> [openbao\_domain\_name](#input\_openbao\_domain\_name) | Vault domain name (default: bao.<domain\_name>) | `string` | `""` | no |
| <a name="input_openbao_root_token_secret_id"></a> [openbao\_root\_token\_secret\_id](#input\_openbao\_root\_token\_secret\_id) | The secret ID for the OpenBao root token | `string` | n/a | yes |
| <a name="input_pki_common_name"></a> [pki\_common\_name](#input\_pki\_common\_name) | Common name to identify the Vault issuer | `string` | `"Private PKI - Vault Issuer"` | no |
| <a name="input_pki_country"></a> [pki\_country](#input\_pki\_country) | The country name used for generating certificates | `string` | n/a | yes |
| <a name="input_pki_domains"></a> [pki\_domains](#input\_pki\_domains) | List of domain names that can be used within the certificates | `list(string)` | <pre>[<br>  "cluster.local"<br>]</pre> | no |
| <a name="input_pki_key_bits"></a> [pki\_key\_bits](#input\_pki\_key\_bits) | The number of bits of generated keys | `number` | `256` | no |
| <a name="input_pki_key_type"></a> [pki\_key\_type](#input\_pki\_key\_type) | The generated key type | `string` | `"ec"` | no |
| <a name="input_pki_max_lease_ttl"></a> [pki\_max\_lease\_ttl](#input\_pki\_max\_lease\_ttl) | Maximum TTL (in seconds) that can be requested for certificates (default 3 years) | `number` | `94670856` | no |
| <a name="input_pki_mount_path"></a> [pki\_mount\_path](#input\_pki\_mount\_path) | Vault Issuer PKI mount path | `string` | `"pki_private_issuer"` | no |
| <a name="input_pki_organization"></a> [pki\_organization](#input\_pki\_organization) | The organization name used for generating certificates | `string` | n/a | yes |
| <a name="input_region"></a> [region](#input\_region) | The region to deploy the resources | `string` | n/a | yes |
| <a name="input_root_ca_secret_name"></a> [root\_ca\_secret\_name](#input\_root\_ca\_secret\_name) | The name of the AWS Secrets Manager secret containing the root CA certificate bundle | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_cert_manager_approle_credentials_secret_arn"></a> [cert\_manager\_approle\_credentials\_secret\_arn](#output\_cert\_manager\_approle\_credentials\_secret\_arn) | The ARN of the AWS Secrets Manager secret containing the cert-manager AppRole credentials |
| <a name="output_cert_manager_approle_role_id"></a> [cert\_manager\_approle\_role\_id](#output\_cert\_manager\_approle\_role\_id) | The role ID of the cert-manager AppRole |
<!-- END_TF_DOCS -->