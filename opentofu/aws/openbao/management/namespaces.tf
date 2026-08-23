# Namespaces are tenancy boundaries, not folders.
#
# The previous layout had `admin`, `admin/pki` and `app`. That used namespaces
# as a directory tree, and it did not hold up:
#
#   - `admin` was a *role*, not a tenant, and cluster-wide operations cannot
#     live there anyway. `sys/storage/raft/*` is a restricted endpoint callable
#     only from root, so the snapshot agent parked in `admin` could never reach
#     it. Audit devices and seal operations are root-only for the same reason.
#   - `admin/pki` held the platform PKI — infrastructure every tenant and every
#     cluster component consumes — nested inside a namespace named after an
#     administrative role, one level down.
#   - The nesting also meant an operator needed one login per namespace, because
#     a policy binds only within the namespace it is created in.
#
# So shared platform services (the PKI, the snapshot agent, operator logins)
# live in the root namespace, and namespaces are reserved for actual tenants.

resource "vault_namespace" "app" {
  path = "app"
}
