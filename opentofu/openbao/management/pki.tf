resource "vault_mount" "this" {
  path        = var.pki_mount_path
  type        = "pki"
  description = var.pki_common_name

  default_lease_ttl_seconds = var.pki_max_lease_ttl
  max_lease_ttl_seconds     = var.pki_max_lease_ttl
}

# Generate a key
resource "vault_pki_secret_backend_key" "this" {
  backend  = vault_mount.this.path
  type     = "internal"
  key_type = var.pki_key_type
  key_bits = var.pki_key_bits
  key_name = lower(replace(var.pki_common_name, " ", "-"))
}

# Create a CSR (Certificate Signing Request)
resource "vault_pki_secret_backend_intermediate_cert_request" "this" {
  backend     = vault_mount.this.path
  type        = "existing"
  common_name = var.pki_common_name
  key_ref     = vault_pki_secret_backend_key.this.key_id
}

# Sign our CSR
resource "vault_pki_secret_backend_root_sign_intermediate" "this" {
  backend              = "pki"
  csr                  = vault_pki_secret_backend_intermediate_cert_request.this.csr
  common_name          = var.pki_common_name
  exclude_cn_from_sans = true
  organization         = var.pki_organization
  ttl                  = var.pki_max_lease_ttl
}

# Submits the CA certificate to the PKI Secret Backend.
resource "vault_pki_secret_backend_intermediate_set_signed" "this" {
  backend = vault_mount.this.path
  # Chaining the certificate used by the Vault CA, the intermediate and the root that are both part of the ca-chain.pem file
  certificate = "${vault_pki_secret_backend_root_sign_intermediate.this.certificate}\n${file("${path.module}/.tls/ca-chain.pem")}"
}

resource "vault_pki_secret_backend_issuer" "this" {
  backend     = vault_mount.this.path
  issuer_ref  = vault_pki_secret_backend_intermediate_set_signed.this.imported_issuers[0]
  issuer_name = lower(replace(var.pki_common_name, " ", "-"))
}
