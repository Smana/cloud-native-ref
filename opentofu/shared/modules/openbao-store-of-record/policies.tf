# Platform administrators. Grants no secret path on its own; secrets-admin does.
resource "vault_policy" "admin" {
  name   = "admin"
  policy = file("${path.module}/policies/admin.hcl")
}

# PKI administration, templated so it tracks the mount it governs.
resource "vault_policy" "pki_admin" {
  name = "pki-admin"
  policy = templatefile("${path.module}/policies/pki-admin.hcl", {
    pki_mount = var.pki_mount_path
  })
}

# Full control of both Stage 2 mounts: the break-glass login and openbao-admin.
resource "vault_policy" "secrets_admin" {
  name   = "secrets-admin"
  policy = file("${path.module}/policies/secrets-admin.hcl")
}

# External Secrets' read-only identity over both mounts. Attached by NAME to
# the per-cluster JWT role in each cluster's configure stack -- a different
# state -- so the name must stay `external-secrets` in both places.
# scripts/validate-openbao-policies.sh enforces that pairing.
resource "vault_policy" "external_secrets" {
  name   = "external-secrets"
  policy = file("${path.module}/policies/external-secrets.hcl")
}
