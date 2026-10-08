# merge-gate's namespaced SecretStore reads the `merge-gate` mount and nothing else (SP3 C1, R44).

path "merge-gate/data/*" {
  capabilities = ["read"]
}

path "merge-gate/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
