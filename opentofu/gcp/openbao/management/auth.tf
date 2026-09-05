# Machine authentication is the JWT method, one mount per cluster, created by
# that cluster's configure stack (opentofu/gcp/gke/configure/openbao.tf) --
# see opentofu/aws/openbao/management/auth.tf for why. The policies those roles
# reference are in policies.tf. The AppRole backend that lived here, with its
# pinned cert-manager role_id and the two Secret Manager entries, is gone: a
# JWT login mints nothing long-lived.
#
# No human auth method on GCP yet; operators use the root token from
# openbao-priv-gcp-root-token, as documented.
