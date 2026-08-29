stack {
  name        = "GCP OpenBao Cluster"
  description = "Single-node OpenBao compute (instance template, MIG, boot script) plus its service account/IAM and auto-unseal wiring against a pre-existing Cloud KMS key, ahead of the load balancer and PKI configuration"
  id          = "d7c24921-dd6c-495d-ab43-db698e2d4724"

  # This stack reads the network stack's outputs via data.terraform_remote_state
  # (subnet, private DNS zone, domain) -- it must exist first.
  after = [
    "/opentofu/gcp/network"
  ]

  tags = [
    "gcp",
    "openbao",
    "security",
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
