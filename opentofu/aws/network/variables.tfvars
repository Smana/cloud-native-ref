env                 = "dev"
region              = "eu-west-3"
private_domain_name = "priv.cloud.ogenki.io"

tailscale_config = {
  subnet_router_name         = "ogenki"
  tailnet                    = "smainklh@gmail.com"
  prometheus_enabled         = true
  ssm_enabled                = true
  overwrite_existing_content = true
}

tags = {
  project = "cloud-native-ref"
  owner   = "Smana"
}
