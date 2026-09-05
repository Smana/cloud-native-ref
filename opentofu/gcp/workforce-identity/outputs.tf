output "workforce_pool_id" {
  description = "Consumed by gke/configure to publish into flux_cluster_vars"
  value       = google_iam_workforce_pool.zitadel.workforce_pool_id
}
