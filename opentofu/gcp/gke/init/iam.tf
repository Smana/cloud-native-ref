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

# NOTE: there is deliberately no Secret Manager role here.
#
# An `xplane_secret_reader` role existed on this branch and was removed once the
# workstream it was built for actually wired External Secrets up. The reason is
# worth keeping: `ProjectIAMMember` -- the only binding the GCPWorkloadIdentity
# composition renders -- is PROJECT-SCOPED, so ANY secret-reading role granted
# through it can read EVERY secret in the project by name. In this project that
# includes OpenBao's root token, its recovery keys and the intermediate CA's
# private key. Narrowing the role's permission list stops enumeration; it does
# not stop "knows the name, reads the secret".
#
# External Secrets is therefore bound per secret instead, in
# opentofu/gcp/openbao/management/iam.tf, the same way
# opentofu/gcp/openbao/cluster/iam.tf binds the OpenBao node to its server
# certificate. Re-adding a project-wide secret role here needs a workload whose
# access is genuinely project-shaped, and an argument for why per-secret
# bindings will not do.

# Bucket management for the App Composition's objectStore block (slice 8).
#
# `Bucket` (storage.gcp.m.upbound.io) needs full CRUD on the bucket resource
# itself; `BucketIAMMember` needs get/setIamPolicy to grant the app's own
# workload identity a role scoped to that one bucket. Neither is covered by
# roles/resourcemanager.projectIamAdmin above, which is IAM-policy
# permissions on the PROJECT, not Cloud Storage permissions. No predefined
# role is this narrow (roles/storage.admin also carries object-level and
# HMAC-key permissions this platform has no use for), so a custom role, same
# pattern as crossplane_dns.
resource "google_project_iam_custom_role" "crossplane_storage" {
  project     = var.project_id
  role_id     = "xplane_storage_admin"
  title       = "Crossplane storage bucket admin"
  description = "Bucket lifecycle + IAM for the App Composition's per-app buckets. See opentofu/gcp/gke/init/iam.tf."

  permissions = [
    # Bucket lifecycle: what the Bucket MR's reconcile loop does on every
    # observe/create/update/delete pass. NOT storage.buckets.list -- Crossplane
    # (like every Terraform-based provider CRUD path) observes a resource it
    # already knows the name of via a GET, never by enumerating the project's
    # buckets and searching. list is also incompatible with the resource.name
    # condition below: list's resource is the collection endpoint, not a
    # single bucket name, so a startsWith(bucket-name-prefix) condition can
    # never match it -- granting it unconditioned would be the one permission
    # on this role with no bucket-name scoping.
    "storage.buckets.create",
    "storage.buckets.delete",
    "storage.buckets.get",
    "storage.buckets.update",

    # BucketIAMMember is additive (get current policy, merge in the member,
    # set it back) -- get is required for the merge, not just set.
    "storage.buckets.getIamPolicy",
    "storage.buckets.setIamPolicy",
  ]
}

locals {
  # Roles Crossplane may grant. Keep tight; grow on evidence.
  crossplane_grantable_roles = [
    google_project_iam_custom_role.crossplane_dns.name,

    # runlore's cloud tools, added on exactly the evidence this comment asks
    # for: its GCPWorkloadIdentity claim failed with
    #
    #   Error 403: Policy update access denied
    #
    # naming roles/logging.viewer -- the condition doing its job, not a bug.
    #
    # These three are PREDEFINED rather than a custom role, unlike
    # crossplane_dns above, and the difference is deliberate. That one exists
    # because roles/dns.admin carries zone DELETION and response policies,
    # both beyond what external-dns needs and one of them a traffic-hijack
    # path. There is no equivalent problem here: all three are *.viewer, so
    # read-only by construction -- no writes, no deletes, nothing that could
    # modify the project. Writing a custom role to narrow a viewer role would
    # add a maintenance burden and a guess about which API calls runlore makes,
    # in exchange for no reduction in blast radius that matters.
    #
    # runlore is read-only by design on the cluster too (actions.mode off); its
    # only writes anywhere are knowledge-base pull requests on GitHub.
    "roles/logging.viewer",
    "roles/container.viewer",
    "roles/monitoring.viewer",
  ]

  # SEPARATE from crossplane_grantable_roles above, deliberately -- N1. The two
  # lists feed the conditions on two DIFFERENT bindings, at two different
  # scopes: crossplane_grant_condition gates roles/resourcemanager.projectIamAdmin,
  # a PROJECT-level setIamPolicy; crossplane_bucket_grant_condition gates
  # crossplane_storage below, a BUCKET-level one. They were merged into one
  # list on first pass, which was wrong: modifiedGrantsByRole does not carry
  # the RESOURCE the grant happened on, only the ROLE, so a role allowlisted
  # for the bucket-scoped binding was *also* legalised for the project-scoped
  # one -- a GCPWorkloadIdentity claim setting spec.roles (project-wide, not
  # bucketRoles) to "roles/storage.objectAdmin" would have passed both the XRD
  # pattern and this condition, reaching every bucket in the project including
  # OpenBao's snapshots and CNPG's backups. Exactly what bucketRoles (Task 1)
  # was built to make impossible. Keep these two lists apart permanently, not
  # just for this pair of roles.
  #
  # storage.objectAdmin / storage.objectViewer are PREDEFINED GCP roles, not
  # custom ones -- apis/app/kcl/main.k's GCPWorkloadIdentity claim names them
  # literally (`role = "roles/storage.objectAdmin" if permissions ==
  # "readwrite" else "roles/storage.objectViewer"`), and hasOnly matches exact
  # role names, so they belong in this allowlist verbatim, the same way the
  # custom DNS role's deterministic name does.
  crossplane_bucket_grantable_roles = [
    "roles/storage.objectAdmin",
    "roles/storage.objectViewer",
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

  # Same hasOnly() shape as above, using the SEPARATE bucket-scoped allowlist
  # (N1) -- plus a second, independent clause restricting WHICH bucket the
  # binding reaches at all, conjoined with a plain `&&`. This is NOT the
  # role-name startsWith the comment above rules out: that one tried to
  # pattern-match ROLE NAMES inside hasOnly's list via `.all()` and hit the
  # macro restriction. `resource.name` is a different attribute entirely (the
  # target object of the API call, not a role), and `&&` is a plain boolean
  # operator, not a macro -- no restriction applies.
  #
  # `_gcsName = envConfig.projectID + "-ogenki-" + _name` in
  # apis/app/kcl/main.k is the single place every bucket name this platform
  # creates comes from, so every Crossplane-managed bucket carries this
  # prefix and nothing else does. GCP's resource-name format for a bucket
  # under IAM Conditions is "projects/_/buckets/<bucket-name>" -- the
  # placeholder is a literal "_", not the project ID.
  crossplane_bucket_grant_condition = join("", [
    "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([",
    join(",", [for r in local.crossplane_bucket_grantable_roles : "'${r}'"]),
    "]) && resource.name.startsWith('projects/_/buckets/${var.project_id}-ogenki-')",
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

# Grants Crossplane the bucket-lifecycle + IAM permissions defined in
# crossplane_storage above.
resource "google_project_iam_member" "crossplane_storage" {
  project = var.project_id
  role    = google_project_iam_custom_role.crossplane_storage.name
  member  = local.crossplane_principal

  # Its OWN allowlist and condition -- crossplane_bucket_grantable_roles /
  # crossplane_bucket_grant_condition, NOT the DNS/projectIamAdmin ones above
  # (N1: they were shared on first pass, which meant adding the storage roles
  # here also legalised granting them at the PROJECT level through the
  # unrelated projectIamAdmin binding). Two independent clauses:
  #   - getIamPolicy/setIamPolicy are gated by hasOnly(bucket-scoped roles) --
  #     the setIamPolicy-shaped half, same mechanism as the DNS grant.
  #   - ALL FIVE permissions (including the four that are not setIamPolicy-
  #     shaped, where modifiedGrantsByRole is undefined and hasOnly alone
  #     would be vacuously true -- "gap 1" below) are additionally scoped to
  #     this platform's own bucket-name prefix via resource.name.startsWith,
  #     so even the unconditioned-by-role verbs (create/delete/get/update)
  #     cannot reach a bucket outside it.
  condition {
    title       = "xplane-scoped-grants-only"
    description = "Crossplane may act only on xplane-owned buckets, and may set IAM policy on them only for the allowlisted roles. Without this, a compromised provider-gcp could manage or grant an arbitrary role on any bucket in the project."
    expression  = local.crossplane_bucket_grant_condition
  }

  # Same fresh-apply race as the other principal bindings -- see TRAP 2.
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

# External Secrets' access to the Tailscale OAuth client.
#
# PER-SECRET, not through GCPWorkloadIdentity, for the same reason
# opentofu/gcp/openbao/management/iam.tf binds per secret: that composition
# renders ProjectIAMMember, which is PROJECT-scoped, so any secret-reading role
# granted through it can read every secret in the project by name -- including
# OpenBao's root token and the intermediate CA's private key.
#
# The subject duplicates the one in openbao/management deliberately rather than
# being shared: the two stacks have no dependency edge, and a remote-state read
# purely to avoid restating two strings would create one.
locals {
  # TRAP: `projects/` takes the project NUMBER while `workloadIdentityPools/`
  # takes the project ID. Reversed, the API ACCEPTS the binding and it silently
  # never matches.
  external_secrets_principal = join("", [
    "principal://iam.googleapis.com/projects/${data.google_project.this.number}",
    "/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog",
    "/subject/ns/${var.external_secrets_namespace}/sa/${var.external_secrets_service_account}",
  ])
}

# Secrets External Secrets may read, granted PER SECRET.
#
# Never project-wide: roles/secretmanager.secretAccessor on the project would
# also hand ESO openbao-priv-gcp-root-token, the recovery keys and the
# intermediate CA's private key, which live in the same project. Same reasoning
# as opentofu/gcp/openbao/cluster/iam.tf.
#
# ── WHY THIS LIST IS SHORT, AND WHERE THE REST ARE GRANTED ──────────────────
#
# A google_secret_manager_secret_iam_member needs its secret to EXIST. At the
# point this stack applies, only the hand-created bootstrap prerequisites and
# whatever opentofu/gcp/openbao created are there. Everything the platform
# itself needs -- Harbor's passwords, Grafana's admin pair, the Slack apps,
# runlore's credentials, the OIDC clients -- is created later, some of it only
# after ZITADEL is running inside the cluster this stack is about to build.
#
# Listing them here would fail the apply on a fresh project. They are granted by
# `scripts/secret-store.sh grant --cloud gcp`, which reads what the cluster's
# ExternalSecrets actually ask for and grants what exists. Creation and access
# stay together.
#
# Add to external_secrets_additional_secrets only for a secret that reliably
# exists BEFORE this stack applies.
locals {
  external_secrets_secret_names = toset(concat(
    [var.tailscale_oauth_secret_name],
    var.external_secrets_additional_secrets,
  ))
}

resource "google_secret_manager_secret_iam_member" "external_secrets" {
  for_each = local.external_secrets_secret_names

  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = local.external_secrets_principal
}

# Singleton -> for_each is a rename, not a change: same project, same secret,
# same role, same member. Without this the plan destroys and recreates the
# binding, and External Secrets loses its Tailscale read for the window in
# between -- a real outage for a pure refactor.
#
# The key is the literal rather than var.tailscale_oauth_secret_name because a
# moved block's addresses must be static.
moved {
  from = google_secret_manager_secret_iam_member.external_secrets_tailscale_oauth
  to   = google_secret_manager_secret_iam_member.external_secrets["tailscale-k8s-operator-oauth"]
}
