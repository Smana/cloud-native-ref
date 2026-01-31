# =============================================================================
# Cilium CNI Configuration for ENI mode with secondary CIDR
# =============================================================================
# Enables pods to use IPs from the secondary CIDR (100.64.0.0/16) via prefix
# delegation for higher pod density. Requires WireGuard encryption to work
# around the cross-node L7 proxy bug (cilium/cilium#43493).
#
# Configuration:
#   - first-interface-index: 1 (skip eth0, use secondary ENIs only for pods)
#   - subnet-tags: select subnets tagged with cilium.io/pod-subnet=true (100.64.0.0/16)
#   - disable-prefix-delegation: false (enable prefix delegation)
resource "kubectl_manifest" "cilium_cni_config" {
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "ConfigMap"
    metadata = {
      name      = "cilium-cni-configuration"
      namespace = "kube-system"
    }
    data = {
      "cni-config" = jsonencode({
        cniVersion = "0.3.1"
        name       = "cilium"
        plugins = [{
          cniVersion = "0.3.1"
          type       = "cilium-cni"
          eni = {
            "first-interface-index"     = 1
            "subnet-tags"               = { "cilium.io/pod-subnet" = "true" }
            "disable-prefix-delegation" = false
          }
        }]
      })
    }
  })
  server_side_apply = true
}
