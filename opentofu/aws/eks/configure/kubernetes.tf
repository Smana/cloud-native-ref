# Cluster-internal bootstrap resources.
#
# These were moved here from eks/init. They must NOT live in the cluster-creating
# stage: there the kubectl/kubernetes providers would be configured from
# module.eks.* outputs that don't exist until the same apply runs, and
# alekc/kubectl cannot defer provider configuration with unknown values
# (fails with "no configuration has been provided, try setting KUBERNETES_MASTER").
# This is the same reason terraform-aws-modules/eks removed the Kubernetes
# provider from the module in v20. Here the cluster already exists
# (data.aws_eks_cluster.this + exec auth), so the providers configure cleanly.

# The Gateway API CRDs moved to gateway_api.tf, which uses the shared module.

# Create flux-system namespace first (required for secrets and ConfigMap)
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

# ConfigMap with cluster variables for Flux substitution
resource "kubectl_manifest" "flux_cluster_vars" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "eks-${var.cluster_name}-vars"
      namespace = "flux-system"
      labels = {
        "reconcile.fluxcd.io/watch" = "Enabled"
      }
    }
    data = {
      cluster_name          = var.cluster_name
      cluster_endpoint      = replace(data.aws_eks_cluster.this.endpoint, "https://", "")
      cluster_endpoint_full = data.aws_eks_cluster.this.endpoint
      oidc_provider_arn     = data.aws_iam_openid_connect_provider.this.arn
      oidc_issuer_url       = local.oidc_issuer_url
      oidc_issuer_host      = local.oidc_issuer_host
      aws_account_id        = data.aws_caller_identity.this.account_id
      region                = var.region
      # The cluster's default block-storage class for PVCs. Shared key name with
      # the GCP ConfigMap, different value: GKE's side is standard-rwo, a class
      # GKE auto-installs. Both are SSD-backed and both are consumed as an
      # opaque string by storageClassName -- nothing derives anything else from
      # it, which is what makes one shared key honest here where ${region} was
      # not (see the workstream 13 design).
      storage_class = local.storage_class
      environment   = var.env
      # `domain_name` used to sit here as a THIRD key holding
      # var.public_domain_name -- the same value as public_domain_name below,
      # under a second name. It was removed rather than kept as a harmless
      # alias, because it was not harmless: gcp-0's ConfigMap never defined it,
      # so every manifest reaching for ${domain_name} was AWS-only by accident
      # rather than by design. observability/base/runlore was excluded from
      # gcp-0 for exactly this reason and nothing else.
      #
      # Flux substitutes an undefined variable to EMPTY, so such a manifest does
      # not fail on GCP -- it renders a hostname with a hole in it. Two keys for
      # one value is how that happens quietly.
      private_domain_name = var.private_domain_name
      public_domain_name  = var.public_domain_name

      # Where the platform's identity provider actually lives.
      #
      # ZITADEL is a SINGLETON: one instance serves both clusters, because two
      # instances would be two user directories, two session stores and two sets
      # of OIDC clients with no federation between them (ADR-0022).
      #
      # aws-0 hosts it today, so here the URL is derived from this cluster's own
      # public domain rather than hardcoded -- a cluster that hosts the IdP is
      # always reachable at auth.<its own domain>. gcp-0 sets the same key to a
      # LITERAL pointing back here; see opentofu/gcp/gke/configure/kubernetes.tf.
      #
      # Consumed by apps/base/openwebui (OIDC discovery) and
      # tooling/base/homepage (a link). Both hardcoded this host until now,
      # which is what made "which cloud hosts the IdP" unanswerable from
      # configuration.
      identity_provider_url = "https://auth.${var.public_domain_name}"
      vpc_id                = data.aws_vpc.selected.id
      vpc_cidr_block        = data.aws_vpc.selected.cidr_block
      # The CIDR holding OpenBao's internal endpoint, consumed by
      # security/base/openbao-snapshot/network-policy.yaml. On AWS that is the
      # whole VPC (the internal NLB's private addresses); on GCP it is the node
      # subnet, where the internal load balancer lives. Same key, different
      # shape per cloud -- which is exactly why the manifest cannot hardcode it.
      openbao_cidr = data.aws_vpc.selected.cidr_block
      # security/base/openbao-snapshot/external-secrets.yaml's Secret Manager
      # key. Path-style here because AWS Secrets Manager allows "/"; GCP's
      # ConfigMap (opentofu/gcp/gke/configure/kubernetes.tf) carries a flat
      # dash-separated ID instead, because GCP Secret Manager forbids "/".
      # Same key, different shape per cloud -- see opentofu/gcp/openbao/management's
      # snapshot_approle_secret_name (Task 14).
      openbao_snapshot_secret = "security/openbao/openbao-snapshot" # pragma: allowlist secret
      # apps/base/ai/llm/hf-token-externalsecret.yaml's Secret Manager key.
      # Path-style here because AWS Secrets Manager allows "/"; GCP's
      # ConfigMap (opentofu/gcp/gke/configure/kubernetes.tf) carries a flat
      # dash-separated ID instead, because GCP Secret Manager forbids "/".
      # Same key, different shape per cloud -- same split as
      # openbao_snapshot_secret above, same reason (Task 14).
      llm_hf_token_secret    = "/platform/llm/hf_token" # pragma: allowlist secret
      karpenter_queue_name   = local.karpenter_queue_name
      route53_public_zone_id = data.aws_route53_zone.public.zone_id
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

# Create secrets using kubectl_manifest instead of kubernetes_secret
# to avoid plan-time validation issues with the kubernetes provider
resource "kubectl_manifest" "flux_cert_manager_approle" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = "cert-manager-openbao-approle"
      namespace = "flux-system"
    }
    type = "Opaque"
    data = {
      cert_manager_approle_id     = base64encode(local.cert_manager_approle.cert_manager_approle_id)
      cert_manager_approle_secret = base64encode(local.cert_manager_approle.cert_manager_approle_secret)
    }
  })
  server_side_apply = true
  depends_on        = [kubectl_manifest.flux_system_namespace]
}

resource "kubectl_manifest" "flux_system_secret" {
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
  depends_on        = [kubectl_manifest.flux_system_namespace]

  # The GitHub App private key is rendered into yaml_body, so without this it
  # appears unredacted in every plan diff and in the S3 state object.
  #
  # Added alongside the GCP equivalent rather than after it: both stacks build the
  # same Secret from the same kind of source, and carrying the field on only one
  # of them is how a fix stops travelling between two copies of one bootstrap.
  sensitive_fields = ["data"]
}

# gp3 StorageClass (default) - EBS CSI Driver is deployed as EKS managed add-on
resource "kubectl_manifest" "gp3_storageclass" {
  yaml_body         = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: ${local.storage_class}
      annotations:
        storageclass.kubernetes.io/is-default-class: "true"
    provisioner: ebs.csi.aws.com
    allowVolumeExpansion: true
    reclaimPolicy: Delete
    volumeBindingMode: WaitForFirstConsumer
    parameters:
      encrypted: "true"
      fsType: ext4
      type: gp3
  YAML
  server_side_apply = true
}

# Remove gp2 as default StorageClass
resource "kubectl_manifest" "gp2_not_default" {
  yaml_body         = <<-YAML
    apiVersion: storage.k8s.io/v1
    kind: StorageClass
    metadata:
      name: gp2
      annotations:
        storageclass.kubernetes.io/is-default-class: "false"
    provisioner: kubernetes.io/aws-ebs
    parameters:
      type: gp2
      fsType: ext4
    volumeBindingMode: WaitForFirstConsumer
  YAML
  server_side_apply = true
}
