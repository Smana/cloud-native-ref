# S3, like opentofu/shared/tailscale: this stack's resources live in AWS and
# its state belongs with the other shared state. ADR-0018 moved GCP stacks to
# GCS because they manage GCP; this one manages AWS IAM.
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/shared/aws-gcp-federation/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
