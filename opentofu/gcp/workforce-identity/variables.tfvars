org_id = "519457084808"

# This id is duplicated (not referenced via remote state -- see opentofu/AGENTS.md's
# per-stack-tfvars note) in Kubernetes RBAC group strings on the consuming
# clusters: a group binding looks like
# `principalSet://iam.googleapis.com/locations/global/workforcePools/ogenki-zitadel/group/<role>`.
# Renaming the pool is delete+create (workforce pools soft-delete for 30 days
# before they purge), and every one of those group strings would go stale the
# moment the rename lands -- so treat this value as permanent.
workforce_pool_id = "ogenki-zitadel"

# Consumed ONLY when this cloud does not host the identity provider, i.e.
# when AWS is primary. When GCP is primary the issuer is derived from
# public_domain_name instead -- see locals in main.tf.
identity_provider_url = "https://auth.cloud.ogenki.io"
public_domain_name    = "gcp.cloud.ogenki.io"
# The `platform` project of the directory in gcp-0's zitadel-20260828 seed.
# A restored directory keeps its ids, so this holds across gcp-0 rebuilds; an
# EMPTY bootstrap gets a new id, and then the audience is reconciled after
# ZITADEL exists by resolve_workforce_audience in
# scripts/provision/zitadel-oidc-clients.sh, and tofu ignores changes to it.
zitadel_project_id = "388252679236747629"
