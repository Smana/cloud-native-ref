stack {
  name        = "GKE Cluster - Init"
  description = "GKE Standard cluster (zonal, private, legacy datapath), static spot node pool, Workload Identity, Crossplane WIF bootstrap"
  id          = "5a0ec1d9-6b2f-4f8e-9c3a-7d41e0b8f256"

  # Why the GKE *cluster* stack waits on OpenBao, when nothing here reads it:
  # the edge exists for gke/configure, one stack downstream. That stack declares
  # a `vault` provider and a google_secret_manager_secret_version data source
  # for `openbao-priv-gcp-root-token`, and BOTH resolve at PLAN time -- so it
  # needs an initialised, unsealed OpenBao and that secret already written.
  # Writing it is openbao/management's job (`openbao-config.sh rehydrate`).
  # Without this edge the run order put management AFTER gke/configure, so a
  # from-scratch `TM_CLOUD=gcp terramate script run deploy` failed twice over:
  # the secret did not exist yet, and the server was still sealed.
  #
  # It sits HERE rather than on gke/configure to mirror
  # opentofu/aws/eks/init/stack.tm.hcl, which orders eks/configure after
  # openbao/management the same transitive way. Same edge, same place, so the
  # two clouds read identically.
  after = [
    "/opentofu/gcp/network",
    "/opentofu/gcp/openbao/management"
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
