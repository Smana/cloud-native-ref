terraform {
  backend "s3" {
    bucket  = "demo-smana-remote-backend"
    key     = "cloud-native-ref/openbao/cluster/opentofu.tfstate"
    region  = "eu-west-3"
    encrypt = true
  }
}
