# agents-gvisor: GKE Sandbox (native gVisor) for agent runs, gcp-0's half of
# ADR-0041. GKE labels and taints the pool sandbox.gke.io/runtime=gvisor and
# ships the `gvisor` RuntimeClass whose scheduling pins every gVisor pod here, so
# the AgentRun composition names only runtimeClassName on both clouds (GP-9).
#
# A standalone pool on google-beta rather than a module node_pools entry: sandbox
# support differs between the module's beta and GA variants, and this pool must
# not ride on that difference.
resource "google_container_node_pool" "agents_gvisor" {
  provider = google-beta

  project        = var.project_id
  name           = "agents-gvisor"
  cluster        = module.gke.name
  location       = module.gke.location
  node_locations = [local.net.zone]

  initial_node_count = 0
  autoscaling {
    min_node_count  = 0
    max_node_count  = var.agents_pool_max_nodes
    location_policy = "ANY"
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type    = var.agents_pool_machine_type
    image_type      = "COS_CONTAINERD"
    spot            = true
    disk_size_gb    = var.node_disk_size_gb
    disk_type       = "pd-balanced"
    service_account = module.gke.service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
    labels          = local.labels
    metadata = {
      disable-legacy-endpoints = "true"
    }

    sandbox_config {
      sandbox_type = "gvisor"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    # Same as the static pool: nothing schedules before Cilium is ready, and
    # Cilium clears it. GKE adds its own sandbox taint.
    taint {
      key    = "node.cilium.io/agent-not-ready"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  depends_on = [module.gke]
}
