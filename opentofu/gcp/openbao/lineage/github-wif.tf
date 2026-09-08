# GitHub Actions -> GCP, for the weekly restore drill's mirror-freshness check.
# The drill reads the newest object name and size on both sides and asserts
# they match; that needs a listing of this bucket and nothing else.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "github-actions"
  display_name              = "GitHub Actions"
  description               = "Federates GitHub Actions OIDC tokens for ${var.github_repository}"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  # checkov:skip=CKV_GCP_125:False positive. The check wants the trust narrowed to a repository; attribute_condition below pins BOTH assertion.repository and assertion.ref to refs/heads/main, which is stricter than the rule asks. Checkov does not evaluate the interpolated condition.
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only this repository, only main. A fork or a branch presents a different
  # repository/ref and is refused at the pool.
  attribute_condition = "assertion.repository == \"${var.github_repository}\" && assertion.ref == \"refs/heads/main\""

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

resource "google_service_account_iam_member" "drill_wif" {
  service_account_id = google_service_account.openbao_drill.name
  role               = "roles/iam.workloadIdentityUser"

  # `principal://.../subject/<sub>`, not `principalSet://.../attribute.repository/<repo>`.
  #
  # The repository form admits every ref and every pull request in the repo, and
  # leaves the refs/heads/main pin living ONLY in the provider's
  # attribute_condition one level up. That is a single point of failure in two
  # directions: a second provider added to this pool would inherit this binding
  # with no ref constraint at all, and relaxing that one condition would
  # immediately admit every branch and PR to openbao-drill -- which can list the
  # entire snapshot mirror. The subject form pins the same identity the AWS role
  # pins in opentofu/aws/openbao/lineage/github-oidc.tf, so both clouds now
  # express one decision in their own syntax rather than two different ones.
  #
  # COUPLED TO THE WORKFLOW'S `environment:`. GitHub's `sub` is
  # `repo:<repo>:ref:refs/heads/main` only while the drill job declares no
  # environment; adding one changes it to `repo:<repo>:environment:<name>` and
  # this binding stops matching. If the drill is ever scoped to a GitHub
  # environment, this string and the AWS role's `sub` condition move together.
  member = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/repo:${var.github_repository}:ref:refs/heads/main"
}
