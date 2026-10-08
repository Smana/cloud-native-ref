# Everything else is left on its defaults in variables.tf, which carry the
# project's real values (europe-west4, priv.gcp.ogenki.io, the Secret Manager
# entry names the ceremony and init script create).
project_id = "ogenki-435905"

# The same apps as AWS (opentofu/aws/openbao/management/variables.tfvars), so a
# persona behaves identically on either cloud's OpenBao.
secret_owning_apps = ["app-wizard", "image-gallery"]

# room-broker serves TLS on :8443 under its Service names (gcp-0 has no WireGuard,
# GP-18), and the run bridges dial it by those names. Only this namespace's
# cluster-local names, and accepted knowingly: the root is shared, so a cert for
# them would also be chain-valid inside aws-0 (F7, 2026-10-01).
pki_additional_allowed_domains = ["agent-system.svc.cluster.local", "agent-system.svc"]
