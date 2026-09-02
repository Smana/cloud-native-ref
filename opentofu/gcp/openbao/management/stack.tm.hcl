stack {
  name        = "GCP OpenBao Management"
  description = "PKI mount, cert-manager PKI role and policies on the GCP OpenBao instance"
  id          = "001633e0-7027-40ca-9d1d-dd2facb5d736"

  # The vault provider needs a REACHABLE, INITIALISED server at plan time, so
  # this cannot run before openbao/cluster exists and `openbao-config.sh init`
  # has run against it. Same constraint that splits gke/init from gke/configure.
  after = [
    "/opentofu/gcp/openbao/cluster"
  ]

  tags = [
    "gcp",
    "openbao",
    "security",
    # See opentofu/gcp/network/stack.tm.hcl -- REMOVE THIS TAG AND THE GUARDS
    # once GCP works end to end. Leaving them on silently skips GCP forever,
    # which looks identical to success.
    "opt-in",
  ]
}
