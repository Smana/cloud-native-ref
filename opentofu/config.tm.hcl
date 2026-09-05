# Global variables that are used in all scripts
# Use your own values for these variables
globals {
  # Not `tofu` directly -- a wrapper that gates on TM_CLOUD, then execs tofu.
  # See scripts/tm-provisioner.sh for why the cloud selector lives here rather
  # than in a flag or a tag: this is the one point every stack reaches OpenTofu
  # through, so intercepting it covers the global scripts and every per-stack
  # override at once, without wrapping commands in bash and losing Terramate
  # Cloud's sync annotations.
  provisioner = "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh"

  # Which lane a stack belongs to, read from its own tags. Anything tagged
  # neither `aws` nor `gcp` -- shared/tailscale, shared/aws-gcp-federation -- is
  # owned by neither cloud and always runs.
  stack_cloud = tm_contains(terramate.stack.tags, "gcp") ? "gcp" : (tm_contains(terramate.stack.tags, "aws") ? "aws" : "shared")

  # The same gate, for jobs that run something other than tofu -- gcloud, a repo
  # script, a bash heredoc. Interpolated as `${global.cloud_gate}` at the top of
  # such a job, because each Terramate job is its own bash process and the check
  # cannot be hoisted to the script or stack level.
  #
  # It delegates rather than restating the rule: the previous gate was fifteen
  # hand-copied blocks, and four scripts ended up missing one entirely.
  cloud_gate = <<-EOT
    "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh" --tm-check ${global.stack_cloud} || {
      echo "[skip] ${global.stack_cloud} stack — TM_CLOUD=$${TM_CLOUD:-aws} does not include it."
      echo "       Set TM_CLOUD=${global.stack_cloud}, a list like aws,gcp, or all."
      exit 0
    }
  EOT

  region           = "eu-west-3"
  profile          = ""
  eks_cluster_name = "aws-0"

  # Which cloud hosts the services that cannot sensibly exist twice: the public
  # DNS zone, the cross-cloud federation trust, and ZITADEL (ADR-0027).
  #
  # Changing this is a MIGRATION, not a toggle. The identity provider's database
  # seed, admin credential and OIDC clients travel with it or the move
  # half-works in silence -- which is why placement is stated here once and
  # never derived from TM_CLOUD, whose value changes per invocation.
  #
  # Enforced by ./scripts/validate-idp-topology.sh.
  primary_cloud = "aws"

  # Whether the GCP lane hosts the identity provider, derived once rather than
  # compared at each call site. Five sites need it -- deploy, preview, destroy
  # and drift in gcp/gke/configure, plus the OIDC-client registration in
  # gcp/gke/init -- and the same file's `cloud_gate` above records what happens
  # when a rule is hand-copied instead: "the previous gate was fifteen
  # hand-copied blocks, and four scripts ended up missing one entirely."
  #
  # A third cloud, or any change to what makes a lane eligible to host, is then
  # one edit here rather than a hunt across two files.
  deploy_identity_provider_gcp = global.primary_cloud == "gcp"
  openbao_url                  = "https://bao.priv.aws.ogenki.io:8200"
  root_token_secret_name       = "openbao/cloud-native-ref/tokens/root"
  # Deliberately a different secret from the root token: the recovery keys are
  # what regenerates a lost or revoked root token, so storing both together
  # would make the pair only as strong as one of them.
  recovery_keys_secret_name        = "openbao/cloud-native-ref/tokens/recovery" # pragma: allowlist secret
  root_ca_secret_name              = "certificates/priv.aws.ogenki.io/root-ca"
  cert_manager_approle_secret_name = "openbao/cloud-native-ref/approles/cert-manager"
  cert_manager_approle             = "cert-manager"

  # Helm chart versions for EKS bootstrap
  cilium_version        = "1.20.1"
  flux_operator_version = "0.59.0"
  flux_instance_version = "0.59.0"

  # Gateway API release. Shared for the same reason as cilium_version: Cilium is
  # the GatewayClass implementation, so the CRD set cannot move independently of
  # it, and both clouds install the bundle from opentofu/shared/modules/
  # gateway-api-crds. This must equal flux/sources/gitrepo-gateway-api.yaml's
  # ref.tag -- Flux re-applies the same directory after bootstrap, so a skew
  # installs one CRD set at bootstrap and a different one on reconcile.
  # ./scripts/validate-doc-claims.sh fails when the two disagree.
  gateway_api_version = "v1.6.2"

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
