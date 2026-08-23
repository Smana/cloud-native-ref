# S3, matching the AWS stacks: this stack predates any GCP bucket and the
# tailnet is not owned by either cloud. The choice of backend does not make it
# an AWS stack -- it makes it a stack whose state lives where the other state
# already lives.
terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/shared/tailscale/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true
  }
}
