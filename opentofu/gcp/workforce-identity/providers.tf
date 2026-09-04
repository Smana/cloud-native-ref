# No `project` argument: google_iam_workforce_pool and
# google_iam_workforce_pool_provider are ORGANISATION-scoped (parent =
# organizations/<org_id>), not project-scoped, so there is no project to
# default them to. Authenticates via Application Default Credentials, same as
# every other stack.
provider "google" {}
