# Tailscale subnet router on GCE.
#
# ────────────────────────────────────────────────────────────────────────────
# WHAT THIS STACK DELIBERATELY DOES *NOT* CREATE
#
# Both clouds share ONE tailnet, and several Tailscale resources are tailnet-wide
# singletons owned by opentofu/shared/tailscale -- which belongs to NEITHER cloud:
#
#   tailscale_acl               <- owned by shared/tailscale
#   tailscale_dns_nameservers   <- owned by shared/tailscale
#   tailscale_dns_search_paths  <- owned by shared/tailscale
#
# Declaring any of them here would make two stacks fight: each apply overwrites
# the other's version, silently, last apply winning. That is not hypothetical --
# opentofu/aws/network declared the same three until this PR, and they had
# already diverged, so an AWS apply would have deleted priv.gcp.ogenki.io from
# the tailnet's search paths.
#
# So this stack creates only per-device and per-domain resources: the subnet
# router, its auth key, and the split-DNS entry pointing at a resolver address
# that exists only inside this VPC.
#
# This router's advertised routes are authorised by the shared stack's
# autoApprovers, via its `advertised_routes` map. Adding a CIDR here means adding
# it there too -- and NOT by hand in the admin console, which the next apply of
# the shared stack overwrites.
# ────────────────────────────────────────────────────────────────────────────

# Inbound DNS forwarding, so tailnet clients can resolve the private zone.
#
# A Cloud DNS inbound policy allocates a resolver address INSIDE the node subnet,
# which the subnet router already advertises. That is what makes the split
# nameserver reachable from a laptop.
#
# The obvious-looking alternative -- pointing the split nameserver at the GCE
# metadata resolver 169.254.169.254 -- does NOT work: it is a link-local address,
# so a tailnet client sends the query to its OWN link-local interface rather than
# into the VPC, and *.priv.gcp.ogenki.io silently fails to resolve. The AWS
# side gets this right by using cidrhost(vpc_cidr, 2), which is inside its
# advertised CIDR.
resource "google_dns_policy" "inbound" {
  project                   = var.project_id
  name                      = "${local.network_name}-inbound"
  enable_inbound_forwarding = true

  networks {
    network_url = module.vpc.network_self_link
  }
}

data "google_compute_addresses" "dns_inbound" {
  project = var.project_id
  region  = var.region
  filter  = "purpose = \"DNS_RESOLVER\""

  depends_on = [google_dns_policy.inbound]
}

# Per-domain, keyed by domain name -> no collision with the AWS split nameservers.
resource "tailscale_dns_split_nameservers" "gcp_private" {
  domain = var.private_domain_name
  # The inbound policy allocates one resolver address per subnet in the region;
  # with a single subnet there is exactly one.
  nameservers = [for a in data.google_compute_addresses.dns_inbound.addresses : a.address]
}

resource "tailscale_tailnet_key" "this" {
  reusable      = true
  ephemeral     = false
  preauthorized = true

  # Explicit, long expiry. The provider defaults to 7776000s (90 days) and
  # recreates a reusable key once it becomes invalid -- so at day 90 OpenTofu
  # would mint a fresh key into state while the running instance keeps the old
  # one. The instance would stay up but fail to rejoin on its next reboot, and it
  # is the ONLY administrative path into this VPC.
  expiry = 31536000 # 365 days

  # Alphanumerics, spaces and dashes only. Tailscale's key API rejects other
  # characters with a bare `keys: description had invalid characters (400)` that
  # names neither the offending character nor the field's accepted charset --
  # "GCP subnet router (dev)" failed on the parentheses during the first deploy.
  # The AWS subnet router sets no description at all; this one is kept because it
  # is what distinguishes the two routers' keys in the tailnet admin console.
  description = "GCP subnet router - ${var.env}"
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
    network = module.vpc.network_name

    # Reference the MODULE OUTPUT, not local.subnet_name. The local is a plain
    # string, which creates no dependency edge -- and `network_name` only makes
    # this instance depend on the network, not on the subnet inside it. A fresh
    # apply then races and fails with:
    #
    #   Error 400: Invalid value for field 'networkInterfaces[0].subnetwork':
    #   ... The referenced subnetwork resource cannot be found.
    #
    # Measured on the 2026-08-23 rebuild: the subnet completed at 31s, after the
    # instance had already tried to attach to it. The first deploy happened to
    # win the race, which is exactly what makes this class of bug dangerous --
    # it is intermittent, and passing once proves nothing.
    subnetwork = module.vpc.subnets_names[0]

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

    # The startup script lives HERE rather than in metadata_startup_script, and
    # there is deliberately no `ignore_changes` on it.
    #
    # metadata_startup_script is create-time only, so it was previously paired
    # with ignore_changes to avoid replacing the instance on every edit. That
    # combination silently discarded real changes: adding a CIDR to
    # local.advertised_routes updated nothing -- not by update, not by
    # replacement -- and planned clean. As `metadata`, it updates in place, so a
    # route change reaches the instance on the next boot without replacing it.
    startup-script = templatefile("${path.module}/templates/tailscale-startup.sh.tftpl", {
      auth_key         = tailscale_tailnet_key.this.key
      advertise_routes = join(",", local.advertised_routes)
      hostname         = var.tailscale_config.subnet_router_name
    })
  }

  # Measured boot, kernel-signature verification and a virtual TPM. Cheap to
  # enable on the Debian 12 UEFI image and worth it here: this instance is the
  # single ingress path from the tailnet into the VPC.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  service_account {
    email  = google_service_account.tailscale_subnet_router.email
    scopes = ["cloud-platform"]
  }

  labels = local.labels

  # REQUIRED, and not inferable from any attribute reference. This instance has
  # no external IP, and the startup script installs Tailscale over HTTPS under
  # `set -e`. Without Cloud NAT already programmed the curl fails, the script
  # aborts, and the instance still reports RUNNING -- so the apply SUCCEEDS with a
  # router that never joined the tailnet.
  #
  # Third instance in this stack of a dependency that is real in the API but
  # invisible to the graph; see also google_project_iam_member.crossplane and the
  # subnetwork reference above.
  depends_on = [module.cloud_nat]
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
