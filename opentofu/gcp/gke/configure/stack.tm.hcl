stack {
  name        = "GKE Cluster - Configure"
  description = "Gateway API CRDs, then Cilium, then Flux Operator and Flux Instance"
  id          = "c47b81e0-3f92-4a15-b6d8-9e02a7c5d431"

  after = [
    "/opentofu/gcp/gke/init"
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
