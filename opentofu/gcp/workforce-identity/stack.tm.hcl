stack {
  name        = "GCP Workforce Identity"
  description = "Organisation-level workforce identity pool federating ZITADEL OIDC, for Kubernetes RBAC on GKE"
  id          = "d00e1d99-c530-405c-ba48-1573d42ba3ad"

  # No `after`. The pool is parented at organizations/<org_id>, not at a
  # project or a cluster, so this stack does not need gcp/network or gcp/gke
  # to exist -- same reasoning as shared/aws-gcp-federation's stack.tm.hcl.
  # It is gke/configure that depends on THIS stack (it consumes
  # `workforce_pool_id`), not the other way around.

  tags = [
    "gcp",
    "iam",
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
