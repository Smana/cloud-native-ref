# GCP trusts ONE AWS role: aws-0's model gateway calls Gemini on Vertex AI with no
# Google key anywhere.
#
# The other direction from main.tf and google-identity.tf, where AWS trusts
# Google-issued tokens. Here a Workload Identity Federation pool trusts the AWS
# account, and its provider admits a single role: the one ai-native-ref's `EPI
# xplane-model-gateway` creates for the gateway's ServiceAccount on aws-0. The
# proxy signs an STS GetCallerIdentity request with that role's Pod Identity
# credentials, Google's STS has AWS verify it, and the federated token calls
# Vertex directly. Design:
# docs/superpowers/specs/2026-11-26-aws-vertex-federation-design.md.
#
# WHY THE AWS PROVIDER TYPE AND NOT AN OIDC PROVIDER ON THE EKS ISSUER: the role
# ARN is stable across an aws-0 rebuild, the EKS issuer URL is not (its ID is
# random per cluster). An OIDC trust would need this stack re-applied after
# every rebuild, and nothing would fail until the first Gemini call.
#
# Gated on `vertex_federation_enabled`: with it off, nothing here uses the
# google provider, so an AWS-only deploy needs no Google credentials.

locals {
  vertex_enabled = var.vertex_federation_enabled ? 1 : 0

  # What the proxy's assumed-role ARN starts with. The trailing slash is the
  # session-name separator, so `xplane-model-gateway-iam-role-other` cannot match.
  model_gateway_assumed_role = "arn:aws:sts::${data.aws_caller_identity.this.account_id}:assumed-role/${var.model_gateway_aws_role_name}"
}

data "google_project" "vertex" {
  count      = local.vertex_enabled
  project_id = var.gcp_project_id
}

resource "google_iam_workload_identity_pool" "aws" {
  count = local.vertex_enabled

  project                   = var.gcp_project_id
  workload_identity_pool_id = "aws-workloads"
  display_name              = "AWS workloads"
  description               = "Federates AWS roles of account ${data.aws_caller_identity.this.account_id}; see opentofu/shared/aws-gcp-federation/vertex.tf"
}

resource "google_iam_workload_identity_pool_provider" "aws" {
  count = local.vertex_enabled

  project                            = var.gcp_project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.aws[0].workload_identity_pool_id
  workload_identity_pool_provider_id = "aws-account"
  display_name                       = "AWS account"

  # Google's default mapping for AWS, written out so the binding below can be
  # read against it: attribute.aws_role drops the session name, leaving
  # arn:aws:sts::<account>:assumed-role/<role>.
  attribute_mapping = {
    "google.subject"     = "assertion.arn"
    "attribute.aws_role" = "assertion.arn.contains('assumed-role') ? assertion.arn.extract('{account_arn}assumed-role/') + 'assumed-role/' + assertion.arn.extract('assumed-role/{role_name}/') : assertion.arn"
  }

  # The membership of the trust: this one role, refused at the pool for every
  # other identity in the account. The binding below names the same role, so
  # either one alone still stops a second role -- a provider added to this pool
  # later inherits no grant it was not given.
  attribute_condition = "assertion.arn.startsWith('${local.model_gateway_assumed_role}/')"

  aws {
    account_id = data.aws_caller_identity.this.account_id
  }
}

# Direct resource access: the federated principal holds the role itself, no
# service account to impersonate, so there is no iamcredentials hop and no key
# that could be created for one.
#
# The role is gke/init's prediction-only custom role (aiplatform.endpoints.predict
# alone). gke/init's destroy keeps its custom roles, so this grant survives a
# gcp-0 teardown -- but the role must exist once: a project that has never run
# gke/init fails this apply with a NOT_FOUND on the role.
resource "google_project_iam_member" "model_gateway_vertex" {
  count = local.vertex_enabled

  project = var.gcp_project_id
  role    = "projects/${var.gcp_project_id}/roles/${var.gcp_vertex_predict_role_id}"
  member  = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.aws[0].name}/attribute.aws_role/${local.model_gateway_assumed_role}"
}
