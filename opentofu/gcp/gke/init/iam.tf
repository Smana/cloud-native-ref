# NO project IAM bindings here, deliberately.
#
# This file used to grant roles/editor project-wide to the Workload Identity
# principal
#
#   principal://iam.googleapis.com/projects/<NUMBER>/locations/global
#     /workloadIdentityPools/<PROJECT_ID>.svc.id.goog
#     /subject/ns/crossplane-system/sa/crossplane
#
# as "bootstrap-only breadth", to be narrowed in slice 5 (GCPWorkloadIdentity).
# It was removed instead, for a reason that only became clear once the GCP
# cluster was actually built: CROSSPLANE IS NOT DEPLOYED ON GCP. The cluster's
# Flux tree is crds, flux and namespaces -- no Crossplane, no providers, no
# compositions. Nothing created that ServiceAccount and nothing used the grant.
#
# So it was not "a grant that is wider than what Crossplane needs". It was a
# project-wide editor grant with NO consumer, and it was reachable: namespaces/
# base is shared between clouds and creates crossplane-system on GCP too, so
# anyone able to create a ServiceAccount named `crossplane` in that existing
# namespace inherited editor on the whole project. The binding is also scoped to
# the project-wide identity pool rather than to this cluster, so every future
# GKE cluster in the project -- including a throwaway one -- would have inherited
# it as well.
#
# Narrowing was rejected as the fix because any role set chosen now would be a
# guess about compositions that do not exist yet. Note also that GCP IAM
# conditions would NOT reproduce the AWS `xplane-*` scoping: resource-level
# conditions are unsupported for most services Crossplane would touch, so the
# AWS parity is not directly available here.
#
# SLICE 5 MUST create its own binding alongside the GCP compositions that define
# what is actually needed, and must NOT restore this one. Two traps that cost
# real time when it existed, worth keeping when it comes back:
#
#   1. `projects/` takes the project NUMBER, `workloadIdentityPools/` takes the
#      project ID. Reversed, the API accepts the binding and it simply never
#      matches -- a permission error that points nowhere. Derive the number from
#      data.google_project.this.number, never hand-copy it.
#   2. The principal string is built from variables, so OpenTofu sees no
#      reference to module.gke and schedules the binding in PARALLEL with the
#      cluster -- but the pool `<project>.svc.id.goog` does not exist until a
#      cluster with workload_pool has been created. Without an explicit
#      depends_on = [module.gke] a FRESH apply fails with
#        Error 400: Identity Pool does not exist (ogenki-435905.svc.id.goog)
#      and does not reproduce on re-apply, because by then the pool exists.
#      Measured on the first real deploy, 2026-08-23.
#
# data.google_project.this stays in data.tf: output "project_number" feeds the
# Flux postBuild substitution ConfigMap and is unrelated to any of the above.
