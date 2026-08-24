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
#   - The blast radius is one narrow role. Anyone able to create a ServiceAccount
#     named `provider-gcp` in crossplane-system could assume this identity, but
#     all it can then do is grant DNS record-set management — not grant itself
#     owner, which is what editor allowed.
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
# roles this binding may modify. That is GCP's analogue of the AWS side's
# `xplane-*` scoping (platform constitution): AWS restricts Crossplane by
# resource NAME; GCP cannot for project IAM, because the resource IS the project,
# so it restricts by role instead.
#
# The attribute covers GRANTS AND REVOCATIONS both — Google documents it as "role
# names from the role bindings that the request modifies", and the reference
# table is headed "Granted/revoked roles". So the condition also stops Crossplane
# REMOVING bindings it did not create, including break-glass human access.
# Verified against the attribute reference 2026-08-24.
#
# Adding a role to the allowlist is therefore a deliberate act, which is the
# point. A workload needing something outside it fails with a permission error
# naming the role, rather than Crossplane quietly having had it all along.

# The DNS role Crossplane is permitted to grant.
#
# Pre-created HERE rather than by the composition, and that is what makes it
# grantable at all: the condition below uses `hasOnly`, which matches exact role
# names, so a role whose name the composition invents at render time could never
# be allowlisted. A role created in OpenTofu has a DETERMINISTIC name, so it can.
#
# NOT roles/dns.admin, which was the first draft. That predefined role carries
# `dns.managedZones.delete` and the whole `dns.responsePolicies.*` /
# `dns.policies.*` family, both beyond anything slice 5 needs:
#
#   - Zone deletion contradicts the platform constitution outright — "no deletion
#     permissions for stateful services (S3, IAM, Route53)". The AWS side honours
#     that; granting dns.admin here would not have.
#   - Response policies are the sharper one. A compromised provider-gcp could
#     bind a response policy to the cluster's VPC overriding
#     `metadata.google.internal` or `*.googleapis.com`, redirecting in-cluster
#     traffic and harvesting credentials — invisible to external-dns, which only
#     ever looks at record sets.
#
# `role_id` may not contain dashes, so the platform's `xplane-` convention is
# spelled `xplane_` here.
resource "google_project_iam_custom_role" "crossplane_dns" {
  project     = var.project_id
  role_id     = "xplane_dns_editor"
  title       = "Crossplane DNS editor"
  description = "Record-set management for external-dns and cert-manager DNS-01. Deliberately excludes zone deletion and response policies; see opentofu/gcp/gke/init/iam.tf."

  permissions = [
    # Record sets: the actual job. Delete IS included — external-dns removes
    # records when a route goes away, and cert-manager cleans up its
    # _acme-challenge TXT records after validation.
    "dns.resourceRecordSets.create",
    "dns.resourceRecordSets.delete",
    "dns.resourceRecordSets.get",
    "dns.resourceRecordSets.list",
    "dns.resourceRecordSets.update",

    # Changes are how Cloud DNS applies record-set edits transactionally.
    "dns.changes.create",
    "dns.changes.get",
    "dns.changes.list",

    # Read-only on zones. external-dns must discover which zone owns a name; it
    # must never create or destroy one.
    "dns.managedZones.get",
    "dns.managedZones.list",
  ]
}

locals {
  # Roles Crossplane may grant. Keep tight; grow on evidence.
  crossplane_grantable_roles = [
    google_project_iam_custom_role.crossplane_dns.name,
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
    # The other end of this is
    # infrastructure/base/crossplane/providers-gcp/deploymentruntimeconfig-gcp.yaml,
    # whose serviceAccountTemplate names the SA `provider-gcp`. Nothing checks
    # that the two agree, and a mismatch fails in the same silent way as TRAP 1 —
    # so change them together.
    "/subject/ns/crossplane-system/sa/provider-gcp",
  ])

  # Grants are limited to the allowlist above, and nothing else.
  #
  # `hasOnly` is the ONLY usable form here. GCP IAM conditions run a restricted
  # CEL dialect: the `.all()` macro is rejected at apply time with
  #   undeclared reference to '@not_strictly_false'
  # so an expression mixing exact matches with a `startsWith` prefix cannot be
  # written. Measured 2026-08-24, not read in docs.
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
    description = "Crossplane may modify only the allowlisted role bindings. Without this, projectIamAdmin can grant itself roles/owner."
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

# Read-only access to role definitions, so the grant above can actually be made.
#
# `gcloud iam roles describe roles/resourcemanager.projectIamAdmin` returns 9
# permissions and `iam.roles.get` is NOT among them (checked 2026-08-24).
# Referencing a CUSTOM role in a setIamPolicy call can require the caller to read
# that role's definition — a constraint that does not exist for predefined roles,
# and therefore one the previous roles/dns.admin draft would never have hit.
#
# UNVERIFIED whether GCP enforces it on this path: confirming needs a live
# provider-gcp pod attempting the grant, and GCP is torn down. Granted
# pre-emptively because the downside is asymmetric — without it slice 5 fails at
# runtime with an error naming the wrong thing, and with it the identity gains
# only the ability to READ role definitions, which are not secret and confer
# nothing. Unconditioned deliberately: `modifiedGrantsByRole` is undefined for
# read requests, so a condition here would be vacuous anyway (see gap 1 below).
resource "google_project_iam_custom_role" "crossplane_role_reader" {
  project     = var.project_id
  role_id     = "xplane_role_reader"
  title       = "Crossplane role reader"
  description = "Read-only on IAM role definitions, so ProjectIAMMember can reference the custom DNS role. Confers no grant capability."

  permissions = [
    "iam.roles.get",
    "iam.roles.list",
  ]
}

resource "google_project_iam_member" "crossplane_role_reader" {
  project = var.project_id
  role    = google_project_iam_custom_role.crossplane_role_reader.name
  member  = local.crossplane_principal

  # Same fresh-apply race as the binding above — see TRAP 2.
  depends_on = [module.gke]
}

# ── WHAT THIS BINDING STILL DOES NOT CLOSE ──────────────────────────────────
#
# Written down because both are inherent to the condition mechanism, neither has
# a fix available in the restricted CEL dialect, and an undocumented gap becomes
# an assumed-safe one. Reviewed 2026-08-24.
#
# 1. The condition gates 1 of the role's 9 permissions.
#    `modifiedGrantsByRole` is populated only for setIamPolicy-shaped requests.
#    Google, verbatim: "For other types of requests, the attribute is not
#    defined." Undefined falls back to the mandated `[]` default, and
#    `[].hasOnly(...)` is vacuously TRUE — so projectIamAdmin's other verbs
#    (resourcemanager.projects.{create,update,delete,search}PolicyBinding and
#    iam.policybindings.{get,list}) are granted UNCONDITIONED.
#    Concretely: deletePolicyBinding could remove a Principal Access Boundary
#    binding constraining this very workload. Latent today — the project uses no
#    PAB policies, and creating one is separately blocked by the missing
#    iam.principalaccessboundarypolicies.bind — but it goes live silently the day
#    the org adopts PAB. Re-examine this binding then.
#
# 2. The condition constrains the ROLE, never the MEMBER.
#    Nothing stops Crossplane granting the allowlisted role to a principal other
#    than itself — e.g. any pod identity in the cluster. Two things bound it:
#    the org policy `constraints/iam.allowedPolicyMemberDomains` is enforced
#    (allowedValues: C01fvyerd), so allUsers/allAuthenticatedUsers and external
#    Google accounts are already refused at the perimeter; and the allowlisted
#    role is narrow by construction, so the worst in-org outcome is DNS
#    record-set management, not project control. Shrinking the role shrinks this.
#
# 3. The binding is scoped to the PROJECT-WIDE workload identity pool
#    `<project>.svc.id.goog`, not to this cluster — GKE workload-identity
#    subjects carry no cluster dimension, so there is no way to write it
#    otherwise. Every future GKE cluster in this project, including a throwaway
#    one, therefore inherits it: a `crossplane-system/provider-gcp` ServiceAccount
#    in ANY cluster here matches. Unavoidable, so it is recorded rather than
#    fixed; it is a further reason to keep the allowlist narrow.

# NO roles/iam.roleAdmin BINDING, deliberately.
#
# GCPWorkloadIdentity's optional `customRole.permissions` renders a role whose
# name the composition chooses at render time, and `hasOnly` cannot allowlist a
# name that does not exist yet. Granting roleAdmin would mean either dropping the
# condition — restoring the escalation path this file exists to close — or
# accepting arbitrary role creation.
#
# The pre-created role above is the supported alternative and covers slice 5's
# actual need. Extend the SAME pattern for anything further: add a
# google_project_iam_custom_role here, reference it in the allowlist. Do NOT
# widen the condition.
