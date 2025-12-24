# =============================================================================
# DISABLED: Cilium CNI Configuration for ENI mode with secondary CIDR
# =============================================================================
# This configuration enables pods to use IPs from the secondary CIDR (100.64.0.0/16)
# via prefix delegation. However, it causes Gateway API L7 proxy to fail on
# cross-node traffic due to a Cilium bug.
#
# Issue: https://github.com/cilium/cilium/issues/43493
# Symptoms:
#   - L7 proxy returns 503 "upstream connect error...connection timeout" for cross-node traffic
#   - Same-node traffic works fine
#   - Direct pod-to-pod/service traffic works fine (issue is specific to L7 proxy)
#   - ipcache shows "hastunnel" flags for remote pods despite native routing mode
#
# When Cilium fixes #43493, uncomment this resource and also:
#   - Enable cni.customConf and cni.configMap in helm_values/cilium.yaml
#   - Enable awsEnablePrefixDelegation in helm_values/cilium.yaml
#   - Add dependency in main.tf helm_release.cilium
#
# Configuration details:
#   - first-interface-index: 1 (skip eth0, use secondary ENIs only for pods)
#   - subnet-tags: select subnets tagged with cilium.io/pod-subnet=true (100.64.0.0/16)
#   - disable-prefix-delegation: false (enable prefix delegation for high pod density)
#
# resource "kubectl_manifest" "cilium_cni_config" {
#   yaml_body = yamlencode({
#     apiVersion = "v1"
#     kind       = "ConfigMap"
#     metadata = {
#       name      = "cilium-cni-configuration"
#       namespace = "kube-system"
#     }
#     data = {
#       "cni-config" = jsonencode({
#         cniVersion = "0.3.1"
#         name       = "cilium"
#         plugins = [{
#           cniVersion = "0.3.1"
#           type       = "cilium-cni"
#           eni = {
#             "first-interface-index"     = 1
#             "subnet-tags"               = { "cilium.io/pod-subnet" = "true" }
#             "disable-prefix-delegation" = false
#           }
#         }]
#       })
#     }
#   })
#   server_side_apply = true
# }
