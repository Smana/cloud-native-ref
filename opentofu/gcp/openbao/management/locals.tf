locals {
  openbao_address = "https://bao.${var.private_domain_name}:8200"

  # Source ranges an in-cluster caller may present to OpenBao's internal LB.
  #
  # MEASURED on a live gcp-0 (2026-08-26), not inferred -- auth.tf carried this
  # as an explicit deferral pending exactly this measurement:
  #
  #   cilium-dbg status        -> Routing: Native; Masquerading: IPTables [IPv4: Enabled]
  #   cilium-config            -> ipv4-native-routing-cidr = 100.65.0.0/16 (the POD cidr)
  #   OpenBao internal LB      -> 10.10.0.9, inside the NODE cidr 10.10.0.0/16
  #
  # The LB sits OUTSIDE the native-routing CIDR, and masquerading is on, so pod
  # egress to it is SNATed to the node IP -- observed as 10.10.0.5. So today the
  # node CIDR is the range that actually matters.
  #
  # Both are bound anyway, and that is deliberate rather than hedging: it is the
  # exact analogue of what AWS binds. There, allowed_cidr_blocks is the whole VPC
  # (10.0.0.0/16), which already contains both node and pod addresses because
  # VPC-CNI gives pods VPC IPs. On GCP the two ranges are disjoint, so covering
  # the same surface takes two entries. Binding node-only would also fail closed
  # if a future datapath change (bpf.masquerade, a wider native-routing CIDR)
  # stopped SNATing -- and it fails at AUTH, with an error naming the AppRole and
  # saying nothing about the network.
  approle_bound_cidrs = [
    local.network.node_cidr,
    local.network.pod_cidr,
  ]

  network = data.terraform_remote_state.network.outputs
}
