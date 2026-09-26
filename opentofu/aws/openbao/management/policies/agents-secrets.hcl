# agent-system's namespaced SecretStore reads the agents' own prefix and nothing
# else (SP1 S9). Not `external-secrets`: that identity reads all of platform/ and
# apps/, through a ClusterSecretStore any namespace can use (T14).

path "platform/data/agents/*" {
  capabilities = ["read"]
}

path "platform/metadata/agents/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
