# The A record clients actually use.
#
# This is not cosmetic. OpenBao's server certificate carries
# DNS:bao.priv.gcp.ogenki.io and NO IP SAN, deliberately, so a client connecting
# to the load balancer's address by IP cannot verify TLS. The name is the only
# way in -- which is why this record and the certificate's SAN have to agree
# exactly, and why local.fqdn derives both.
resource "google_dns_record_set" "openbao" {
  project      = var.project_id
  managed_zone = local.network.private_dns_zone_name
  name         = "${local.fqdn}."
  type         = "A"
  ttl          = 60
  rrdatas      = [google_compute_address.openbao.address]
}
