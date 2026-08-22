# Tailscale subnet router on GCE.
#
# ────────────────────────────────────────────────────────────────────────────
# WHAT THIS STACK DELIBERATELY DOES *NOT* CREATE
#
# Both clouds share ONE tailnet, and several Tailscale resources are tailnet-wide
# singletons already owned by opentofu/network (the AWS stack):
#
#   tailscale_acl               <- owned by AWS, overwrite_existing_content = true
#   tailscale_dns_nameservers   <- owned by AWS
#   tailscale_dns_search_paths  <- owned by AWS
#
# Declaring any of them here would make the two stacks fight: each apply would
# overwrite the other's version, silently, with the last apply winning. So this
# stack creates only per-device and per-domain resources.
#
# CONSEQUENCE, and it is load-bearing: the AWS-owned ACL currently auto-approves
# and permits ONLY 10.0.0.0/16. Until it also carries the GCP ranges, this
# router's advertised routes stay unapproved and unreachable. Editing the ACL by
# hand does not work either -- the next AWS apply overwrites it. See the plan's
# Task 8 for the required change to opentofu/network/tailscale.tf.
# ────────────────────────────────────────────────────────────────────────────

# Per-domain, keyed by domain name -> no collision with the AWS split nameservers.
# Points the GCP private zone at the VPC's metadata resolver so tailnet devices
# resolve *.priv.gcp.cloud.ogenki.io through this network.
resource "tailscale_dns_split_nameservers" "gcp_private" {
  domain      = var.private_domain_name
  nameservers = ["169.254.169.254"]
}

resource "tailscale_tailnet_key" "this" {
  reusable      = true
  ephemeral     = false
  preauthorized = true
  description   = "GCP subnet router (${var.env})"
}

data "google_compute_image" "debian" {
  family  = "debian-12"
  project = "debian-cloud"
}

resource "google_service_account" "tailscale_subnet_router" {
  account_id   = "tailscale-subnet-router"
  display_name = "Tailscale subnet router (${var.env})"
  project      = var.project_id
}

# Two accepted findings on this instance:
#
#   GCP-0043 (IP forwarding) -- IP forwarding IS the function of a subnet router.
#     Without can_ip_forward the VPC drops every forwarded packet.
#   GCP-0033 (no CMEK on the boot disk) -- Google-managed encryption is the platform
#     default, and the disk holds no state: the auth key arrives via metadata and the
#     routes are re-derived on every boot. A CMEK adds a key to rotate for no gain.
#
# The directives below must stay contiguous with the resource -- trivy attaches an
# inline ignore to the block starting on the next line, so a prose comment in
# between silently voids it.
#trivy:ignore:AVD-GCP-0043
#trivy:ignore:AVD-GCP-0033
resource "google_compute_instance" "tailscale_subnet_router" {
  project      = var.project_id
  name         = var.tailscale_config.subnet_router_name
  machine_type = var.tailscale_config.machine_type
  zone         = var.zone

  # Mandatory for a subnet router: without it the VPC drops any packet whose
  # destination is not the instance itself, so forwarding silently fails even
  # though the tailnet shows the routes as advertised.
  can_ip_forward = true

  boot_disk {
    initialize_params {
      image = data.google_compute_image.debian.self_link
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = module.vpc.network_name
    subnetwork = local.subnet_name
    # No access_config block => no external IP. Egress to the Tailscale
    # coordination server goes through Cloud NAT.
  }

  metadata = {
    # OS Login keeps SSH access on IAM rather than on instance metadata keys.
    enable-oslogin = "TRUE"
    # Belt and braces: OS Login already supersedes metadata keys, but blocking
    # project-wide keys explicitly means a key added at project level can never
    # grant shell on the one host that bridges the tailnet into the VPC.
    block-project-ssh-keys = "TRUE"
  }

  # Measured boot, kernel-signature verification and a virtual TPM. Cheap to
  # enable on the Debian 12 UEFI image and worth it here: this instance is the
  # single ingress path from the tailnet into the VPC.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata_startup_script = templatefile("${path.module}/templates/tailscale-startup.sh.tftpl", {
    auth_key         = tailscale_tailnet_key.this.key
    advertise_routes = join(",", local.advertised_routes)
    hostname         = var.tailscale_config.subnet_router_name
  })

  service_account {
    email  = google_service_account.tailscale_subnet_router.email
    scopes = ["cloud-platform"]
  }

  labels = local.labels

  # The startup script re-runs `tailscale up` idempotently, so a route change
  # does not need instance replacement.
  lifecycle {
    ignore_changes = [metadata_startup_script]
  }
}

# NOTE: there is deliberately no egress firewall rule here.
#
# A GCP VPC carries an implied allow-all egress rule, so an additional ALLOW rule
# for the Tailscale ports would grant nothing that is not already permitted -- it
# would be security theatre that also trips trivy's GCP-0035 for its 0.0.0.0/0
# destination. Real egress control needs a paired low-priority DENY, which is not
# attempted here: the router bootstraps by installing Tailscale over apt and
# HTTPS, and Tailscale itself reaches a changing set of DERP relays, so a deny
# list is fragile in exactly the place where a mistake leaves the VPC with no
# administrative path in. The router also has no external IP -- egress leaves via
# Cloud NAT, which is the actual control point.

# Let traffic forwarded by the subnet router reach the rest of the VPC.
#
# Scoped by SOURCE SERVICE ACCOUNT, not by source range. Tailscale SNATs subnet
# routes by default (--snat-subnet-routes=true), so forwarded packets arrive
# sourced from the router's own VPC address, not from the 100.64.0.0/10 tailnet
# range. Allowing 100.64.0.0/10 would be both wrong (it is not the observed
# source) and far too broad -- the GCP pod range 100.65.0.0/16 sits inside it, so
# it would blanket-allow every pod to reach every VM on every port.
# Five accepted findings on this rule, in two groups.
#
# FALSE POSITIVE on the source (GCP-0027 / 0071 / 0073): this rule has no
#   source_ranges at all -- it is scoped by source_service_accounts to the subnet
#   router alone. Trivy does not model source_service_accounts and so reads the
#   absent source_ranges as 0.0.0.0/0. Nothing on the public internet matches it;
#   GCP requires one of source_ranges / source_tags / source_service_accounts and
#   we supply the last.
#
# INTENTIONAL on the ports (GCP-0072 / 0074): a subnet router forwards arbitrary
#   traffic on behalf of tailnet devices -- kubectl to 443, Hubble, SSH, whatever a
#   future service listens on. Enumerating ports would mean editing this firewall
#   every time a service is added, and the access decision already lives in the
#   tailnet ACL, which is the intended control point.
#
# Keep the directives contiguous with the resource; a prose line between them and
# the `resource` keyword silently voids the ignore.
#trivy:ignore:AVD-GCP-0027
#trivy:ignore:AVD-GCP-0071
#trivy:ignore:AVD-GCP-0073
#trivy:ignore:AVD-GCP-0072
#trivy:ignore:AVD-GCP-0074
resource "google_compute_firewall" "tailscale_ingress" {
  project     = var.project_id
  name        = "${local.network_name}-tailscale-ingress"
  network     = module.vpc.network_name
  direction   = "INGRESS"
  description = "Allow traffic forwarded by the Tailscale subnet router into the VPC"

  allow {
    protocol = "all"
  }

  source_service_accounts = [google_service_account.tailscale_subnet_router.email]
}
