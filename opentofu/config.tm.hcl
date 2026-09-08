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

  # The AWS NLB's fixed private address in the first private subnet, used only
  # as a fallback when `bao.priv.aws.ogenki.io` does not resolve. A teardown
  # removes that record while the node is still serving, which is precisely when
  # the pre-destroy snapshot needs to reach it (measured 2026-09-05: dig empty,
  # the same request to this address returned 200).
  #
  # This is the SAME contract as `openbao_target_ip` in gcp/gke/configure, and
  # the same one load_balancer.tf's `cidrhost(cidr, -6)` comment calls out: move
  # the offset and both values move with it. Only used to connect -- TLS still
  # verifies the hostname, because the certificate carries no IP SAN.
  openbao_fallback_address = "10.0.15.250"

  root_token_secret_name = "openbao/cloud-native-ref/tokens/root"
  # Deliberately a different secret from the root token: the recovery keys are
  # what regenerates a lost or revoked root token, so storing both together
  # would make the pair only as strong as one of them.
  recovery_keys_secret_name = "openbao/cloud-native-ref/tokens/recovery" # pragma: allowlist secret
  # PKI material, both written by the offline signing ceremony (PKI & Secrets
  # page). The intermediate's private key is in `intermediate-ca` and nowhere
  # else on AWS; `ca-chain` is certificates only ({"ca": "<intermediate>\n<root>"})
  # and is what every client verifies against. The former `root-ca` entry, which
  # held the ROOT private key, is gone -- the root is offline, as on GCP.
  intermediate_ca_secret_name = "certificates/priv.aws.ogenki.io/intermediate-ca" # pragma: allowlist secret
  ca_chain_secret_name        = "certificates/priv.aws.ogenki.io/ca-chain"        # pragma: allowlist secret

  # The lineage's snapshot bucket (opentofu/aws/openbao/lineage). Read by the
  # management stack's rehydrate step and the cluster stack's pre-destroy
  # snapshot, both of which run BEFORE the cluster that used to own the bucket.
  snapshot_bucket_name = "eu-west-3-ogenki-openbao-snapshot"

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
  # workflows take them as script arguments. Their GCP peers have no such consumer,
  # so the same globals were pure duplication -- a third copy of values that already
  # live in each stack's variables.tf defaults and variables.tfvars, and one that
  # nothing would notice going stale.
  #
  # The live values: project/region/zone in opentofu/gcp/network/variables.tfvars,
  # cluster name in opentofu/gcp/gke/init/variables.tfvars. Add a global here when,
  # and only when, a script needs to be handed one.
  #
  # `gcp_snapshot_bucket_name` is the one value that clears that bar today, which is
  # why the rule above is a bar and not a ban. Two GCP scripts take the bucket as an
  # argument -- `openbao-config.sh rehydrate` in gcp/openbao/management's deploy,
  # `openbao-config.sh pre-destroy-snapshot` in gcp/openbao/cluster's destroy --
  # the same two sites that on AWS already read `snapshot_bucket_name` above. It was
  # a literal in both heredocs, so one value was written twice with neither copy
  # aware of the other. The project id stays a literal there: nothing is handed it
  # as a shared argument, so it does not clear the bar.
  gcp_snapshot_bucket_name = "ogenki-435905-ogenki-openbao-snapshot"
}

# The CA-chain fetch, as a command list, for the two AWS stacks whose `vault`
# provider must verify OpenBao before it can plan.
#
# `providers.tf` in aws/openbao/management and `openbao.tf` in aws/eks/configure
# both point `ca_cert_file` at `.tls/ca.pem`. `.tls/` is gitignored, so on a fresh
# checkout or any CI runner that file does not exist and the provider fails to
# CONFIGURE -- before it can plan. Provider configuration is evaluated before any
# resource exists, so this cannot be a `local_file` resource; it has to be a script
# step, prepended to every script in those stacks that runs tofu.
#
# It lives HERE rather than in either stack because the two copies were 18
# byte-identical lines, and the newer one carried a comment reading "one global,
# reused" -- which would have stopped the next reader noticing there were two.
# Terramate globals are stack-local (`terramate debug show globals` resolves
# `openbao_ca_cmd` in aws/eks/configure and not in aws/openbao/cluster), so a
# stack-level block cannot be shared however it is worded. opentofu/aws/ holds no
# *.tm.hcl at all, which makes this file the nearest common ancestor -- and it
# already owns every input the command takes (`ca_chain_secret_name`, `region`,
# `profile`) and already carries a bash-snippet command global (`cloud_gate`) as
# precedent.
#
# Visible to the GCP stacks as well, like `region` and `snapshot_bucket_name`
# above, and unused there: GCP fetches its CA with `--cloud gcp` from its own
# Secret Manager, as a bash snippet inside a `${global.cloud_gate}` block.
globals "openbao_ca_cmd" {
  args = [
    "bash",
    "${terramate.root.path.fs.absolute}/scripts/tm-provisioner.sh",
    "--tm-run",
    "bash",
    "${terramate.root.path.fs.absolute}/scripts/openbao-config.sh",
    "ca",
    "--root-ca-secret-name",
    global.ca_chain_secret_name,
    "--ca-output-file",
    ".tls/ca.pem",
    "--region",
    global.region,
    "--profile",
    global.profile,
  ]
}
