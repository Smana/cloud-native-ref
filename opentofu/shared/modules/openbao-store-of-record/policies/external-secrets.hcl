# External Secrets reads platform/ and apps/. It writes NOTHING, anywhere.
#
# Never the `agents` mount (SP2 ruling P38, external review M1): this identity
# backs `openbao-platform`, a ClusterSecretStore any namespace can use (T14).
# scripts/ci/tests/test-openbao-agent-mounts.sh fails if a path here names it.
#
# This is the property that makes per-app ownership mean something. The
# controller reads with its OWN identity, not the requester's, so if it could
# write, anything able to create a namespaced ExternalSecret could launder a
# value into another app's prefix and the per-app human policies would be
# bypassed entirely.
#
# `list` on metadata is what the provider needs to resolve a `dataFrom` extract;
# `read` on data is what serves an ordinary `remoteRef.key`.
#
# The token self-operations at the bottom are also granted by OpenBao's built-in
# `default` policy, which this role carries alongside this one. They are
# repeated here so the policy stands on its own if `default` is ever dropped.

path "platform/data/*" {
  capabilities = ["read"]
}

path "platform/metadata/*" {
  capabilities = ["read", "list"]
}

path "apps/data/*" {
  capabilities = ["read"]
}

path "apps/metadata/*" {
  capabilities = ["read", "list"]
}

path "auth/token/lookup-self" {
  capabilities = ["read"]
}

path "auth/token/renew-self" {
  capabilities = ["update"]
}
