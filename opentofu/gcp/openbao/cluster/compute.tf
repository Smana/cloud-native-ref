# Single-node OpenBao compute: instance template + a one-instance MIG.
#
# Single node on raft, like the AWS stack's "dev" mode. The node's storage is
# derived state: the lineage's newest snapshot is restored into it on every
# deploy (opentofu/gcp/openbao/management/workflows.tm.hcl, rehydrate), so a
# recreated instance is a restore, not a loss. Multi-node raft remains future
# work.

# Ubuntu, not a GCP-native image family such as Container-Optimized OS: the
# boot script installs OpenBao from a signed .deb via dpkg (scripts/startup-
# script.sh), which COS's read-only, container-only root filesystem cannot
# do. Matches the AWS stack, which also boots a Canonical AMI for the same
# reason.
data "google_compute_image" "ubuntu" {
  family  = "ubuntu-2404-lts-amd64"
  project = "ubuntu-os-cloud"
}

resource "google_compute_instance_template" "openbao" {
  name_prefix  = "openbao-${var.env}-"
  project      = var.project_id
  region       = var.region
  machine_type = var.machine_type

  disk {
    source_image = data.google_compute_image.ubuntu.self_link
    auto_delete  = true
    boot         = true
    disk_type    = "pd-balanced"
    # OS + the OpenBao .deb + snap-installed gcloud CLI + logs. Generous on
    # purpose, and not a variable: this is the same OS/binary set on every
    # node, with nothing environment-specific to size for.
    disk_size_gb = 20
  }

  # OpenBao's storage (file backend) and its TLS material live here, not on
  # the boot disk -- so a boot disk replacement (a new image, a template
  # revision) never touches raft/file state. device_name is the contract with
  # scripts/setup-local-disks.sh, which looks for this disk at the stable path
  # /dev/disk/by-id/google-openbao-data.
  #
  # auto_delete = true, matching the AWS dev launch template's
  # delete_on_termination = true on its root volume: this is a single-node,
  # torn-down-every-cycle demo posture, not a deployment with anything on the
  # data disk worth outliving the instance. Revisit before any real HA/raft
  # work, which will need a disk that survives instance replacement.
  disk {
    auto_delete  = true
    boot         = false
    disk_type    = "pd-balanced"
    disk_size_gb = var.data_disk_size_gb
    device_name  = "openbao-data"
  }

  network_interface {
    subnetwork = local.subnetwork_self_link
    # No access_config => no external IP. Matches the network stack's other
    # GCE workload (the Tailscale subnet router): egress goes through Cloud
    # NAT, ingress arrives over the tailnet / internal load balancer (Task 6).
  }

  service_account {
    email = local.lineage.openbao_node_sa_email
    # Broad OAuth scope, narrow IAM: the actual permissions are the two grants
    # in iam.tf (KMS encrypt/decrypt on one key, Secret Manager access on one
    # secret), not this scope. Same pattern as the Tailscale subnet router in
    # opentofu/gcp/network/tailscale.tf.
    scopes = ["cloud-platform"]
  }

  # Measured boot, kernel-signature verification and a virtual TPM. Cheap to
  # enable on the Ubuntu UEFI image and worth it here: this instance holds the
  # OpenBao unseal path and the private PKI's server key material.
  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    # OS Login keeps SSH access on IAM rather than on instance metadata keys.
    enable-oslogin = "TRUE"
    # Belt and braces: OS Login already supersedes metadata keys, but blocking
    # project-wide keys explicitly means a key added at project level can
    # never grant shell on this instance.
    block-project-ssh-keys = "TRUE"
  }

  # setup-local-disks.sh MUST run before startup-script.sh: OpenBao's config
  # (written by the latter) points storage.path at the mount the former
  # creates.
  metadata_startup_script = join("\n", [
    templatefile("${path.module}/scripts/setup-local-disks.sh", {
      openbao_data_path = var.openbao_data_path
    }),
    templatefile("${path.module}/scripts/startup-script.sh", {
      openbao_version         = var.openbao_version
      openbao_data_path       = var.openbao_data_path
      project_id              = var.project_id
      region                  = var.region
      kms_key_ring            = data.google_kms_key_ring.openbao.name
      kms_crypto_key          = data.google_kms_crypto_key.openbao.name
      server_cert_secret_name = var.server_cert_secret_name
      fqdn                    = local.fqdn
      seal_provider           = var.seal_provider
      aws_seal_kms_key_id     = var.aws_seal_kms_key_id
      aws_seal_region         = var.aws_seal_region
      aws_seal_role_arn       = var.aws_seal_role_arn
    }),
  ])

  labels = {
    app         = "openbao"
    environment = var.env
  }

  lifecycle {
    create_before_destroy = true

    precondition {
      condition     = var.seal_provider == "gcpckms" || (var.aws_seal_kms_key_id != "" && var.aws_seal_role_arn != "")
      error_message = "seal_provider = awskms needs aws_seal_kms_key_id and aws_seal_role_arn."
    }
  }
}

resource "google_compute_instance_group_manager" "openbao" {
  name               = "openbao-${var.env}"
  project            = var.project_id
  zone               = var.zone
  base_instance_name = "openbao-${var.env}"

  # Single node -- see the file-header note on why this stack does not run
  # raft/HA. Task 6's backend service (a regional internal load balancer)
  # points at this resource's `instance_group` attribute.
  target_size = 1

  version {
    instance_template = google_compute_instance_template.openbao.id
  }

  named_port {
    name = "https"
    port = 8200
  }

  # Without this, GCP's default OPPORTUNISTIC update policy applies: the MIG
  # adopts a new instance_template but does not replace the running instance.
  # A `tofu apply` that bumps var.openbao_version or edits either boot script
  # would report success while the node keeps running the OLD template
  # indefinitely -- there is no second apply, no drift signal, nothing. AWS
  # hit the analogous trap on its launch template (see
  # opentofu/aws/openbao/cluster/autoscaling_group.tf around
  # `update_default_version = true`); this is the MIG-shaped fix for the same
  # failure mode.
  #
  # max_surge_fixed = 0 because this is a single-node MIG (target_size = 1):
  # there is no second node to surge onto, so the replacement must free the
  # one slot before creating its successor.
  update_policy {
    type                  = "PROACTIVE"
    minimal_action        = "REPLACE"
    max_unavailable_fixed = 1
    max_surge_fixed       = 0
  }

  # NO auto_healing_policies, deliberately -- and this is a reversal worth
  # explaining, because the obvious reading of the incident below is that MIG
  # auto-healing is exactly what was missing.
  #
  # Measured 2026-08-25: a missing IAM permission made openbao.service fail at
  # seal configuration. systemd retried, hit its start limit -- "Start request
  # repeated too quickly" -- and gave up for good. The instance stayed RUNNING,
  # stayed in the MIG, and served nothing. Fixing the IAM changed nothing,
  # because nothing ever tried again; the instance had to be deleted by hand.
  #
  # Auto-healing would have replaced that node. It would also wipe its storage.
  # Auto-healing RECREATEs the instance, the data disk above is
  # `auto_delete = true` with no source, and OpenBao keeps everything in
  # `storage "file"` on it -- so the successor boots with a blank disk that
  # setup-local-disks.sh runs mkfs over. What comes back has no PKI mount and no
  # imported issuer, and the root token in Secret Manager now belongs to a
  # server that no longer exists.
  #
  # Recoverable, though, and less costly than it once was:
  #   - There is no AppRole to lose. cert-manager and the snapshot job now
  #     authenticate through the cluster's JWT mount; the AppRole backend that
  #     used to live here is gone (openbao/management/auth.tf, secrets.tf).
  #   - The mount, the issuer and the root token all come back: the management
  #     stack's deploy runs `openbao-config.sh rehydrate` BEFORE its apply,
  #     restoring the lineage's newest snapshot into the blank node and writing
  #     a fresh root token.
  #
  # What is still lost is everything written since that snapshot -- and, more to
  # the point, nothing triggers a rehydrate on an unattended replacement. The
  # node would sit blank and sealed, serving nothing, until an operator noticed
  # and ran the management deploy.
  #
  # The health check is TCP on 8200 with a 30-second unhealthy threshold
  # (load_balancer.tf), so an OOM on a 2 GB e2-small, or any 30-second stall
  # after initial_delay_sec, would be enough to trigger it. That converts a
  # recoverable "restart the service" into an unattended outage that only an
  # operator-run rehydrate ends, plus the loss of everything written since the
  # last snapshot.
  #
  # The actual root cause was systemd giving up, not the absence of a node
  # replacer -- so it is fixed where it happened: scripts/startup-script.sh
  # installs a drop-in clearing the start limit, and a dead OpenBao now retries
  # forever instead of needing anything to recycle the node.
  #
  # Revisit together with the data disk: once state survives instance
  # replacement (a standalone google_compute_disk, or raft on a persistent
  # volume), auto-healing becomes restorative rather than destructive and should
  # come back.
}
