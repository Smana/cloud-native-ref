output "autoscaling_group_id" {
  value = module.openbao_asg.autoscaling_group_id
}

# A MAP keyed by availability zone, not a list.
#
# `aws_lb.subnet_mapping` is a set in the provider schema, so a list built from
# it comes out in hash order -- not AZ order, and not stable when an AZ is added
# or removed. The one consumer of this output picks a SINGLE address
# (openbao_target_ip, in opentofu/gcp/gke/configure), so it needs to know which
# address belongs to which zone rather than being handed three in arbitrary
# order. Computed from the subnet data source with the same expression the
# resource uses, so it is also known at plan time instead of only after apply.
output "nlb_private_ips" {
  description = "Fixed private address of the internal NLB, per availability zone. A remote cluster's openbao_target_ip is one of these (opentofu/gcp/gke/configure)."
  value       = { for s in data.aws_subnet.private : s.availability_zone => cidrhost(s.cidr_block, -6) }
}
