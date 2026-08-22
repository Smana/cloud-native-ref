# Gateway API CRDs, applied BEFORE Cilium.
#
# These live in `configure`, not `init`, even though the plan originally placed
# them in `init`. A kubectl provider configured from the cluster created in the
# same apply cannot be deferred and fails on fresh applies with "no configuration
# has been provided" -- documented in opentofu/eks/init/providers.tf after the AWS
# side hit it. `configure` runs against an already-created cluster, so the
# provider resolves cleanly.
#
# for_each, NOT count: keyed by manifest identity, so a future Gateway API release
# that adds a CRD appends instead of shifting every index. A count-indexed list
# would make tofu destroy and recreate live CRDs on any reordering, taking every
# Gateway and HTTPRoute with them. (The AWS side is count-indexed and cannot be
# switched cheaply for exactly that reason; GCP is greenfield and starts correct.)
resource "kubectl_manifest" "gateway_api_crds" {
  for_each  = data.kubectl_file_documents.gateway_api_crds.manifests
  yaml_body = each.value

  # server_side_apply is REQUIRED, not a preference. Client-side apply writes a
  # last-applied-configuration annotation, and the httproutes CRD exceeds the
  # 262144-byte annotation limit:
  #   metadata.annotations: Too long: may not be more than 262144 bytes
  # Confirmed on the Phase 1 gate cluster.
  #
  # force_conflicts because Flux also reconciles these from the gateway-api
  # GitRepository; whoever applies second must not fight the first.
  server_side_apply = true
  force_conflicts   = true
}
