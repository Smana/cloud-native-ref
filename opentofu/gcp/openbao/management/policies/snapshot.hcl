# Least privilege for the snapshot agent: one read, on one path. Mirrors
# opentofu/aws/openbao/management/policies/snapshot.hcl exactly -- the raft
# snapshot endpoint is cloud-neutral, so there is nothing here for GCP to
# diverge on.
#
# Note this policy must live in the ROOT namespace: sys/storage/raft/* is a
# restricted endpoint, callable only from root. See the comment on
# vault_approle_auth_backend_role.snapshot in auth.tf.
path "sys/storage/raft/snapshot" {
  capabilities = ["read"]
}
