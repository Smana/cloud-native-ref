org_id = "519457084808"

# This id is duplicated (not referenced via remote state -- see CLAUDE.md's
# per-stack-tfvars note) in Kubernetes RBAC group strings on the consuming
# clusters: a group binding looks like
# `principalSet://iam.googleapis.com/locations/global/workforcePools/ogenki-zitadel/group/<role>`.
# Renaming the pool is delete+create (workforce pools soft-delete for 30 days
# before they purge), and every one of those group strings would go stale the
# moment the rename lands -- so treat this value as permanent.
workforce_pool_id = "ogenki-zitadel"

identity_provider_url = "https://auth.cloud.ogenki.io"
zitadel_project_id    = "388445486190712688"
