# One AppRole backend hosting one role. The AWS stack hosts two (snapshot and
# cert-manager); the snapshot role has no GCP consumer because nothing backs up
# this PKI yet -- recorded as a risk in the design rather than solved here.
resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

resource "vault_approle_auth_backend_role" "cert_manager" {
  backend        = vault_auth_backend.approle.path
  role_name      = "cert-manager"
  token_policies = [vault_policy.cert_manager.name]

  # PINNED, not generated — and this is a deliberate divergence from AWS.
  #
  # cert-manager's ClusterIssuer takes `roleId` as a REQUIRED STRING with no
  # secretRef option (verified against the cert-manager v1.21.1 CRD). AWS
  # therefore plumbs the generated value into a Flux postBuild variable via its
  # cluster vars ConfigMap.
  #
  # GCP cannot: that ConfigMap is owned by gke/configure, which applies it
  # server-side as a whole object, and THIS stack has no kubernetes provider at
  # all (see providers.tf -- google and vault only). A key added here would be
  # reverted by the next gke/configure apply even if it could be written.
  # Reversing the two stacks is not an option either; management needs a
  # reachable, initialised OpenBao at plan time.
  #
  # A role_id is an identifier, not a credential — it is useless without the
  # secret_id, which stays in Secret Manager and reaches the cluster through
  # External Secrets. Pinning it lets the ClusterIssuer name it directly and
  # removes a cross-stack ordering dependency entirely.
  role_id = "cert-manager-gcp"


  # Short-lived tokens. cert-manager re-authenticates per issuance, so a long
  # TTL buys nothing and widens the window on a leaked token.
  token_ttl     = 600
  token_max_ttl = 1200

  # NOTE: no token_bound_cidrs, unlike AWS. DEFERRED, not impossible.
  #
  # An earlier version of this comment said the source address could not be
  # predicted because the caller reached OpenBao "over the tailnet". That is
  # wrong, and it contradicted openbao/cluster/firewall.tf: cert-manager is a POD
  # on gcp-mycluster-0 talking to the internal LB inside the VPC, and never
  # traverses the tailnet. The candidate ranges are perfectly predictable --
  # node_cidr and pod_cidr, both already reachable from this stack through the
  # network remote state.
  #
  # What is NOT yet known is WHICH of the two the packet actually presents.
  # Cilium displaced GKE's CNI here, so whether pod egress to an in-VPC LB is
  # masqueraded to the node IP or arrives with the pod IP is a measurement
  # nobody has taken on this cluster. Binding to the wrong one fails closed at
  # issuance, with an error that names the AppRole and says nothing about the
  # network.
  #
  # So: measure it against a running cluster (`hubble observe` on the
  # cert-manager pod, or the OpenBao audit log's remote_address), then bind to
  # what it shows. Do not guess.
}
