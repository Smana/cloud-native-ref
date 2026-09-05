# External Secrets' access to the ONE secret it still reads: the CA chain.
#
# This is the fix for the Critical finding the whole-branch review raised, and
# it is why the GCPWorkloadIdentity route was NOT taken here.
#
# That composition renders ProjectIAMMember, which is PROJECT-scoped. Granting
# External Secrets a secret-reading role that way would let anything holding its
# ServiceAccount token read every secret in the project by name — including
# openbao-priv-gcp-root-token, the recovery keys, and the intermediate CA's
# PRIVATE KEY. That last one is enough to mint any *.priv.gcp.ogenki.io
# certificate offline and indefinitely, in a design restructured specifically so
# the ROOT key never touches a networked system.
#
# Per-secret bindings give External Secrets exactly these secrets and nothing else,
# which is the same treatment opentofu/gcp/openbao/cluster/iam.tf already gives
# the OpenBao node for its server certificate.
#
# Consequence, stated rather than hidden: slice 5's GCPWorkloadIdentity
# composition now has no consumer on this cluster. That is the honest outcome —
# it is an API waiting for a workload whose access is genuinely project-shaped,
# and external-dns in workstream 10 is the likely first one.
locals {
  # GKE Workload Identity binds by SUBJECT: no Google service account, no
  # annotation on the KSA. `projects/` takes the project NUMBER while
  # `workloadIdentityPools/` takes the project ID -- reversed, the API ACCEPTS
  # the binding and it silently never matches.
  external_secrets_principal = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/${var.external_secrets_namespace}/sa/${var.external_secrets_service_account}",
  ])
}

data "google_project" "this" {
  project_id = var.project_id
}

# The CA chain, so cert-manager can verify OpenBao's certificate. Public
# material -- certificates only, no key -- but it still goes through Secret
# Manager rather than a committed file so a rotated intermediate does not
# require editing a manifest.
resource "google_secret_manager_secret_iam_member" "external_secrets_ca_chain" {
  project   = var.project_id
  secret_id = var.ca_chain_secret_name
  role      = "roles/secretmanager.secretAccessor"
  member    = local.external_secrets_principal
}
