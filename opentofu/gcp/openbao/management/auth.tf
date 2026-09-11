# Machine authentication is the JWT method, one mount per cluster, created by
# that cluster's configure stack (opentofu/gcp/gke/configure/openbao.tf) --
# see opentofu/aws/openbao/management/auth.tf for why. The policies those roles
# reference are in policies.tf. The AppRole backend that lived here, with its
# pinned cert-manager role_id and the two Secret Manager entries, is gone: a
# JWT login mints nothing long-lived.
#
# Human logins -- the userpass break-glass and the ZITADEL OIDC method -- come
# from the shared module (store-of-record.tf). The break-glass password is
# published to openbao-priv-gcp-admin-credentials.
