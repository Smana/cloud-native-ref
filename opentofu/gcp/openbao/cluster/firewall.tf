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
  target_service_accounts = [local.lineage.openbao_node_sa_email]
}

# Everything that talks to OpenBao's API.
#
# Two distinct callers, and it is worth being precise about them because an
# earlier version of this comment claimed the rule excluded GKE. It does not,
# and must not:
#
#   - Operators and the management stack, from tailnet devices. The subnet
#     router SNATs, so that traffic arrives sourced from the router's own
#     address in `node_cidr` -- not from a 100.64/10 tailnet address.
#   - cert-manager, from a POD on gcp-0, reaching the internal LB
#     directly inside the VPC. It never traverses the tailnet.
#
# `advertised_routes` covers both because it is node + pod + service +
# control-plane CIDRs (opentofu/gcp/network/locals.tf). Narrowing this rule to
# exclude the pod range would break every certificate issuance on the cluster,
# with cert-manager reporting a connection timeout that points at OpenBao rather
# than at this rule.
#
# It is still narrower than the VPC: it is a route list, so a subnet added later
# for something unrelated is not admitted by default.
resource "google_compute_firewall" "openbao_api" {
  name    = "openbao-${var.env}-api"
  project = var.project_id
  network = local.network.network_self_link

  allow {
    protocol = "tcp"
    ports    = ["8200"]
  }

  source_ranges           = local.network.advertised_routes
  target_service_accounts = [local.lineage.openbao_node_sa_email]
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
  target_service_accounts = [local.lineage.openbao_node_sa_email]
}
