tailnet     = "smainklh@gmail.com"
admin_users = ["smainklh@gmail.com"]

# Must match opentofu/aws/network vpc_cidr and opentofu/gcp/network's
# advertised_routes output. Re-run the overlap check in the GCP foundation
# plan's Task 3 Step 2 before changing any of these.
advertised_routes = {
  aws = ["10.0.0.0/16"]
  gcp = ["10.10.0.0/16", "100.65.0.0/16", "10.11.0.0/20", "172.16.0.0/28"]
}

search_domains = [
  "eu-west-3.compute.internal",
  "priv.cloud.ogenki.io",
  "priv.gcp.cloud.ogenki.io",
]
