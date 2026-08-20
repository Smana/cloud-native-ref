resource "vault_mount" "pki" {
  path        = var.pki_mount_path
  type        = "pki"
  description = var.pki_common_name

  default_lease_ttl_seconds = var.pki_max_lease_ttl
  max_lease_ttl_seconds     = var.pki_max_lease_ttl
}

# Configure PKI with the root CA
resource "vault_pki_secret_backend_config_ca" "pki" {
  backend    = vault_mount.pki.path
  pem_bundle = jsondecode(data.aws_secretsmanager_secret_version.root_ca.secret_string).bundle
}

# Generate a key
resource "vault_pki_secret_backend_key" "this" {
  backend  = vault_mount.pki.path
  type     = "internal"
  key_type = var.pki_key_type
  key_bits = var.pki_key_bits
  key_name = lower(replace(var.pki_common_name, " ", "-"))
}

# Create a CSR (Certificate Signing Request)
resource "vault_pki_secret_backend_intermediate_cert_request" "this" {
  backend     = vault_mount.pki.path
  type        = "existing"
  common_name = var.pki_common_name
  key_ref     = vault_pki_secret_backend_key.this.key_id
}

# Sign our CSR
resource "vault_pki_secret_backend_root_sign_intermediate" "this" {
  # Ordering here was previously luck. Nothing tied this to config_ca, so the
  # graph was free to call root/sign-intermediate before the root CA bundle had
  # been imported into the mount. At the old default parallelism the two raced
  # and config_ca happened to win; serialising the stack (-parallelism=1, see
  # workflows.tm.hcl) made Terraform pick the other order and it failed with
  # `no default issuer currently configured` (HTTP 500).
  depends_on = [vault_pki_secret_backend_config_ca.pki]

  backend              = vault_mount.pki.path
  csr                  = vault_pki_secret_backend_intermediate_cert_request.this.csr
  common_name          = var.pki_common_name
  exclude_cn_from_sans = true
  organization         = var.pki_organization
  ttl                  = var.pki_max_lease_ttl
}

# Submits the CA certificate to the PKI Secret Backend.
resource "vault_pki_secret_backend_intermediate_set_signed" "this" {
  backend = vault_mount.pki.path
  # Chaining the certificate used by the Vault CA, the intermediate and the root that are both part of the ca-chain.pem file
  certificate = "${vault_pki_secret_backend_root_sign_intermediate.this.certificate}\n${jsondecode(data.aws_secretsmanager_secret_version.root_ca.secret_string).ca}"
}

resource "vault_pki_secret_backend_issuer" "this" {
  backend     = vault_mount.pki.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.this.imported_issuers[0]
  issuer_name = lower(replace(var.pki_common_name, " ", "-"))
}
