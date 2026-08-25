# Internal passthrough Network LB fronting the OpenBao MIG.
#
# Passthrough (not a proxy) is deliberate: OpenBao terminates TLS itself with a
# certificate issued by the offline root, and a proxying LB would either need
# that private CA in its trust store or terminate TLS with its own certificate.
# A passthrough LB forwards the TCP stream untouched, so the client verifies
# OpenBao's own certificate end to end.
resource "google_compute_address" "openbao" {
  name         = "openbao-${var.env}"
  project      = var.project_id
  region       = var.region
  subnetwork   = local.subnetwork_self_link
  address_type = "INTERNAL"
  purpose      = "GCE_ENDPOINT"
}

# TCP, not HTTPS. An HTTPS health check would have to trust the private CA, and
# the check runs from Google's probers, which have no way to be given it. TCP
# proves the listener is accepting connections, which is what the LB needs to
# decide whether to send traffic; whether OpenBao is sealed is a different
# question and one the LB should not answer -- a sealed node still needs to be
# reachable so an operator can unseal it.
resource "google_compute_health_check" "openbao" {
  name                = "openbao-${var.env}"
  project             = var.project_id
  check_interval_sec  = 10
  timeout_sec         = 5
  healthy_threshold   = 2
  unhealthy_threshold = 3

  tcp_health_check {
    port = 8200
  }
}

resource "google_compute_region_backend_service" "openbao" {
  name                  = "openbao-${var.env}"
  project               = var.project_id
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  protocol              = "TCP"
  health_checks         = [google_compute_health_check.openbao.id]

  # CONNECTION is not a tuning choice — an INTERNAL backend service rejects the
  # provider's default UTILIZATION outright:
  #   Error 400: Invalid value for field 'resource.backends[0].balancingMode':
  #   'UTILIZATION'. Balancing mode must be CONNECTION for an INTERNAL backend
  #   service.
  # Passthrough load balancers distribute connections, not requests, so there is
  # no utilization signal for them to balance on.
  backend {
    group          = google_compute_instance_group_manager.openbao.instance_group
    balancing_mode = "CONNECTION"
  }
}

resource "google_compute_forwarding_rule" "openbao" {
  name                  = "openbao-${var.env}"
  project               = var.project_id
  region                = var.region
  load_balancing_scheme = "INTERNAL"
  ip_protocol           = "TCP"
  ports                 = ["8200"]
  ip_address            = google_compute_address.openbao.id
  subnetwork            = local.subnetwork_self_link
  backend_service       = google_compute_region_backend_service.openbao.id
}
