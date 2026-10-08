# agent-system's namespaced SecretStore reads the `agents` mount and nothing else
# (SP1 S9, SP2 ruling P38). A mount of its own, not platform/agents/*:
# `external-secrets` reads all of platform/ through a ClusterSecretStore any
# namespace can use (T14, review M1).

path "agents/data/*" {
  capabilities = ["read"]
}

path "agents/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
