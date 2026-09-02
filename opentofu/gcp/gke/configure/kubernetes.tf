# Cluster-specific values for Flux postBuild substitution.
#
# This is how cluster-specific config reaches shared manifests: anything under
# infrastructure/, security/ or observability/ that writes `${cluster_name}`,
# `${region}`, `${private_domain_name}` and friends is rendered per cluster from
# this ConfigMap, via `postBuild.substituteFrom` on the consuming Kustomization.
#
# The CLOUD-NEUTRAL keys below deliberately match the names the AWS ConfigMap
# (eks-<cluster>-vars) uses -- cluster_name, cluster_endpoint, region,
# environment, private_domain_name. That is what lets one manifest under
# infrastructure/base/ render correctly on either cloud. Renaming them here would
# silently break shared manifests on GCP only.
#
# AWS-only keys mostly stay absent (aws_account_id, oidc_provider_arn, vpc_id,
# karpenter_queue_name). The manifests that use them are AWS-specific and are
# excluded from clusters/gcp-0. If a shared manifest ever needs one, the right
# fix is a cloud-neutral name provided by both ConfigMaps, not an AWS name faked
# on GCP.
#
# route53_public_zone_id, route53_role_arn and route53_region are the
# deliberate exception: AWS values in a GCP ConfigMap on
# purpose, because cloud.ogenki.io is one Route53 zone BOTH clusters write to
# (ADR-0017, ADR-0019). route53_public_zone_id matches the key name the AWS
# ConfigMap uses for that same zone; route53_role_arn has no AWS counterpart
# because aws-0 reaches Route53 with ambient EKS Pod Identity credentials, not
# federation. route53_region is deliberately its own key rather than a reuse
# of the cloud-neutral `region` above -- that one holds gcp-0's GCP region,
# and feeding it to the AWS SDK as an AssumeRoleWithWebIdentity credential-scope
# hint breaks the token exchange this federation depends on. See the comment
# on var.route53_region.
#
# public_domain_name is NOT the exception above -- it is GCP-only in VALUE
# (gcp.cloud.ogenki.io, not cloud.ogenki.io) even though it shares a variable
# name with the AWS side. Both clusters write into the same zone, but each
# requests a different name within it, so aws-0's live *.cloud.ogenki.io
# wildcard Certificate and gcp-0's do not share a Let's Encrypt
# duplicate-certificate bucket or a `_acme-challenge` TXT record. See the
# comment on var.public_domain_name and ADR-0019.
resource "kubectl_manifest" "flux_cluster_vars" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "gke-${var.cluster_name}-vars"
      namespace = "flux-system"
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
    }
    data = {
      # Cloud-neutral — names shared with the AWS ConfigMap.
      cluster_name        = var.cluster_name
      cluster_endpoint    = local.cluster_endpoint
      environment         = var.env
      region              = var.region
      private_domain_name = local.init.private_domain_name
      # See local.storage_class for why standard-rwo. Same local feeds Flux's
      # own artifact PVC, so the two cannot disagree.
      storage_class = local.storage_class

      # GCP-specific.
      project_id     = var.project_id
      project_number = local.init.project_number
      zone           = local.init.cluster_location
      workload_pool  = local.init.workload_pool
      network_name   = local.init.network_name
      node_cidr      = local.init.node_cidr
      pod_cidr       = local.pod_cidr
      service_cidr   = local.init.service_cidr
      # OpenBao's internal load balancer sits in the node subnet on GCP
      # (opentofu/gcp/openbao/cluster/load_balancer.tf uses
      # local.subnetwork_self_link, whose range is var.node_cidr) -- unlike
      # AWS, where it's the whole VPC. Same key as the AWS ConfigMap, same
      # value as node_cidr above, consumed by
      # security/base/openbao-snapshot/network-policy.yaml.
      openbao_cidr = local.init.node_cidr
      # Secret Manager keys for the two ExternalSecrets that need one:
      # security/base/openbao-snapshot/external-secrets.yaml and
      # apps/base/ai/llm/hf-token-externalsecret.yaml. Both are FLAT and
      # dash-separated, unlike the AWS ConfigMap's path-style values, because
      # GCP Secret Manager forbids "/" in a secret ID -- ADR-0023. The first
      # must match opentofu/gcp/openbao/management's
      # snapshot_approle_secret_name.
      #
      # llm_hf_token_secret is only required if the LLM platform is enabled on
      # this cluster (clusters/gcp-0/llm-platform.yaml), and is a hand-created
      # entry like the other gcp-bootstrap.md prerequisites -- not provisioned
      # by OpenTofu on either cloud.
      openbao_snapshot_secret = "openbao-priv-gcp-snapshot" # pragma: allowlist secret
      llm_hf_token_secret     = "llm-platform-hf-token"     # pragma: allowlist secret

      # Public DNS, for the federated Route53 path.
      # public_domain_name is gcp.cloud.ogenki.io -- gcp-0's OWN subdomain of
      # the shared zone, not the same name aws-0 uses. The other three are AWS
      # values in a GCP ConfigMap on purpose: both clusters write into one
      # Route53 zone, which is what ADR-0017 and ADR-0019 decided. See the
      # header comment above for why the name itself still differs per cloud.
      public_domain_name     = var.public_domain_name
      route53_public_zone_id = var.route53_public_zone_id
      route53_role_arn       = var.route53_role_arn
      route53_region         = var.route53_region

      # The platform's identity provider, which this cluster may either HOST or
      # CONSUME. ADR-0024 supersedes ADR-0022: the IdP is deployable on either
      # cloud, default AWS, so a GCP-only platform is self-sufficient rather
      # than dependent on an AWS cluster being up to log anyone in.
      #
      # Derived rather than hand-set, because the two halves of that choice must
      # agree and a literal is what let them drift:
      #
      #   deploy_identity_provider = true   -> auth.<this cluster's public domain>
      #   deploy_identity_provider = false  -> var.identity_provider_url, whose
      #                                       default names the aws-0 instance
      #
      # Setting it true while leaving the Flux Kustomization suspended points
      # every consumer at a hostname this cluster does not serve, which is why
      # local.identity_provider_url is computed in one place and both halves are
      # documented together in variables.tf.
      identity_provider_url = local.identity_provider_url

      # Workforce pool federating ZITADEL (opentofu/gcp/workforce-identity).
      # Consumed by security/gcp-0/rbac -- the RBAC binding's group name embeds
      # this pool id. Must be present, or Flux substitutes an empty string and
      # produces a binding matching nobody. See var.workforce_pool_id.
      workforce_pool_id = var.workforce_pool_id

      # Same reasoning as workforce_pool_id, for the other half of the exchange.
      # The workforce provider pins its audience to the ZITADEL PROJECT id, and
      # ZITADEL only puts that id in a token's `aud` when the token was
      # REQUESTED with the matching project-audience scope -- so oauth2-proxy's
      # scope has to name it. Substituting it means a rename is caught by
      # check-substitution.py instead of surfacing as a bare `invalid_grant`
      # with oauth2-proxy, the exchange proxy and Headlamp all reporting healthy.
      zitadel_project_id = var.zitadel_project_id
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

resource "kubectl_manifest" "flux_system_namespace" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Namespace"
    metadata = {
      name = "flux-system"
    }
  })
  server_side_apply = true
}

# Flux's Git credentials. Sourced from GCP Secret Manager (see data.tf) so the GCP
# bootstrap has no AWS dependency.
resource "kubectl_manifest" "flux_system_secret" {
  depends_on = [kubectl_manifest.flux_system_namespace]

  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "flux-system"
      namespace = "flux-system"
    }
    type = "Opaque"
    data = {
      for key, value in local.github_app_secret :
      key => base64encode(value)
    }
  })
  server_side_apply = true

  # The GitHub App private key is rendered into yaml_body, so without this it
  # appears unredacted in every plan diff and in the S3 state object.
  #
  # data.tf's comment says the secret is "deliberately NOT in OpenTofu" -- that is
  # true of its CREATION (we do not manage the Secret Manager entry) but NOT of
  # its value, which flows through this resource. Marking the field is what makes
  # the two statements consistent.
  sensitive_fields = ["data"]
}
