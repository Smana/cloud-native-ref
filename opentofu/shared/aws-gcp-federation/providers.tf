provider "aws" {
  region = var.aws_region
}

# Used by vertex.tf alone. OpenTofu configures a declared provider even when no
# resource uses it, and google's configure looks for Application Default
# Credentials -- so with vertex_federation_enabled off, an AWS-only deploy would
# fail here with no Google account. A placeholder token satisfies configure, and
# with every vertex.tf resource at count 0 nothing ever sends it. Measured offline:
# tests/vertex.tftest.hcl's first run passes with the google provider unmocked
# and GOOGLE_APPLICATION_CREDENTIALS pointing nowhere; without this line it fails.
provider "google" {
  project      = var.gcp_project_id
  access_token = var.vertex_federation_enabled ? null : "vertex-federation-off"
}
