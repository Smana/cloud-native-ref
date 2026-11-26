# Offline, and the google provider is NOT mocked here: with the federation off
# it must not need Google credentials (providers.tf). Proven by running from the
# stack with none to find:
#   GOOGLE_APPLICATION_CREDENTIALS=/nonexistent CLOUDSDK_CONFIG=$(mktemp -d) tofu test
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

run "vertex_off_creates_nothing_on_google" {
  command = plan

  variables {
    vertex_federation_enabled = false
  }

  assert {
    condition     = length(google_iam_workload_identity_pool.aws) == 0 && length(google_project_iam_member.model_gateway_vertex) == 0
    error_message = "with vertex_federation_enabled off, no Google resource may be planned"
  }
  assert {
    condition     = output.vertex_wif_audience == ""
    error_message = "the audience output must be empty when the federation is off"
  }
}
