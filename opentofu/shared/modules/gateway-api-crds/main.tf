# The Gateway API CRDs, applied identically on every cloud.
#
# This module exists because the two clouds previously applied these CRDs two
# different ways, which meant fixing a Gateway API problem in one directory did
# not fix it in the other. Unlike the Cilium values -- which are deliberately
# forked per cloud so divergence stays visible -- there is no intended
# divergence here: same version, same channel, same bundle.
#
# THE WHOLE BUNDLE, NOT AN ENUMERATION. cilium-operator probes for these CRDs
# exactly once at startup and permanently disables its Gateway API controller if
# any is absent -- no crash, no alert, and only the leader replica logs it. On
# 2026-08-19 that fired over a two-second gap because the hand-written list had
# ten entries and Cilium 1.20 also wants BackendTLSPolicy. A bundle cannot drift
# from what Cilium expects; a list can, and did.
#
# Experimental channel, matching what the cluster already runs, so a route using
# an experimental field cannot work on one cloud and fail on the other.
data "http" "gateway_api_crds" {
  url = "https://github.com/kubernetes-sigs/gateway-api/releases/download/${var.gateway_api_version}/experimental-install.yaml"
}

data "kubectl_file_documents" "gateway_api_crds" {
  content = data.http.gateway_api_crds.response_body
}

# for_each keyed by manifest self-link, NOT count: a future release that adds a
# CRD appends a key instead of shifting every index. A count-indexed list makes
# OpenTofu destroy and recreate live CRDs on any reordering, taking every
# Gateway and HTTPRoute with them.
resource "kubectl_manifest" "this" {
  for_each  = data.kubectl_file_documents.gateway_api_crds.manifests
  yaml_body = each.value

  # server_side_apply is REQUIRED, not preferred: client-side apply writes a
  # last-applied-configuration annotation and the httproutes CRD exceeds the
  # 262144-byte limit. Confirmed on the GCP gate cluster.
  #
  # force_conflicts because Flux also reconciles these from the gateway-api
  # GitRepository; whoever applies second must not fight the first.
  server_side_apply = true
  force_conflicts   = true
  wait              = true
}
