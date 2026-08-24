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
#
#trivy:ignore:AVD-GCP-0056
#trivy:ignore:AVD-GCP-0052
#trivy:ignore:AVD-GCP-0060
#trivy:ignore:AVD-GCP-0057
module "gke" {
  # checkov:skip=CKV_TF_1:Version-pinned like every other registry module here.
  source  = "terraform-google-modules/kubernetes-engine/google//modules/private-cluster"
  version = "~> 44.3"

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

  # ── 5. COST: no duplicate telemetry pipeline ──────────────────────────────
  # VictoriaLogs and VictoriaMetrics already do this job. The GKE defaults bill
  # Cloud Logging and Cloud Monitoring for a pipeline nobody reads. This is one
  # of the two GCP-only cost levers in the design, and it is awkward to retrofit.
  logging_service    = "none"
  monitoring_service = "none"

  # THREE separate toggles, not one. Setting only the two above leaves Google
  # Managed Prometheus collecting and billing: `monitoring_enable_managed_prometheus`
  # defaults to null, which GKE reads as enabled.
  #
  # Measured on the first deploy: with logging_service and monitoring_service
  # already "none", the cluster still ran a 3-replica gmp-system/collector
  # DaemonSet plus gke-metrics-agent and a kube-state-metrics StatefulSet --
  # a full second metrics pipeline alongside VictoriaMetrics, which is exactly
  # the duplicate the design's cost lever exists to remove.
  #
  # Criterion 10 ("workload Cloud Logging AND Monitoring disabled") is not met
  # without this line; verifying it in the plan output is not enough, because the
  # plan shows the two services as "none" and says nothing about GMP.
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
  # Unschedulable rather than growing the cluster without bound. It is set low on
  # purpose -- this is a reference platform, and the failure mode of a too-high
  # limit is a bill rather than an error.
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
