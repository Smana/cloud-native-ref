stack {
  name        = "GKE Cluster - Init"
  description = "GKE Standard cluster (zonal, private, legacy datapath), static spot node pool, Workload Identity, Crossplane WIF bootstrap"
  id          = "5a0ec1d9-6b2f-4f8e-9c3a-7d41e0b8f256"

  after = [
    "/opentofu/gcp/network",
    # This stack's own deploy script embeds a `gke/configure` apply as its
    # stage 2, rather than leaving it to Terramate's separate visit to that
    # stack. So gke/configure's `after` edge on workforce-identity does NOT
    # constrain the embedded run -- without this edge here, the ConfigMap can
    # publish workforce_pool_id before the pool exists, and stage 3's audience
    # reconciliation then finds no provider and skips. It self-heals on a later
    # sync, but silently, with RBAC bindings matching nobody in between.
    "/opentofu/gcp/workforce-identity"
  ]

  tags = [
    "gcp",
    "gke",
    "kubernetes",
    "infrastructure",
    # `opt-in` lets `terramate script run --no-tags=opt-in deploy` skip this
    # stack entirely (CI/audit path). The script overrides in workflows.tm.hcl
    # additionally guard on $TM_CLOUD so `terramate script run deploy`
    # from the opentofu/ root is also safe by default -- the script runs but
    # no-ops with a [skip] message.
    #
    # REMOVE THIS TAG AND THE GUARDS once GCP works end to end. Leaving them on
    # silently skips GCP forever, which looks identical to success.
    "opt-in",
  ]
}
