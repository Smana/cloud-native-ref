provider "google" {
  project = var.project_id
  region  = var.region
}

# The CFT network module declares google-beta in its required_providers, so the
# root module has to configure it even where no beta resource is used directly.
provider "google-beta" {
  project = var.project_id
  region  = var.region
}

provider "tailscale" {
  api_key = var.tailscale_api_key
  tailnet = var.tailscale_config.tailnet
}
