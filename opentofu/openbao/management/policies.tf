# Platform policies live in the root namespace alongside the mounts and auth
# methods they govern. A policy binds only within the namespace it is created
# in, so co-locating them is what makes a single operator login workable.
#
# The previous layout got this wrong in a way that was invisible:
# `vault_namespace.admin.namespace` is the *parent* of `admin` — an empty
# string, i.e. root — so these policies were written to root while the AppRole
# roles referencing them by name were created in `admin`. Policy names resolve
# within the token's own namespace, so `snapshot-agent` tokens carried no
# capabilities at all. `path` and `path_fq` agree for a single-level namespace,
# which is what let it hide.

# Platform administrators
resource "vault_policy" "admin" {
  name   = "admin"
  policy = file("policies/admin.hcl")
}

# Creating snapshots. Grants on `sys/storage/raft/*`, a restricted endpoint
# callable only from the root namespace.
resource "vault_policy" "snapshot" {
  name   = "snapshot"
  policy = file("policies/snapshot.hcl")
}

# Cert manager
resource "vault_policy" "cert_manager" {
  name   = "cert-manager"
  policy = file("policies/cert-manager.hcl")
}

# PKI administration. templatefile rather than file: the paths have to track
# var.pki_mount_path so the policy cannot drift from the mount it governs.
resource "vault_policy" "pki_admin" {
  name = "pki-admin"
  policy = templatefile("policies/pki-admin.hcl", {
    pki_mount = var.pki_mount_path
  })
}

# Tenant policy, created inside the tenant's own namespace.
resource "vault_policy" "app" {
  namespace = vault_namespace.app.path_fq
  name      = "app"
  policy    = file("policies/app.hcl")
}
