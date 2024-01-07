# Vault management

This repository leverages the Vault provider in order to configure an existing Vault cluster.

## ✅ Requirements

1. Follow the cluster creation [here](../cluster/README.md)
2. The following files are required and should have been created in the previous step: `intermediate-ca.pem`, `root-ca-key.pem` and `root-ca-key.pem` (⚠️ This latter file is very sensitive, store it in a safe location and delete it as soon as this procedure is completed)

## 🚀 Getting started

1. enable the pki and tune the max TTL to 10 years

```console
vault secrets enable pki
vault secrets tune -max-lease-ttl=315360000 pki
```
2. build and import the full chain bundle

```console
cat .tls/intermediate-ca.pem .tls/root-ca.pem .tls/intermediate-ca-key.pem > .tls/bundle.pem
vault write pki/config/ca pem_bundle=@.tls/bundle.pem
```

3. Prepare your variables.tfvars file. Here is an example:

```hcl
domain_name      = "priv.cloud.ogenki.io"
pki_country      = "France"
pki_organization = "Ogenki"
pki_domains = [
  "cluster.local",
  "priv.cloud.ogenki.io"
]

tags = {
  project = "demo-cloud-native-ref"
  owner   = "Smana"
}
```

4. Run these commands

```console
tofu init
tofu apply -var-file variables.tfvars
```

5. Test by generating a certificate

```console
vault write -format=json pki_private_issuer/issue/Ogenki common_name="foobar.priv.cloud.ogenki.io" ttl="720h" > data.json
jq -r '.data.ca_chain[]' data.json > vault_ca_chain.pem
jq -r '.data.certificate' data.json > foobar-cert.pem
openssl verify -CAfile vault_ca_chain.pem foobar-cert.pem
foobar-cert.pem: OK
```


<!-- BEGINNING OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.4 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | ~> 5.0 |
| <a name="requirement_vault"></a> [vault](#requirement\_vault) | ~> 3.23 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_vault"></a> [vault](#provider\_vault) | ~> 3.23 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [vault_mount.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/mount) | resource |
| [vault_pki_secret_backend_intermediate_cert_request.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_intermediate_cert_request) | resource |
| [vault_pki_secret_backend_intermediate_set_signed.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_intermediate_set_signed) | resource |
| [vault_pki_secret_backend_issuer.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_issuer) | resource |
| [vault_pki_secret_backend_key.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_key) | resource |
| [vault_pki_secret_backend_role.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_role) | resource |
| [vault_pki_secret_backend_root_sign_intermediate.this](https://registry.terraform.io/providers/hashicorp/vault/latest/docs/resources/pki_secret_backend_root_sign_intermediate) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
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
<!-- END OF PRE-COMMIT-TERRAFORM DOCS HOOK -->
