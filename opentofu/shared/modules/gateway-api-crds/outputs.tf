output "manifest_keys" {
  description = "Self-link keys of every applied manifest. Printed so the AWS moved blocks can be written from real output rather than constructed by hand"
  value       = keys(data.kubectl_file_documents.gateway_api_crds.manifests)
}
