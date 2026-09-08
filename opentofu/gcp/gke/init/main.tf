locals {
  net = data.terraform_remote_state.network.outputs

  labels = merge(
    { environment = var.env },
    var.tags
  )
}

# GKE Standard, private, zonal, self-managed Cilium.
#
# Built on the Cloud Foundation Toolkit module rather than raw google_container_*
# resources, mirroring the AWS side's terraform-aws-modules/eks. Five settings
# below are load-bearing and each is a silent-failure class if it drifts.
# Three accepted trivy findings, all deliberate design decisions:
#
#   GCP-0056 (no network policy) -- Cilium IS the policy engine. Enabling GKE's
#     would put a second enforcer in the datapath, which is the whole thing
#     ADR-0005 exists to avoid.
#   GCP-0052 / GCP-0060 (StackDriver monitoring/logging off) -- VictoriaMetrics and
#     VictoriaLogs already collect this. The GKE defaults bill for a duplicate
#     pipeline nobody reads; this is one of the design's two GCP-only cost levers.
#
# Directives must stay contiguous with the block -- a prose line between them and
# `module` silently voids the ignore.
#   GCP-0057 (node metadata exposed) -- FALSE POSITIVE. The module renders
#     workload_metadata_config through a `dynamic` block driven by
#     var.node_metadata, which trivy cannot resolve statically, so it assumes the
#     insecure default. node_metadata is set to GKE_METADATA below (and is the
#     module default); confirm in the plan output before apply.
#   GCP-0050 (default service account not overridden) -- FALSE POSITIVE, same
#     shape as GCP-0057. The node pools take `local.service_account`, which the
#     module computes as
#       (var.service_account == "" || "create") && var.create_service_account
#         ? local.service_account_list[0] : var.service_account
#     so it renders as `(known after apply)` and trivy assumes the default
#     compute SA. create_service_account defaults to true and we do not override
#     it, so the module creates a DEDICATED least-privilege account. Confirmed in
#     the plan 2026-08-24: google_service_account.cluster_service_account[0] is
#     created, with only metric_writer / node_service_account /
#     resource_metadata_writer bindings -- not Editor.
#
#trivy:ignore:AVD-GCP-0056
#trivy:ignore:AVD-GCP-0052
#trivy:ignore:AVD-GCP-0060
#trivy:ignore:AVD-GCP-0057
#trivy:ignore:AVD-GCP-0050
module "gke" {
  # checkov:skip=CKV_TF_1:Version-pinned like every other registry module here.
  source  = "terraform-google-modules/kubernetes-engine/google//modules/private-cluster"
  version = "~> 45.0"

  project_id = var.project_id
  name       = var.cluster_name

  # ── 1. ZONAL ──────────────────────────────────────────────────────────────
  # regional = false is DESTRUCTIVE to change afterwards (the module says so).
  # Zonal matches design criterion 9 and the AWS bootstrap group's single-subnet
  # choice; a regional Standard cluster defaults to nine nodes, three per zone,
  # and bills node-to-node traffic across zones.
  regional = false
  region   = var.region
  zones    = [local.net.zone]

  network           = local.net.network_name
  subnetwork        = local.net.nodes_subnetwork_name
  ip_range_pods     = local.net.pods_range_name
  ip_range_services = local.net.services_range_name

  kubernetes_version = var.kubernetes_version
  release_channel    = var.release_channel

  # ── 2. DATAPATH: legacy, NOT Dataplane V2 (ADR-0005) ──────────────────────
  # Set explicitly even though it is the module default, because it is CREATE-TIME
  # ONLY -- a later change means cluster replacement. ADVANCED_DATAPATH would
  # replace our Cilium with Google's, which ships no CiliumGatewayClassConfig CRD
  # and no io.cilium/gateway-controller, breaking both Tailscale gateways and the
  # Envoy access-log pipeline into VictoriaLogs.
  datapath_provider = "DATAPATH_PROVIDER_UNSPECIFIED"

  # Cilium is the network policy engine. Leaving GKE's own policy controller on
  # would put a second enforcer in the datapath.
  network_policy = false

  # ── 3. PRIVATE CONTROL PLANE ──────────────────────────────────────────────
  # Reachable only over the tailnet, via the subnet router that advertises
  # control_plane_cidr (owned by the network stack precisely so it can be
  # advertised before this cluster exists).
  enable_private_nodes    = true
  enable_private_endpoint = true
  master_ipv4_cidr_block  = local.net.control_plane_cidr

  master_authorized_networks = [
    {
      cidr_block   = local.net.node_cidr
      display_name = "tailnet-via-subnet-router"
    },
  ]

  # ── 4. WORKLOAD IDENTITY ──────────────────────────────────────────────────
  # "enabled" resolves to the project-based pool <project-id>.svc.id.goog.
  # Gates slice 5 (GCPWorkloadIdentity) entirely.
  identity_namespace = "enabled"

  # Node metadata mode is a MODULE-LEVEL setting, not a per-node-pool one: the
  # module derives it from var.node_metadata and ignores any workload metadata key
  # placed inside node_pools[]. Set explicitly (it happens to be the default)
  # because GCE_METADATA would expose the legacy metadata endpoint to pods and
  # undermine Workload Identity, and because a per-pool key here would look
  # correct while doing nothing.
  node_metadata = "GKE_METADATA"

  cluster_resource_labels = local.labels

  # Cloud Storage FUSE CSI driver. The LLM platform's weights mount depends on
  # this (ADR-0021: Cloud Storage FUSE replaces the S3 Files POSIX mount used on
  # AWS). Inert for now -- gcp-0's LLM stack ships behind a suspended Flux
  # umbrella Kustomization, same gating pattern as aws-0, so nothing mounts
  # through this addon yet. Do not read that as unused.
  gcs_fuse_csi_driver = true

  # ── 5. COST: no duplicate telemetry pipeline ──────────────────────────────
  # VictoriaLogs and VictoriaMetrics already do this job. The GKE defaults bill
  # Cloud Logging and Cloud Monitoring for a pipeline nobody reads. This is one
  # of the two GCP-only cost levers in the design, and it is awkward to retrofit.
  #
  # This is expressed through the *_enabled_components variables, NOT through
  # `logging_service`/`monitoring_service = "none"`, which is what this stack
  # used to say and which silently did nothing. The module:
  #
  #   logmon_config_is_set = length(logging_enabled_components) > 0
  #                       || length(monitoring_enabled_components) > 0
  #                       || monitoring_enable_managed_prometheus != null
  #   logging_service    = logmon_config_is_set ? null : var.logging_service
  #   monitoring_service = logmon_config_is_set ? null : var.monitoring_service
  #
  # Setting `monitoring_enable_managed_prometheus = false` -- the line added to
  # close the Managed Prometheus gap -- makes that local TRUE, which nulls BOTH
  # `_service` fields. Monitoring still came out disabled because a
  # `monitoring_config` block is emitted regardless with an empty
  # componentConfig. Logging did not: the module emits `logging_config` only
  # when `logging_enabled_components` is non-empty, so with the default `[]` no
  # block was written and GKE fell back to its own default.
  #
  # Measured on the live cluster on 2026-08-28, six deploys in:
  #   loggingService: logging.googleapis.com/kubernetes
  #   enableComponents: [SYSTEM_COMPONENTS, WORKLOADS]
  # WORKLOADS is every container log on every node, shipped and billed, next to
  # a VictoriaLogs collecting the same lines. Criterion 10 of the design was
  # never met, and nothing reported it: the plan showed "none" and the cluster
  # ignored it.
  #
  # SYSTEM_COMPONENTS rather than nothing at all, deliberately. `[]` is the
  # module's "do not set this" sentinel, so it cannot express "no logging" --
  # it is what produced this bug. System logs are a small fraction of the
  # volume and are the ones worth having when GKE itself misbehaves; WORKLOADS
  # is the expensive half and is what goes.
  logging_enabled_components = ["SYSTEM_COMPONENTS"]

  # Left at its default `[]`. That is NOT the same sentinel problem as logging:
  # because managed_prometheus below is non-null, a `monitoring_config` block is
  # emitted anyway, and an empty componentConfig inside it means no monitoring.
  # Verified on the cluster: `monitoringService: none`.
  monitoring_enabled_components = []

  # THREE separate toggles, not one -- and this is the one that makes the other
  # two behave as described above. Without it, `monitoring_enable_managed_prometheus`
  # defaults to null, which GKE reads as enabled: the first deploy ran a
  # 3-replica gmp-system/collector DaemonSet plus gke-metrics-agent and a
  # kube-state-metrics StatefulSet -- a full second metrics pipeline alongside
  # VictoriaMetrics.
  monitoring_enable_managed_prometheus = false

  # Must stay false. The module's ip-masq-agent is a kubernetes_config_map, i.e. a
  # call into the very cluster this apply is creating -- the same-apply dependency
  # that opentofu/aws/eks/init/providers.tf documents as unfixable. The module's own
  # description says as much: "IP masquerading uses a kubectl call, so when you
  # have a private cluster, you will need access to the API server."
  # It is also unnecessary here: we use alias IPs, and Cilium owns masquerading.
  configure_ip_masq = false

  remove_default_node_pool = true

  # This is a reference platform that gets rebuilt; deletion protection would make
  # `terramate script run destroy` fail rather than protect anything of value.
  deletion_protection = false

  # ── 6. NODE AUTO-PROVISIONING (ADR-0006) ──────────────────────────────────
  # This is what makes a ComputeClass able to CREATE node pools rather than only
  # select among existing ones. Without it a ComputeClass with
  # nodePoolAutoCreation still schedules, but only onto pools that already exist,
  # so nothing new is ever provisioned and the slice's whole premise is untested.
  #
  # The ceiling is design criterion 16: an oversized workload must stay
  # Unschedulable rather than growing the cluster without bound. Why the specific
  # numbers are what they are lives on the variables in variables.tf.
  #
  # image_type MUST match the static pool's (criterion 14). Cilium's DaemonSet is
  # built around a writable /home/kubernetes/bin on Container-Optimized OS; an
  # auto-created node on a different image would fail the same way the very first
  # GKE deploy did, but only on nodes nobody created by hand.
  #
  # OPTIMIZE_UTILIZATION over BALANCED: criterion 17 wants empty auto-created
  # pools removed on scale-down, and BALANCED is deliberately reluctant to do so.
  # The trade is more pod churn, which is acceptable here and would not be on a
  # latency-sensitive platform.
  cluster_autoscaling = {
    enabled             = true
    autoscaling_profile = "OPTIMIZE_UTILIZATION"

    min_cpu_cores = 0
    max_cpu_cores = var.autoscaling_max_cpu_cores
    min_memory_gb = 0
    max_memory_gb = var.autoscaling_max_memory_gb

    # REQUIRED for the gpu-l4 ComputeClass to provision anything. NAP will not
    # create a node with an accelerator that has no resourceLimits entry, so an
    # empty list here silently caps GPU autoscaling at zero -- the class applies
    # cleanly, pods stay Pending, and nothing says why.
    #
    # nvidia-l4 only, matching the class and the reason europe-west4 was chosen
    # (see opentofu/config.tm.hcl). Maximum 2 is a test-cluster ceiling: L4s are
    # the most expensive thing this repository can provision, and criterion 16
    # wants an oversized workload to stay Unschedulable rather than scale into a
    # bill.
    gpu_resources = [
      {
        resource_type = "nvidia-l4"
        minimum       = 0
        maximum       = 2
      },
    ]

    auto_repair  = true
    auto_upgrade = true

    image_type = var.node_image_type

    # COST. This is a test cluster that gets rebuilt, so the cheap option wins
    # wherever it is not actively misleading.
    #
    # Both of these are otherwise left on module defaults of 100 GB pd-standard
    # -- TWICE the static pool's disk, which is the sort of thing that costs
    # money quietly because nobody set it.
    #
    # 50 GB matches the static pool rather than being an independent guess.
    # pd-standard is the cheapest disk type; the static pool uses pd-balanced,
    # so if auto-created nodes ever behave worse than hand-created ones under
    # image pulls or log writes, this asymmetry is the first thing to look at.
    disk_size = var.node_disk_size_gb
    disk_type = "pd-standard"
  }

  node_pools = [
    {
      name         = "static"
      machine_type = var.node_machine_type
      image_type   = var.node_image_type

      # Spot, matching the EKS bootstrap node group's capacity_type = "SPOT".
      # A GKE node pool takes ONE machine type, so spot interruption risk
      # concentrates on a single shape -- hence a deliberately small pool, with
      # breadth coming later from ComputeClass rather than on-demand fallback.
      spot = true

      node_locations = local.net.zone
      min_count      = var.node_count
      max_count      = var.node_max_count
      initial_count  = var.node_count

      disk_size_gb = var.node_disk_size_gb
      disk_type    = "pd-balanced"

      auto_repair  = true
      auto_upgrade = true
    },
  ]

  node_pools_oauth_scopes = {
    static = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  # ── THE CILIUM TAINT ──────────────────────────────────────────────────────
  # Without it, pods schedule onto a node before the Cilium agent is ready and
  # fail with FailedCreatePodSandBox. Cilium clears the taint once it is up.
  # Slice 4 must reproduce this on every ComputeClass's nodePoolConfig.taints[],
  # which is the single riskiest assumption in the autoscaling design.
  node_pools_taints = {
    all = []
    static = [
      {
        key    = "node.cilium.io/agent-not-ready"
        value  = "true"
        effect = "NO_SCHEDULE"
      },
    ]
  }

  node_pools_labels = {
    all    = local.labels
    static = {}
  }
}
