terraform {
  backend "s3" {
    bucket  = "demo-smana-remote-backend"
    key     = "openbao/cluster/terraform.tfstate"
    region  = "eu-west-3"
    encrypt = true
  }
}
