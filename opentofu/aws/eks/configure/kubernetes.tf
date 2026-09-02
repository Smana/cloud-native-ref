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
      # See local.storage_class for the value. One shared ConfigMap key with a
      # different value per cloud is honest here -- unlike ${region} was --
      # because both values are consumed as an opaque storageClassName and
      # nothing derives anything else from them.
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

      # Where the platform's identity provider lives.
      #
      # ADR-0024 supersedes ADR-0022: the IdP is deployable on either cloud,
      # defaulting to AWS, so a GCP-only platform is self-sufficient. aws-0
      # hosts it, so the URL is derived from this cluster's own public domain
      # rather than hardcoded -- a cluster that hosts the IdP is always
      # reachable at auth.<its own domain>. gcp-0 runs its own instance and
      # derives its own from deploy_identity_provider; see
      # opentofu/gcp/gke/configure/locals.tf.
      #
      # Consumed by apps/base/openwebui (OIDC discovery) and
      # tooling/base/homepage (a link).
      identity_provider_url = "https://auth.${var.public_domain_name}"
      vpc_id                = data.aws_vpc.selected.id
      vpc_cidr_block        = data.aws_vpc.selected.cidr_block
      # The CIDR holding OpenBao's internal endpoint, consumed by
      # security/base/openbao-snapshot/network-policy.yaml. On AWS that is the
      # whole VPC (the internal NLB's private addresses); on GCP it is the node
      # subnet, where the internal load balancer lives. Same key, different
      # shape per cloud -- which is exactly why the manifest cannot hardcode it.
      openbao_cidr = data.aws_vpc.selected.cidr_block
      # The lineage's snapshot bucket, consumed by
      # security/base/openbao-snapshot/snapshot-cronjob.yaml as BUCKET_NAME.
      # Region-prefixed on AWS, project-prefixed on GCP (GCS names are global
      # and the Crossplane IAM condition keyed on the project prefix), so it is
      # a per-cluster variable rather than a literal in the shared manifest.
      openbao_snapshot_bucket = "${var.region}-ogenki-openbao-snapshot"
      # Secret Manager key for apps/base/ai/llm/hf-token-externalsecret.yaml.
      # PATH-STYLE here because AWS Secrets Manager permits "/"; gcp-0's
      # ConfigMap carries a flat dash-separated ID instead -- ADR-0023.
      llm_hf_token_secret    = "/platform/llm/hf_token" # pragma: allowlist secret
      karpenter_queue_name   = local.karpenter_queue_name
      route53_public_zone_id = data.aws_route53_zone.public.zone_id
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
