# Crossplane's GCP identity, for slice 5 (GCPWorkloadIdentity).
#
# This file previously granted roles/editor project-wide and was REMOVED in
# #1818, because Crossplane was not deployed on GCP at all and the grant had no
# consumer. It comes back for slice 5 — deliberately scoped this time, with
# everything that was measured rather than assumed recorded below.
#
# HONEST CAVEAT: the consumer still does not exist. Crossplane is not yet
# deployed on GCP, so this binding again lands ahead of the workload it is for,
# which is the situation #1818 removed the old one over. Two things make that
# acceptable where roles/editor was not:
#
#   - The blast radius is one role. Anyone able to create a ServiceAccount named
#     `provider-gcp` in crossplane-system could assume this identity, but all it
#     can then do is grant roles/dns.admin -- not grant itself owner, which is
#     what editor allowed.
#   - It is a prerequisite, not a leftover: the GCP provider cannot authenticate
#     without it, so it has to precede the deployment rather than follow it.
#
# If slice 5 stalls, REMOVE THIS AGAIN rather than letting it sit. The reasoning
# that justified deleting the last one applies to a narrow grant too, just more
# slowly.
#
# ── WHAT IT REPLACES ────────────────────────────────────────────────────────
#
# roles/editor is thousands of permissions across every service. What
# GCPWorkloadIdentity renders is ProjectIAMMember, one per requested role, so the
# capability actually needed is setIamPolicy on the project:
#
#   roles/resourcemanager.projectIamAdmin
#
# ── WHY THAT ALONE IS NOT ENOUGH ────────────────────────────────────────────
#
# projectIamAdmin is a PRIVILEGE-ESCALATION PATH: setIamPolicy can grant any role
# to any principal, including granting Crossplane itself roles/owner. Narrowing
# editor to it would be a large improvement and still leave that open.
#
# The mitigation is an IAM Condition on `modifiedGrantsByRole`, limiting WHICH
# roles this binding may grant. That is GCP's analogue of the AWS side's
# `xplane-*` scoping (platform constitution): AWS restricts Crossplane by
# resource NAME; GCP cannot for project IAM, because the resource IS the project,
# so it restricts by grantable ROLE instead.
#
# Adding a role to the allowlist is therefore a deliberate act, which is the
# point. A workload needing something outside it fails with a permission error
# naming the role, rather than Crossplane quietly having had it all along.
#
locals {
  # Predefined roles Crossplane may grant. Keep tight; grow on evidence.
  crossplane_grantable_roles = [
    "roles/dns.admin", # external-dns records + cert-manager DNS-01 (criterion 21)
  ]

  # TRAP 1, and it is silent: `projects/` takes the project NUMBER while
  # `workloadIdentityPools/` takes the project ID. Reversed, the API ACCEPTS the
  # binding and it simply never matches — a permission error that points nowhere.
  # Derived from data.google_project rather than hand-copied for that reason.
  crossplane_principal = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    # sa/provider-gcp, NOT sa/crossplane. The PROVIDER pod makes the cloud API
    # calls; Crossplane core never talks to GCP -- the AWS side binds
    # crossplane-system/provider-aws for the same reason
    # (opentofu/aws/eks/init/iam.tf:56-57).
    #
    # OBLIGATION ON SLICE 5, not a description of something that exists: when the
    # GCP provider tree is written, its DeploymentRuntimeConfig MUST name this
    # ServiceAccount `provider-gcp`. Nothing checks that the two agree, and a
    # mismatch fails in the same silent way as TRAP 1.
    "/subject/ns/crossplane-system/sa/provider-gcp",
  ])

  # Grants are limited to the allowlist above, and nothing else.
  #
  # `hasOnly` is the ONLY usable form here. GCP IAM conditions run a restricted
  # CEL dialect: the `.all()` macro is rejected at apply time with
  #   undeclared reference to '@not_strictly_false'
  # so an expression mixing exact matches with a `startsWith` prefix cannot be
  # written. Measured 2026-08-24, not read in docs.
  #
  crossplane_grant_condition = join("", [
    "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([",
    join(",", [for r in local.crossplane_grantable_roles : "'${r}'"]),
    "])",
  ])
}

# Additive binding, and it must stay that way.
#
# NEVER use google_project_iam_policy or google_project_iam_binding here: both
# are AUTHORITATIVE for the roles they manage and would delete every binding
# they do not know about — other workloads, and break-glass human access. The
# failure is silent until something unrelated loses permission.
resource "google_project_iam_member" "crossplane_iam_admin" {
  project = var.project_id
  role    = "roles/resourcemanager.projectIamAdmin"
  member  = local.crossplane_principal

  condition {
    title       = "xplane-scoped-grants-only"
    description = "Crossplane may grant only the allowlisted predefined roles. Without this, projectIamAdmin can grant itself roles/owner."
    expression  = local.crossplane_grant_condition
  }

  # TRAP 2, fresh-apply only. The principal string is built from variables, so
  # OpenTofu sees no reference to module.gke and schedules this in PARALLEL with
  # the cluster — but the pool `<project>.svc.id.goog` does not exist until a
  # cluster with workload_pool has been created. Without this a FRESH apply fails
  # with `Error 400: Identity Pool does not exist`, and it does NOT reproduce on
  # re-apply, because by then the pool exists. Measured 2026-08-23.
  depends_on = [module.gke]
}

# NO roles/iam.roleAdmin BINDING, deliberately.
#
# It would only be needed for GCPWorkloadIdentity's optional
# `customRole.permissions`, and that feature CANNOT be granted safely today: the
# condition above uses `hasOnly`, which matches exact role names, and a custom
# role's name is chosen by the composition at render time. Allowing it would mean
# either dropping the condition — restoring the escalation path this file exists
# to close — or enumerating names that do not exist yet.
#
# So the capability is deferred rather than half-granted; the allowlist above
# covers what slice 5 actually needs.
#
# To enable customRole later: add roles/iam.roleAdmin, and either accept an
# unconditioned projectIamAdmin or pre-create the custom roles in OpenTofu so
# their names can be named in the allowlist. Do NOT simply widen the condition.
