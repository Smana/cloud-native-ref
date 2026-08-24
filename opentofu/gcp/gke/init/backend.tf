# State lives in S3, not GCS, even though this stack manages GCP resources.
# See opentofu/gcp/network/backend.tf for the full rationale: the GCS bucket it
# replaced sat inside the very project whose resources it tracked, and one
# bucket means one hand-created bootstrap prerequisite instead of two.
#
# NOTE the hardcoded region. It is the S3 BUCKET's region and has nothing to do
# with var.region, which in this stack is a GCP region (europe-west4).
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/gcp/gke/init/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true # native S3 locking (.tflock object, no DynamoDB)
  }
}
