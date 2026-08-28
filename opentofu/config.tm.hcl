# Global variables that are used in all scripts
# Use your own values for these variables
globals {
  provisioner                      = "tofu"
  region                           = "eu-west-3"
  profile                          = ""
  eks_cluster_name                 = "aws-0"
  openbao_url                      = "https://bao.priv.aws.ogenki.io:8200"
  root_token_secret_name = "openbao/cloud-native-ref/tokens/root"
  # Deliberately a different secret from the root token: the recovery keys are
  # what regenerates a lost or revoked root token, so storing both together
  # would make the pair only as strong as one of them.
  recovery_keys_secret_name        = "openbao/cloud-native-ref/tokens/recovery" # pragma: allowlist secret
  root_ca_secret_name              = "certificates/priv.aws.ogenki.io/root-ca"
  cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"
  cert_manager_approle             = "cert-manager"

  # Helm chart versions for EKS bootstrap
  cilium_version        = "1.20.0"
  flux_operator_version = "0.55.0"
  flux_instance_version = "0.55.0"

  # Gateway API release. Shared for the same reason as cilium_version: Cilium is
  # the GatewayClass implementation, so the CRD set cannot move independently of
  # it, and both clouds install the bundle from opentofu/shared/modules/
  # gateway-api-crds. This must equal flux/sources/gitrepo-gateway-api.yaml's
  # ref.tag -- Flux re-applies the same directory after bootstrap, so a skew
  # installs one CRD set at bootstrap and a different one on reconcile.
  # ./scripts/validate-doc-claims.sh fails when the two disagree.
  gateway_api_version = "v1.6.1"

  # Flux sync configuration
  flux_sync_repository_url = "https://github.com/Smana/cloud-native-ref.git"

  # GCP (dual-cloud — see docs/superpowers/specs/2026-08-18-gcp-support-design.md)
  # `region` and `eks_cluster_name` above are AWS-specific; these are the GCP peers.
  # `cilium_version` and `flux_*_version` are deliberately NOT duplicated: they are
  # shared, so both clouds upgrade together.
  #
  # Zonal, not regional: design criterion 9 keeps the static pool in a single zone,
  # matching the AWS bootstrap node group's single-subnet cost choice. A regional
  # Standard cluster defaults to nine nodes (three per zone) and bills node-to-node
  # traffic across zones.
  #
  # europe-west4 was chosen on GPU availability, not price: nvidia-l4 exists in all
  # three of its zones but not at all in europe-west9 (Paris), which would otherwise
  # have been the geographic match for the AWS eu-west-3 side.
  #
  # There are deliberately NO gcp_project / gcp_region / gcp_zone / gke_cluster_name
  # globals to match `region` and `eks_cluster_name` above. Those two exist because
  # something consumes them: eks-recycle-bootstrap-nodes.sh and the OpenBao
  # workflows take them as script arguments. GCP has no equivalent imperative step,
  # so the same globals were pure duplication -- a third copy of values that already
  # live in each stack's variables.tf defaults and variables.tfvars, and one that
  # nothing would notice going stale.
  #
  # The live values: project/region/zone in opentofu/gcp/network/variables.tfvars,
  # cluster name in opentofu/gcp/gke/init/variables.tfvars. Add a global here when,
  # and only when, a script needs to be handed one.
}
