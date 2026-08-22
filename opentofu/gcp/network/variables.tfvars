env        = "dev"
project_id = "ogenki-435905"
region     = "europe-west4"
zone       = "europe-west4-a"

# Verified non-overlapping with the AWS ranges advertised into the same tailnet
# (VPC 10.0.0.0/16, pods 100.64.0.0/16). Re-run the plan's Task 3 Step 2 check
# before changing any of these.
node_cidr          = "10.10.0.0/16"
pod_cidr           = "100.65.0.0/16"
service_cidr       = "10.11.0.0/20"
control_plane_cidr = "172.16.0.0/28"

private_domain_name = "priv.gcp.cloud.ogenki.io"

tailscale_config = {
  subnet_router_name = "ogenki-gcp"
  tailnet            = "smainklh@gmail.com"
  machine_type       = "e2-micro"
}

tags = {
  project = "cloud-native-ref"
  owner   = "smana"
  cloud   = "gcp"
}
