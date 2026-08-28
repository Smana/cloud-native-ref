# The Gateway API CRDs, from the same shared module gcp/gke/configure uses.
# Why a bundle rather than a list: see the module's own header.
module "gateway_api_crds" {
  source = "../../../shared/modules/gateway-api-crds"

  gateway_api_version = var.gateway_api_version
}

# ONE-SHOT STATE MIGRATION -- DELETE THIS WHOLE BLOCK, and the module's
# `manifest_keys` output, once aws-0 has applied once. After that apply the ten
# `kubectl_manifest.gateway_api_crds[N]` addresses no longer exist in state and
# every block below is a permanent no-op.
#
# It has to exist for exactly one apply: without it OpenTofu destroys ten live
# CRDs and recreates them, taking every Gateway, HTTPRoute and TLSRoute on the
# cluster with them. The keys are the manifest self-links produced by
# kubectl_file_documents, read from the module's `manifest_keys` output rather
# than constructed by hand. Indices match the order of the old
# local.gateway_api_crds_urls list.
#
# They are also pinned to Gateway API v1.6.1's CRD names. If gateway_api_version
# is bumped before this block is deleted, check every `to` address still names a
# key the bundle produces -- upstream has already moved ListenerSet between
# gateway.networking.k8s.io and gateway.networking.x-k8s.io once.
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
