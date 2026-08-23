# The project NUMBER, derived rather than hand-maintained.
#
# It was previously a required variable duplicating a value GCP already knows.
# That is exactly the kind of hand-copied identifier this stack's own comments
# warn about: the number and the ID are not interchangeable, they sit in
# different segments of the Workload Identity principal string, and reversing or
# mistyping one yields a binding the API accepts and that never matches.
# Deriving it removes the opportunity for that mistake entirely.
data "google_project" "this" {
  project_id = var.project_id
}

# The network stack owns the VPC, the secondary range NAMES that GKE binds to,
# the zone, and the control-plane CIDR (which the subnet router must advertise
# before this cluster exists). Consuming its state keeps one source of truth: a
# secondary range renamed here rather than there would force cluster replacement.
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = "demo-smana-remote-backend"
    key    = "cloud-native-ref/gcp/network/opentofu.tfstate"
    # Literal, NOT var.region: this is the S3 bucket's region, while var.region
    # in this stack is a GCP region (europe-west4). The AWS stacks pass
    # var.region here because for them the two happen to coincide.
    region = "eu-west-3"
  }
}
