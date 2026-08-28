# The Gateway API CRDs, from the same shared module gcp/gke/configure uses.
#
# This stack used to apply a hand-written list of ten individual CRD URLs, which
# is exactly the arrangement the module was written to retire: cilium-operator
# probes for these CRDs once at startup and permanently disables its Gateway API
# controller if any is missing -- no crash, no alert, only the leader replica
# logs it. That fired on 2026-08-19 over a missing BackendTLSPolicy. A bundle
# cannot drift from what Cilium expects; a list can, and did.
#
# The module applies the whole experimental bundle, so this also picks up the
# three x-k8s.io CRDs and the two safe-upgrade ValidatingAdmissionPolicy objects
# the enumeration never carried.
module "gateway_api_crds" {
  source = "../../../shared/modules/gateway-api-crds"

  gateway_api_version = var.gateway_api_version
}

# State migration: count-indexed resources -> the module's for_each map.
#
# Without these, OpenTofu destroys ten live CRDs and recreates them, taking
# every Gateway, HTTPRoute and TLSRoute on the cluster with them. The keys are
# the manifest self-links produced by kubectl_file_documents, read from the
# module's `manifest_keys` output rather than constructed by hand.
#
# Indices match the order of the old local.gateway_api_crds_urls list.
moved {
  from = kubectl_manifest.gateway_api_crds[0]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/gatewayclasses.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[1]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/gateways.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[2]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/httproutes.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[3]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/referencegrants.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[4]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/tcproutes.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[5]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/tlsroutes.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[6]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/udproutes.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[7]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/grpcroutes.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[8]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/backendtlspolicies.gateway.networking.k8s.io"]
}

moved {
  from = kubectl_manifest.gateway_api_crds[9]
  to   = module.gateway_api_crds.kubectl_manifest.this["/apis/apiextensions.k8s.io/v1/customresourcedefinitions/listenersets.gateway.networking.k8s.io"]
}
