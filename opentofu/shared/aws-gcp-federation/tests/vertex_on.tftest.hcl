# Offline: every provider is mocked, so neither cloud is called. Run from the
# stack: `tofu init -backend=false && tofu test`.
mock_provider "aws" {
  # The provider validates every policy argument as JSON, which a mocked string is not.
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{}" }
  }
  override_data {
    target = data.aws_caller_identity.this
    values = { account_id = "111122223333" }
  }
}
mock_provider "tls" {
  override_data {
    target = data.tls_certificate.gke_oidc
    values = {
      certificates = [{
        sha1_fingerprint     = "0000000000000000000000000000000000000000"
        cert_pem             = ""
        is_ca                = false
        issuer               = ""
        max_path_length      = 0
        not_after            = ""
        not_before           = ""
        public_key_algorithm = ""
        serial_number        = ""
        signature_algorithm  = ""
        subject              = ""
        version              = 3
      }]
    }
  }
}
mock_provider "google" {
  override_data {
    target = data.google_project.vertex
    values = { number = "123456789012" }
  }
}

run "vertex_trusts_the_gateway_role_only" {
  command = apply

  variables {
    vertex_federation_enabled = true
    gcp_project_id            = "fixture-project"
  }

  assert {
    condition     = google_iam_workload_identity_pool_provider.aws[0].aws[0].account_id == "111122223333"
    error_message = "the provider must trust this AWS account, and only it"
  }
  assert {
    condition     = google_iam_workload_identity_pool_provider.aws[0].attribute_condition == "assertion.arn.startsWith('arn:aws:sts::111122223333:assumed-role/xplane-model-gateway-iam-role/')"
    error_message = "the pool must admit the gateway's assumed role alone, session separator included"
  }
  assert {
    condition     = google_project_iam_member.model_gateway_vertex[0].role == "projects/fixture-project/roles/xplane_vertex_predict_v3"
    error_message = "the grant must be gke/init's prediction-only role, never a predefined Vertex role"
  }
  assert {
    condition     = endswith(google_project_iam_member.model_gateway_vertex[0].member, "/attribute.aws_role/arn:aws:sts::111122223333:assumed-role/xplane-model-gateway-iam-role")
    error_message = "the grant must name the gateway role's principalSet, not the whole pool"
  }
  assert {
    condition     = startswith(google_project_iam_member.model_gateway_vertex[0].member, "principalSet://iam.googleapis.com/")
    error_message = "the member must be a federated principalSet"
  }
  assert {
    condition     = output.vertex_wif_audience == "//iam.googleapis.com/projects/123456789012/locations/global/workloadIdentityPools/aws-workloads/providers/aws-account"
    error_message = "the audience must be the provider's full resource name, by project NUMBER"
  }
}

run "role_name_must_be_crossplane_created" {
  command = plan

  variables {
    vertex_federation_enabled   = true
    model_gateway_aws_role_name = "admin"
  }

  expect_failures = [var.model_gateway_aws_role_name]
}
