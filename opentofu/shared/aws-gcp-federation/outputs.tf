output "route53_role_arn" {
  description = "ARN the ClusterIssuer's route53 solver and external-dns-public assume"
  value       = aws_iam_role.route53.arn
}

output "oidc_issuer" {
  description = "The GKE issuer AWS trusts. Renaming or moving the cluster changes this and invalidates the provider."
  value       = local.oidc_issuer
}

output "public_zone_id" {
  description = "Hosted zone the role may change records in"
  value       = data.aws_route53_zone.public.zone_id
}
