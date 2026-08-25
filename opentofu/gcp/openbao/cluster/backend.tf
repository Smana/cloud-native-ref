# State lives in S3, not GCS, even though this stack manages GCP resources.
# See opentofu/gcp/network/backend.tf for the full rationale.
#
# NOTE the hardcoded region. It is the S3 BUCKET's region and has nothing to do
# with var.region, which in this stack is a GCP region (europe-west4).
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/gcp/openbao/cluster/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
