locals {
  init = data.terraform_remote_state.init.outputs

  cluster_endpoint       = local.init.cluster_endpoint
  cluster_ca_certificate = local.init.cluster_ca_certificate

  # Cilium needs the pod CIDR for ipv4NativeRoutingCIDR, which is MANDATORY under
  # routingMode=native + ipam.mode=kubernetes. Taken from state rather than
  # hardcoded so it cannot drift from the subnet's actual secondary range -- a
  # mismatch would not fail loudly, it would just misroute pod traffic.
  pod_cidr = local.init.pod_cidr

  github_app_secret = jsondecode(data.google_secret_manager_secret_version.flux_github_app.secret_data)
}
