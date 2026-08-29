stack {
  name        = "GCP Network"
  description = "VPC, subnet with pod/service secondary ranges, Private Google Access, Cloud NAT, Cloud DNS, Tailscale subnet router"
  id          = "93a39f89-c13b-4320-8340-2de99a08e4df"

  # shared/tailscale owns the tailnet-wide autoApprovers. A subnet router that
  # registers before they exist advertises routes that stay pending manual
  # approval -- which presents as a routing failure rather than a policy gap.
  after = [
    "/opentofu/shared/tailscale"
  ]

  tags = [
    "gcp",
    "network",
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
