output "autoscaling_group_id" {
  value = module.openbao_asg.autoscaling_group_id
}

output "nlb_private_ips" {
  description = "Fixed private addresses of the internal NLB, one per AZ. A remote cluster's openbao_target_ip is one of these (opentofu/gcp/gke/configure)."
  value       = [for m in aws_lb.this.subnet_mapping : m.private_ipv4_address]
}
