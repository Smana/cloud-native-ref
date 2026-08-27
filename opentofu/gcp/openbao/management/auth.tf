# One AppRole backend hosting both roles below. It used to host only
# cert-manager: the snapshot role had no GCP consumer because nothing backed up
# this PKI yet, recorded as a risk in the design rather than solved here.
# Workstream 9 gave it a consumer -- the openbao-snapshot CronJob -- so that
# risk is now closed.
resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"
}

# Raft snapshots. `sys/storage/raft/*` is a restricted endpoint: "Clients must
# call the API path from the root namespace." Raft is a property of the
# cluster, not a namespace, so a token from any child namespace gets 404
# "unsupported path" no matter what its policy grants. This resource therefore
# takes no `namespace` argument, same as vault_auth_backend.approle above --
# that is how the provider addresses root.
resource "vault_approle_auth_backend_role" "snapshot" {
  backend        = vault_auth_backend.approle.path
  role_name      = "snapshot-agent"
  token_policies = [vault_policy.snapshot.name]

  # role_id is NOT pinned, unlike cert_manager below. That pinning exists only
  # because cert-manager's ClusterIssuer takes roleId as a required literal
  # string with no secretRef option. The snapshot CronJob reads both
  # APPROLE_ROLE_ID and APPROLE_SECRET_ID out of its Secret Manager entry
  # (secrets.tf), so there is no manifest-literal reason to fix this value --
  # let both be generated.

  # Bound now. The deferral this replaced said the ranges were known but which
  # one the CronJob's egress actually presents had "not been measured on this
  # cluster" -- it has been, on a live gcp-0 (2026-08-26). See
  # local.approle_bound_cidrs for the measurement and why both ranges are bound
  # rather than only the node CIDR the packets currently carry.
  token_bound_cidrs = local.approle_bound_cidrs
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

  # Bound now, resolving the deferral this comment used to carry.
  #
  # That deferral was right to exist and right about the diagnosis: cert-manager
  # is a POD on gcp-0 talking to the internal LB inside the VPC, never over the
  # tailnet, so the candidate ranges were always node_cidr and pod_cidr. What it
  # correctly refused to guess was WHICH one the packet presents, since Cilium
  # displaced GKE's CNI here.
  #
  # It has now been measured on a live gcp-0 (2026-08-26): native routing with
  # the native-routing CIDR set to the POD range, masquerading on, and the LB
  # outside that range -- so pod egress is SNATed to the node IP. Details in
  # local.approle_bound_cidrs.
  #
  # One correction the deferral also needs: it said both ranges were "already
  # reachable from this stack through the network remote state". They were not.
  # That data source lived only in openbao/cluster/data.tf; this stack had none
  # until it was added alongside this change.
  token_bound_cidrs = local.approle_bound_cidrs
}
