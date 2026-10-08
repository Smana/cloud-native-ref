locals {
  init = data.terraform_remote_state.init.outputs

  cluster_endpoint       = local.init.cluster_endpoint
  cluster_ca_certificate = local.init.cluster_ca_certificate

  # Cilium needs the pod CIDR for ipv4NativeRoutingCIDR, which is MANDATORY under
  # routingMode=native + ipam.mode=kubernetes. Taken from state rather than
  # hardcoded so it cannot drift from the subnet's actual secondary range -- a
  # mismatch would not fail loudly, it would just misroute pod traffic.
  pod_cidr = local.init.pod_cidr

  # This cluster's default block-storage class, defined once here so Flux's own
  # artifact PVC and every postBuild-substituted workload PVC cannot disagree.
  # GKE auto-installs the class, so unlike AWS there is no StorageClass object
  # to create here.
  #
  # standard-rwo is pd-balanced, GKE's SSD class and the honest gp3 equivalent --
  # despite the name it is NOT the HDD tier. That is "standard" (pd-standard),
  # which is cheaper and was considered given this platform's
  # tear-down-after-every-run posture, but rejected: the largest consumer is a
  # VictoriaMetrics cluster whose write path is I/O-sensitive, and a reference
  # platform running it on HDD would be unrepresentative of production.
  storage_class = "standard-rwo"

  github_app_secret = jsondecode(data.google_secret_manager_secret_version.flux_github_app.secret_data)

  # The GKE issuer: deterministic from project, location and name, and public.
  # Its JWKS is <issuer>/jwks; EKS's is <issuer>/keys.
  oidc_issuer_url = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${local.init.cluster_location}/clusters/${var.cluster_name}"

  # Hosting the IdP means serving it on THIS cluster's public domain; consuming
  # it means naming whichever cluster does. Derived in one place so the two
  # cannot disagree -- a literal in the vars ConfigMap is what let "which cloud
  # hosts the IdP" become unanswerable from configuration in the first place.
  # See ADR-0024 and the two-gate note on var.deploy_identity_provider.
  identity_provider_url = var.deploy_identity_provider ? "https://auth.${var.public_domain_name}" : var.identity_provider_url

  # The list filter is a substring match; contains() makes it exact.
  zitadel_project_secret_present = var.deploy_identity_provider && contains(
    [for s in try(data.google_secret_manager_secrets.zitadel_project[0].secrets, []) : s.secret_id],
    "zitadel-project-id"
  )
  # Not secret: nonsensitive() keeps the whole ConfigMap out of (sensitive) diffs.
  zitadel_project_id = local.zitadel_project_secret_present ? nonsensitive(jsondecode(data.google_secret_manager_secret_version.zitadel_project[0].secret_data)["project_id"]) : var.zitadel_project_id
}
