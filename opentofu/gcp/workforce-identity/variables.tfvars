org_id = "519457084808"

# This id is duplicated (not referenced via remote state -- see CLAUDE.md's
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
# The AWS-hosted ZITADEL's project id, valid while AWS is primary because
# its rebuilds restore from a seed and keep their ids. On a GCP-primary
# bootstrap this value is WRONG and unknowable in advance; the audience is
# reconciled after ZITADEL exists by resolve_workforce_audience in
# scripts/zitadel-oidc-clients.sh, and tofu ignores changes to it.
zitadel_project_id = "388445486190712688"
