terraform {
  backend "s3" {
    bucket       = "demo-smana-remote-backend"
    key          = "cloud-native-ref/llm-platform/opentofu.tfstate"
    region       = "eu-west-3"
    encrypt      = true
    use_lockfile = true # native S3 locking (.tflock object, no DynamoDB)
  }
}
