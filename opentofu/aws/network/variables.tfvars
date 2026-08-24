env                 = "dev"
region              = "eu-west-3"
private_domain_name = "priv.aws.ogenki.io"

# overwrite_existing_content dropped: it only ever gated tailscale_acl, which
# this stack no longer declares. opentofu/shared/tailscale owns the ACL and sets
# that flag itself.
tailscale_config = {
  subnet_router_name = "ogenki"
  tailnet            = "smainklh@gmail.com"
  prometheus_enabled = true
  ssm_enabled        = true
}

tags = {
  project = "cloud-native-ref"
  owner   = "Smana"
}
