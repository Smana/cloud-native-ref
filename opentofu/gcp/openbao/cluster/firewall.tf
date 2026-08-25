# Google's health-check probers. Without this the backend service marks every
# instance UNHEALTHY and the forwarding rule blackholes traffic -- with no error
# anywhere except the backend's health status, which nothing surfaces unless you
# go looking.
#
# These two ranges are fixed and documented by Google; they are not our network.
resource "google_compute_firewall" "openbao_health_check" {
  name    = "openbao-${var.env}-health-check"
  project = var.project_id
  network = local.network.network_self_link

  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }

  source_ranges           = ["130.211.0.0/22", "35.191.0.0/16"]
  target_service_accounts = [google_service_account.openbao.email]
}

# Clients reach OpenBao over the tailnet, whose routes the subnet router
# advertises. Scoped to the advertised ranges rather than the whole VPC: the
# GKE nodes are in this network too, and they have no business talking to
# OpenBao's API directly -- their access is via cert-manager, which comes
# through the same tailnet path.
resource "google_compute_firewall" "openbao_api" {
  name    = "openbao-${var.env}-api"
  project = var.project_id
  network = local.network.network_self_link

  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }

  source_ranges           = local.network.advertised_routes
  target_service_accounts = [google_service_account.openbao.email]
}

# IAP TCP forwarding for SSH, OFF by default.
#
# This is the "how do you reach a node whose boot script failed" path. It is
# disabled because the tailnet already reaches the subnet and an always-on admin
# path is a standing exposure. Turn it on for a debugging session, turn it off
# after -- and note that on 2026-08-25 the thing that actually needed debugging
# (a crashlooping openbao.service) was diagnosed entirely from the serial
# console, which needs no firewall rule at all.
resource "google_compute_firewall" "openbao_iap_ssh" {
  count = var.enable_iap_ssh ? 1 : 0

  name    = "openbao-${var.env}-iap-ssh"
  project = var.project_id
  network = local.network.network_self_link

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges           = ["35.235.240.0/20"]
  target_service_accounts = [google_service_account.openbao.email]
}
