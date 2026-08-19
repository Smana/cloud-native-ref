# Administer the private PKI issuer.
#
# Created in the root namespace, alongside the mount. The `admin` policy used to
# carry `path "pki/*"` and `path "int_pki/*"`; neither named a real mount, and
# while the PKI lived in the `admin/pki` child namespace no path written from
# `admin` could have reached it — a policy binds only within its own namespace.
# Collapsing the platform into root makes co-location the answer.
#
# The mount path below is templated from var.pki_mount_path (escaped here as
# $${pki_mount}) so the policy cannot drift from the mount it governs.

# Issue, sign, revoke, and manage roles, issuers and keys on the mount.
path "${pki_mount}" {
  capabilities = ["read", "list"]
}

path "${pki_mount}/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}

# Rotating an issuer requires sudo on these two.
path "${pki_mount}/root/rotate/*" {
  capabilities = ["create", "update", "sudo"]
}

path "${pki_mount}/issuers/generate/*" {
  capabilities = ["create", "update", "sudo"]
}

# Read and tune the mount's lease TTLs, and list what is mounted here.
path "sys/mounts" {
  capabilities = ["read", "list"]
}

path "sys/mounts/${pki_mount}" {
  capabilities = ["read"]
}

path "sys/mounts/${pki_mount}/tune" {
  capabilities = ["read", "update"]
}

# Inspect and revoke the leases this mount hands out.
path "sys/leases/lookup/${pki_mount}/*" {
  capabilities = ["read", "list"]
}

path "sys/leases/revoke" {
  capabilities = ["create", "update"]
}

path "sys/health" {
  capabilities = ["read"]
}

# Let an operator see and manage their own token.
path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}

path "auth/token/revoke-self" {
  capabilities = ["update"]
}
