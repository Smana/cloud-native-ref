# Crossplane's own GCP identity. Bootstrapped in OpenTofu because Crossplane
# cannot create the binding that grants itself access -- the same chicken-and-egg
# the AWS side resolves by bootstrapping Crossplane's Pod Identity in eks/init.
# Slice 5 (GCPWorkloadIdentity) is blocked without this.
#
# NOTE the two different project identifiers below: projects/ takes the project
# NUMBER, workloadIdentityPools/ takes the project ID. Reversed, the API accepts
# the binding and it simply never matches -- a permission error pointing nowhere.
# This is asserted in the output `crossplane_principal` so a mistake is visible in
# the plan rather than at runtime.
locals {
  crossplane_principal = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/crossplane-system/sa/crossplane",
  ])
}

# Additive binding, and it must stay that way.
#
# NEVER use google_project_iam_policy or google_project_iam_binding here: both are
# AUTHORITATIVE for the roles they manage and would delete every binding they do
# not know about -- other workloads, and break-glass human access. The failure is
# silent until something unrelated loses permission.
#
# SCOPE NOTE: roles/editor is bootstrap-only breadth, carried deliberately so the
# cluster can come up before the permission model exists. Narrowing it to the
# specific roles Crossplane needs belongs to the GCPWorkloadIdentity plan, which
# is where that model is designed. Do not let it survive silently into slice 5.
resource "google_project_iam_member" "crossplane" {
  project = var.project_id
  role    = "roles/editor"
  member  = local.crossplane_principal

  # REQUIRED. The principal string is built from variables, so OpenTofu sees no
  # reference to module.gke and schedules this binding in PARALLEL with the
  # cluster -- but the Workload Identity Pool `<project>.svc.id.goog` does not
  # exist until a cluster with `workload_pool` has been created. Without this,
  # a fresh apply fails with:
  #
  #   Error 400: Identity Pool does not exist (ogenki-435905.svc.id.goog)
  #
  # Measured on the first real deploy, 2026-08-23: the cluster and node pool
  # created fine and only this binding failed, leaving the stage partially
  # applied. It does NOT reproduce on a re-apply, because by then the pool
  # exists -- so it is a fresh-apply-only failure, which is the same class as
  # the provider-from-same-apply-outputs trap documented in
  # opentofu/aws/eks/init/providers.tf: a dependency that is real but invisible
  # to the graph.
  depends_on = [module.gke]
}
