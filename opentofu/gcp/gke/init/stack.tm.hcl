stack {
  name        = "GKE Cluster - Init"
  description = "GKE Standard cluster (zonal, private, legacy datapath), static spot node pool, Workload Identity, Crossplane WIF bootstrap"
  id          = "5a0ec1d9-6b2f-4f8e-9c3a-7d41e0b8f256"

  after = [
    "/opentofu/gcp/network"
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
